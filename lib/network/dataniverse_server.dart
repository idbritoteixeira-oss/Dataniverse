// lib/network/dataniverse_server.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/server_config.dart';
import '../database/enx_db.dart';

typedef ServerLogCallback = void Function(String message);
typedef ConnectionCountCallback = void Function(int count);

/// Servidor HTTP REST puro.
///
/// POST  /command   → executa uma ação no banco (requer header X-Password)
/// GET   /          → página de status HTML
///
/// Sem WebSocket, sem port-forwarding especial — HTTP puro atravessa
/// qualquer roteador / operadora de celular.
class DataniverseServer {
  DataniverseServer({
    required this.config,
    required this.database,
    this.onLog,
    this.onConnectionsChanged,
  });

  ServerConfig config;
  EnXDB database;
  final ServerLogCallback? onLog;
  final ConnectionCountCallback? onConnectionsChanged;

  HttpServer? _httpServer;
  StreamSubscription<HttpRequest>? _serverSub;

  // "Conexões ativas" aqui = requisições em processamento simultâneo
  int _activeRequests = 0;

  String? publicIp;

  bool get isRunning => _httpServer != null;
  int get connectionCount => _activeRequests;

  // ─────────────────────────────────────────────
  // Start / Stop
  // ─────────────────────────────────────────────

  Future<void> start() async {
    if (isRunning) return;
    await database.ensureStructure();
    _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, config.port);
    _serverSub = _httpServer!.listen(_handle);
    _log('Servidor HTTP iniciado na porta ${config.port}.');
    _detectPublicIp();
  }

  Future<void> stop() async {
    final server = _httpServer;
    _httpServer = null;
    await _serverSub?.cancel();
    _serverSub = null;
    await server?.close(force: true);
    _activeRequests = 0;
    onConnectionsChanged?.call(0);
    _log('Servidor parado.');
  }

  Future<void> _detectPublicIp() async {
    try {
      final response = await http
          .get(Uri.parse('https://api.ipify.org'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        publicIp = response.body.trim();
        _log('IP público: $publicIp');
      }
    } catch (_) {
      _log('Não foi possível detectar o IP público.');
    }
  }

  // ─────────────────────────────────────────────
  // Roteamento HTTP
  // ─────────────────────────────────────────────

  Future<void> _handle(HttpRequest req) async {
    // CORS — permite chamadas de qualquer origem
    req.response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..set('Access-Control-Allow-Headers', 'Content-Type, X-Password');

    if (req.method == 'OPTIONS') {
      req.response.statusCode = HttpStatus.noContent;
      await req.response.close();
      return;
    }

    final path = req.uri.path;

    if (req.method == 'GET' && (path == '/' || path.isEmpty)) {
      await _serveStatus(req);
      return;
    }

    if (req.method == 'POST' && path == '/command') {
      _activeRequests++;
      onConnectionsChanged?.call(_activeRequests);
      try {
        await _handleCommand(req);
      } finally {
        _activeRequests--;
        onConnectionsChanged?.call(_activeRequests);
      }
      return;
    }

    req.response
      ..statusCode = HttpStatus.notFound
      ..write('Not found');
    await req.response.close();
  }

  // ─────────────────────────────────────────────
  // POST /command
  // ─────────────────────────────────────────────

  Future<void> _handleCommand(HttpRequest req) async {
    // Autenticação via header X-Password
    final password = req.headers.value('x-password') ?? '';
    if (password != config.password) {
      await _jsonResponse(req, HttpStatus.unauthorized, {
        'status': 'ERROR',
        'message': 'Senha inválida. Envie o header X-Password.',
      });
      _log('Tentativa não autorizada de ${req.connectionInfo?.remoteAddress.address}.');
      return;
    }

    // Lê o body JSON
    final body = await utf8.decoder.bind(req).join();
    _log('Requisição recebida de ${req.connectionInfo?.remoteAddress.address}.');

    Map<String, dynamic> request;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw const FormatException('Body deve ser um objeto JSON.');
      request = Map<String, dynamic>.from(decoded);
    } catch (e) {
      await _jsonResponse(req, HttpStatus.badRequest, {
        'status': 'ERROR',
        'message': 'JSON inválido: $e',
      });
      return;
    }

    final action = request['action']?.toString().toUpperCase();
    _log('Action: $action');

    try {
      switch (action) {
        case 'INSERT':
          await _insert(req, request);
        case 'UPDATE':
          await _update(req, request);
        case 'DELETE':
          await _delete(req, request);
        case 'FIND_BY_ID':
          await _findById(req, request);
        case 'FIND_BY_INDEX':
          await _findByIndex(req, request);
        case 'LIST_TABLES':
          await _listTables(req);
        case 'LIST_RECORDS':
          await _listRecords(req, request);
        default:
          await _jsonResponse(req, HttpStatus.badRequest, {
            'status': 'ERROR',
            'message': 'Ação desconhecida: ${request['action']}.',
          });
      }
    } catch (e) {
      _log('Erro ao processar ação: $e');
      await _jsonResponse(req, HttpStatus.internalServerError, {
        'status': 'ERROR',
        'message': e.toString(),
      });
    }
  }

  // ─────────────────────────────────────────────
  // Ações do banco (lógica idêntica, só troca
  // WebSocket por HttpRequest)
  // ─────────────────────────────────────────────

  Future<void> _insert(HttpRequest req, Map<String, dynamic> r) async {
    final table = _req(r, 'table');
    final rawData = r['data'];
    if (rawData is! Map) throw const FormatException('O campo data precisa ser um objeto.');
    final record = await database.insert(table, Map<String, dynamic>.from(rawData), _opt(r['seedShard']));
    _log('INSERT em $table: ${record['id']}.');
    await _ok(req, 'Registro inserido.', record);
  }

  Future<void> _update(HttpRequest req, Map<String, dynamic> r) async {
    final table = _req(r, 'table');
    final id = _req(r, 'id');
    final rawData = r['data'];
    if (rawData is! Map) throw const FormatException('O campo data precisa ser um objeto.');
    final record = await database.update(table, id, Map<String, dynamic>.from(rawData), _opt(r['seedShard']));
    _log('UPDATE em $table: $id.');
    await _ok(req, 'Registro atualizado.', record);
  }

  Future<void> _delete(HttpRequest req, Map<String, dynamic> r) async {
    final table = _req(r, 'table');
    if (!r.containsKey('id') || r['id']?.toString().trim().isEmpty == true) {
      await database.deleteTable(table, _opt(r['seedShard']));
      _log('DELETE tabela $table.');
      await _ok(req, 'Tabela eliminada.', null);
      return;
    }
    final id = _req(r, 'id');
    final deleted = await database.deleteRecord(table, id, _opt(r['seedShard']));
    _log('DELETE em $table: $id.');
    await _jsonResponse(req, HttpStatus.ok, {
      'status': deleted ? 'SUCCESS' : 'ERROR',
      'message': deleted ? 'Registro eliminado.' : 'Registro não encontrado.',
    });
  }

  Future<void> _findById(HttpRequest req, Map<String, dynamic> r) async {
    final table = _req(r, 'table');
    final id = _req(r, 'id');
    final record = await database.findById(table, id, _opt(r['seedShard']));
    _log('FIND_BY_ID em $table: $id.');
    await _jsonResponse(req, HttpStatus.ok, {
      'status': record == null ? 'ERROR' : 'SUCCESS',
      'message': record == null ? 'Registro não encontrado.' : 'Registro encontrado.',
      'data': record,
    });
  }

  Future<void> _findByIndex(HttpRequest req, Map<String, dynamic> r) async {
    final table = _req(r, 'table');
    final field = _req(r, 'field');
    if (!r.containsKey('value')) throw const FormatException('O campo value é obrigatório.');
    final records = await database.findByIndex(table, field, r['value'], _opt(r['seedShard']));
    _log('FIND_BY_INDEX em $table.$field.');
    await _ok(req, '${records.length} registro(s) encontrado(s).', records);
  }

  Future<void> _listTables(HttpRequest req) async {
    final tables = await database.listTables();
    await _ok(req, '${tables.length} tabela(s).', tables);
  }

  Future<void> _listRecords(HttpRequest req, Map<String, dynamic> r) async {
    final table = _req(r, 'table');
    final records = await database.listRecords(table, _opt(r['seedShard']));
    await _ok(req, '${records.length} registro(s).', records);
  }

  // ─────────────────────────────────────────────
  // Helpers de resposta
  // ─────────────────────────────────────────────

  Future<void> _ok(HttpRequest req, String message, dynamic data) =>
      _jsonResponse(req, HttpStatus.ok, {
        'status': 'SUCCESS',
        'message': message,
        'data': data,
      });

  Future<void> _jsonResponse(
    HttpRequest req,
    int statusCode,
    Map<String, dynamic> body,
  ) async {
    req.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await req.response.close();
  }

  // ─────────────────────────────────────────────
  // Página de status HTML (GET /)
  // ─────────────────────────────────────────────

  Future<void> _serveStatus(HttpRequest req) async {
    final now = DateTime.now().toLocal().toString().substring(0, 19);
    final html = '''<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Dataniverse Server</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:system-ui,sans-serif;background:#0f172a;color:#e2e8f0;
         display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}
    .card{background:#1e293b;border-radius:16px;padding:40px 48px;max-width:480px;width:100%;
          box-shadow:0 20px 60px rgba(0,0,0,.5)}
    .logo{width:48px;height:48px;background:#4f46e5;border-radius:12px;
          display:flex;align-items:center;justify-content:center;font-size:24px;margin-bottom:20px}
    h1{font-size:1.5rem;font-weight:800;color:#f1f5f9;margin-bottom:6px}
    .badge{display:inline-flex;align-items:center;gap:6px;background:#064e3b;
           color:#34d399;border-radius:20px;padding:4px 12px;font-size:.8rem;font-weight:700;margin-bottom:24px}
    .dot{width:8px;height:8px;background:#34d399;border-radius:50%;animation:pulse 1.5s ease-in-out infinite}
    @keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
    table{width:100%;border-collapse:collapse}
    td{padding:10px 0;border-bottom:1px solid #334155;font-size:.9rem}
    td:first-child{color:#94a3b8}
    td:last-child{font-weight:600;text-align:right;font-family:monospace}
    .footer{margin-top:20px;font-size:.75rem;color:#475569;text-align:center}
    code{background:#0f172a;padding:2px 6px;border-radius:4px;font-size:.85rem}
  </style>
</head>
<body>
  <div class="card">
    <div class="logo">🗄</div>
    <h1>Dataniverse Server</h1>
    <div class="badge"><span class="dot"></span> Online</div>
    <table>
      <tr><td>Porta</td><td>${config.port}</td></tr>
      <tr><td>Protocolo</td><td>HTTP REST / JSON</td></tr>
      <tr><td>IP público</td><td>${publicIp ?? 'detectando...'}</td></tr>
      <tr><td>Requisições ativas</td><td>$_activeRequests</td></tr>
      <tr><td>Última verificação</td><td>$now</td></tr>
    </table>
    <p class="footer">
      Envie <code>POST /command</code> com header <code>X-Password</code> e body JSON.
    </p>
  </div>
</body>
</html>''';

    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(html);
    await req.response.close();
    _log('Página de status servida.');
  }

  // ─────────────────────────────────────────────
  // Helpers gerais
  // ─────────────────────────────────────────────

  String _req(Map<String, dynamic> r, String key) {
    final v = r[key]?.toString().trim();
    if (v == null || v.isEmpty) throw FormatException('O campo $key é obrigatório.');
    return v;
  }

  String? _opt(dynamic v) {
    final s = v?.toString().trim();
    return s == null || s.isEmpty ? null : s;
  }

  void _log(String msg) =>
      onLog?.call('[${DateTime.now().toIso8601String()}] $msg');
}