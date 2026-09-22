import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/server_config.dart';
import '../database/enx_db.dart';

typedef ServerLogCallback = void Function(String message);
typedef ConnectionCountCallback = void Function(int count);

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

  // ── #1 Alteração: Usamos HttpServer em vez de ServerSocket ──
  HttpServer? _httpServer;
  StreamSubscription<HttpRequest>? _serverSubscription;
  
  // As listas agora armazenam WebSockets
  final Set<WebSocket> _clients = {};
  final Map<WebSocket, bool> _authenticated = {};

  String? publicIp;

  bool get isRunning => _httpServer != null;
  int get connectionCount => _clients.length;

  Future<void> start() async {
    if (isRunning) return;

    // Garante estrutura de pastas antes de aceitar conexões
    await database.ensureStructure();

    // ── #2 Inicializa o HttpServer ──
    _httpServer = await HttpServer.bind(
      InternetAddress.anyIPv4,
      config.port,
    );
    
    // Escuta as requisições HTTP de entrada
    _serverSubscription = _httpServer!.listen(_handleHttpRequest);
    _log('Servidor iniciado na porta ${config.port} (HTTP/WebSocket).');

    // Busca IP público assincronamente
    _detectPublicIp();
  }

  Future<void> stop() async {
    final server = _httpServer;
    _httpServer = null;
    await _serverSubscription?.cancel();
    _serverSubscription = null;
    await server?.close();

    // Fecha todos os clientes conectados
    for (final socket in _clients.toList()) {
      await socket.close();
    }
    _clients.clear();
    _authenticated.clear();
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
        _log('IP público detectado: $publicIp');
      }
    } catch (_) {
      _log('Não foi possível detectar o IP público.');
    }
  }

  // ──────────────────────────────────────────────
  // #3 Roteamento: Separa HTTP comum de WebSockets
  // ──────────────────────────────────────────────
  void _handleHttpRequest(HttpRequest request) {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      // É uma tentativa de conexão WebSocket (ws://)
      WebSocketTransformer.upgrade(request).then((socket) {
        _handleWebSocketClient(socket, request);
      }).catchError((error) {
        _log('Erro ao fazer upgrade para WebSocket: $error');
      });
    } else {
      // É uma requisição HTTP comum (navegador acessando a página)
      _serveHtmlPage(request);
    }
  }

  // ──────────────────────────────────────────────
  // Gestão de Conexão WebSocket
  // ──────────────────────────────────────────────
  void _handleWebSocketClient(WebSocket socket, HttpRequest request) {
    _clients.add(socket);
    _authenticated[socket] = false;
    onConnectionsChanged?.call(connectionCount);
    
    final address = request.connectionInfo?.remoteAddress.address ?? 'Desconhecido';
    _log('Cliente WebSocket conectado: $address.');

    // Escuta as mensagens JSON recebidas
    socket.listen(
      (dynamic message) {
        // Os WebSockets entregam a mensagem completa, sem precisar de buffer!
        unawaited(_handleLine(socket, message.toString()));
      },
      onError: (Object error) {
        _log('Erro de comunicação com cliente: $error');
        _removeClient(socket);
      },
      onDone: () => _removeClient(socket),
    );
  }

  // ──────────────────────────────────────────────
  // Serve página HTML de status (HTTP GET)
  // ──────────────────────────────────────────────
  Future<void> _serveHtmlPage(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.html;
    response.write(_buildHtmlIndex());
    await response.close();
    _log('Página HTTP servida para ${request.connectionInfo?.remoteAddress.address}.');
  }

  String _buildHtmlIndex() {
    final now = DateTime.now().toLocal().toString().substring(0, 19);
    return '''<!DOCTYPE html>
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
    .dot{width:8px;height:8px;background:#34d399;border-radius:50%;
         animation:pulse 1.5s ease-in-out infinite}
    @keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
    table{width:100%;border-collapse:collapse}
    td{padding:10px 0;border-bottom:1px solid #334155;font-size:.9rem}
    td:first-child{color:#94a3b8}
    td:last-child{font-weight:600;text-align:right;font-family:monospace}
    .footer{margin-top:20px;font-size:.75rem;color:#475569;text-align:center}
  </style>
</head>
<body>
  <div class="card">
    <div class="logo">🗄</div>
    <h1>Dataniverse Server</h1>
    <div class="badge"><span class="dot"></span> Online</div>
    <table>
      <tr><td>Porta</td><td>${config.port}</td></tr>
      <tr><td>Protocolo</td><td>WebSocket / JSON</td></tr>
      <tr><td>IP público</td><td>${publicIp ?? 'detectando...'}</td></tr>
      <tr><td>Conexões ativas</td><td>$connectionCount</td></tr>
      <tr><td>Última verificação</td><td>$now</td></tr>
    </table>
    <p class="footer">Conecte-se via WebSocket (ws://) na porta ${config.port} e envie AUTH primeiro.</p>
  </div>
</body>
</html>''';
  }

  // ──────────────────────────────────────────────
  // Processamento de Mensagens JSON
  // ──────────────────────────────────────────────
  Future<void> _handleLine(WebSocket socket, String line) async {
    if (line.trim().isEmpty) return;

    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        throw const FormatException('O comando precisa ser um objeto JSON.');
      }
      final request = Map<String, dynamic>.from(decoded);
      final action = request['action']?.toString().toUpperCase();
      _log('Requisição recebida: ${action ?? 'sem action'}.');

      if (!(_authenticated[socket] ?? false)) {
        if (action != 'AUTH') {
          await _respond(
            socket,
            status: 'ERROR',
            message: 'Autenticação obrigatória. Envie AUTH primeiro.',
          );
          return;
        }

        if (request['password']?.toString() != config.password) {
          await _respond(
            socket,
            status: 'ERROR',
            message: 'Senha inválida.',
          );
          _log('Tentativa de autenticação recusada.');
          return;
        }

        _authenticated[socket] = true;
        _log('Cliente autenticado.');
        await _respond(
          socket,
          status: 'SUCCESS',
          message: 'Autenticação realizada.',
        );
        return;
      }

      switch (action) {
        case 'INSERT':
          await _insert(socket, request);
          break;
        case 'UPDATE':
          await _update(socket, request);
          break;
        case 'DELETE':
          await _delete(socket, request);
          break;
        case 'FIND_BY_ID':
          await _findById(socket, request);
          break;
        case 'FIND_BY_INDEX':
          await _findByIndex(socket, request);
          break;
        case 'LIST_TABLES':
          await _listTables(socket);
          break;
        case 'LIST_RECORDS':
          await _listRecords(socket, request);
          break;
        default:
          await _respond(
            socket,
            status: 'ERROR',
            message: 'Ação desconhecida: ${request['action']}.',
          );
      }
    } catch (error) {
      _log('Requisição inválida: $error');
      await _respond(
        socket,
        status: 'ERROR',
        message: error.toString(),
      );
    }
  }

  // Métodos de Banco de Dados mantidos exatamente iguais, 
  // recebendo apenas o WebSocket agora.

  Future<void> _insert(WebSocket socket, Map<String, dynamic> request) async {
    final table = _requiredString(request, 'table');
    final rawData = request['data'];
    if (rawData is! Map) {
      throw const FormatException('O campo data precisa ser um objeto.');
    }
    final record = await database.insert(
      table,
      Map<String, dynamic>.from(rawData),
      _optionalString(request['seedShard']),
    );
    _log('INSERT em $table: ${record['id']}.');
    await _respond(socket, status: 'SUCCESS', message: 'Registro inserido.', data: record);
  }

  Future<void> _update(WebSocket socket, Map<String, dynamic> request) async {
    final table = _requiredString(request, 'table');
    final id = _requiredString(request, 'id');
    final rawData = request['data'];
    if (rawData is! Map) {
      throw const FormatException('O campo data precisa ser um objeto.');
    }
    final record = await database.update(
      table, id, Map<String, dynamic>.from(rawData), _optionalString(request['seedShard'])
    );
    _log('UPDATE em $table: $id.');
    await _respond(socket, status: 'SUCCESS', message: 'Registro atualizado.', data: record);
  }

  Future<void> _delete(WebSocket socket, Map<String, dynamic> request) async {
    final table = _requiredString(request, 'table');
    if (!request.containsKey('id') || request['id']?.toString().trim().isEmpty == true) {
      await database.deleteTable(table, _optionalString(request['seedShard']));
      _log('DELETE tabela $table.');
      await _respond(socket, status: 'SUCCESS', message: 'Tabela eliminada.');
      return;
    }
    final id = _requiredString(request, 'id');
    final deleted = await database.deleteRecord(table, id, _optionalString(request['seedShard']));
    _log('DELETE em $table: $id.');
    await _respond(socket, status: deleted ? 'SUCCESS' : 'ERROR', 
                   message: deleted ? 'Registro eliminado.' : 'Registro não encontrado.');
  }

  Future<void> _findById(WebSocket socket, Map<String, dynamic> request) async {
    final table = _requiredString(request, 'table');
    final id = _requiredString(request, 'id');
    final record = await database.findById(table, id, _optionalString(request['seedShard']));
    _log('FIND_BY_ID em $table: $id.');
    await _respond(socket, status: record == null ? 'ERROR' : 'SUCCESS',
                   message: record == null ? 'Registro não encontrado.' : 'Registro encontrado.', data: record);
  }

  Future<void> _findByIndex(WebSocket socket, Map<String, dynamic> request) async {
    final table = _requiredString(request, 'table');
    final field = _requiredString(request, 'field');
    if (!request.containsKey('value')) throw const FormatException('O campo value é obrigatório.');
    final records = await database.findByIndex(table, field, request['value'], _optionalString(request['seedShard']));
    _log('FIND_BY_INDEX em $table.$field.');
    await _respond(socket, status: 'SUCCESS', message: '${records.length} registro(s) encontrado(s).', data: records);
  }

  Future<void> _listTables(WebSocket socket) async {
    final tables = await database.listTables();
    await _respond(socket, status: 'SUCCESS', message: '${tables.length} tabela(s).', data: tables);
  }

  Future<void> _listRecords(WebSocket socket, Map<String, dynamic> request) async {
    final table = _requiredString(request, 'table');
    final records = await database.listRecords(table, _optionalString(request['seedShard']));
    await _respond(socket, status: 'SUCCESS', message: '${records.length} registro(s).', data: records);
  }

  // ── #4 Respondendo ao Cliente ──
  Future<void> _respond(
    WebSocket socket, {
    required String status,
    required String message,
    dynamic data,
  }) {
    if (!_clients.contains(socket)) return Future<void>.value();
    
    // O WebSocket usa 'add' em vez de 'write' para enviar a string pronta
    socket.add(
      jsonEncode({
        'status': status,
        'message': message,
        'data': data,
      })
    );
    return Future<void>.value();
  }

  String _requiredString(Map<String, dynamic> request, String key) {
    final value = request[key]?.toString().trim();
    if (value == null || value.isEmpty) {
      throw FormatException('O campo $key é obrigatório.');
    }
    return value;
  }

  String? _optionalString(dynamic value) {
    final normalized = value?.toString().trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  void _removeClient(WebSocket socket) {
    _clients.remove(socket);
    _authenticated.remove(socket);
    onConnectionsChanged?.call(connectionCount);
    _log('Cliente desconectado.');
  }

  void _log(String message) {
    onLog?.call('[${DateTime.now().toIso8601String()}] $message');
  }
}
