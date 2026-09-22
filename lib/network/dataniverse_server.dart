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

  ServerSocket? _serverSocket;
  StreamSubscription<Socket>? _serverSubscription;
  final Set<Socket> _clients = {};
  final Map<Socket, bool> _authenticated = {};

  // ── #1 IP público detectado assincronamente ──
  String? publicIp;

  bool get isRunning => _serverSocket != null;
  int get connectionCount => _clients.length;

  Future<void> start() async {
    if (isRunning) return;

    // #4 Garante estrutura de pastas antes de aceitar conexões
    await database.ensureStructure();

    _serverSocket = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      config.port,
    );
    _serverSubscription = _serverSocket!.listen(_handleClient);
    _log('Servidor iniciado na porta ${config.port}.');

    // #1 Busca IP público sem bloquear o start
    _detectPublicIp();
  }

  Future<void> stop() async {
    final serverSocket = _serverSocket;
    _serverSocket = null;
    await _serverSubscription?.cancel();
    _serverSubscription = null;
    await serverSocket?.close();

    for (final socket in _clients.toList()) {
      socket.destroy();
    }
    _clients.clear();
    _authenticated.clear();
    onConnectionsChanged?.call(0);
    _log('Servidor parado.');
  }

  // ──────────────────────────────────────────────
  // #1 Detecção de IP público
  // ──────────────────────────────────────────────
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
  // Recebe conexão — detecta se é HTTP ou TCP puro
  // ──────────────────────────────────────────────
  void _handleClient(Socket socket) {
    _clients.add(socket);
    _authenticated[socket] = false;
    onConnectionsChanged?.call(connectionCount);
    _log(
      'Cliente conectado: ${socket.remoteAddress.address}:${socket.remotePort}.',
    );

    // Lê o primeiro chunk para detectar protocolo
    bool protocolDecided = false;
    final buffer = StringBuffer();

    socket.cast<List<int>>().listen(
      (bytes) {
        if (!protocolDecided) {
          final chunk = utf8.decode(bytes, allowMalformed: true);
          buffer.write(chunk);
          final raw = buffer.toString();

          // Detecta requisição HTTP pelo verbo na primeira linha
          if (raw.startsWith('GET ') ||
              raw.startsWith('POST ') ||
              raw.startsWith('HEAD ')) {
            protocolDecided = true;
            _handleHttpRequest(socket, raw);
          } else if (raw.contains('\n')) {
            // Tem uma linha completa → protocolo TCP/JSON
            protocolDecided = true;
            _switchToJsonProtocol(socket, raw);
          }
          // Se ainda não tem linha completa, continua acumulando
        }
      },
      onError: (Object error) {
        _log('Erro de comunicação com cliente: $error');
        _removeClient(socket);
      },
      onDone: () => _removeClient(socket),
    );
  }

  // ──────────────────────────────────────────────
  // #6 HTTP: serve página HTML de status
  // ──────────────────────────────────────────────
  void _handleHttpRequest(Socket socket, String rawRequest) {
    final body = _buildHtmlIndex();
    final response = [
      'HTTP/1.1 200 OK',
      'Content-Type: text/html; charset=utf-8',
      'Content-Length: ${utf8.encode(body).length}',
      'Connection: close',
      '',
      body,
    ].join('\r\n');

    socket.write(response);
    socket.destroy();
    _log('Página HTTP servida para ${socket.remoteAddress.address}.');
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
      <tr><td>Porta TCP</td><td>${config.port}</td></tr>
      <tr><td>Protocolo</td><td>TCP / JSON</td></tr>
      <tr><td>IP público</td><td>${publicIp ?? 'detectando...'}</td></tr>
      <tr><td>Conexões ativas</td><td>$connectionCount</td></tr>
      <tr><td>Última verificação</td><td>$now</td></tr>
    </table>
    <p class="footer">Conecte-se via TCP na porta ${config.port} e envie AUTH primeiro.</p>
  </div>
</body>
</html>''';
  }

  // ──────────────────────────────────────────────
  // Protocolo TCP/JSON (comportamento original)
  // ──────────────────────────────────────────────
  void _switchToJsonProtocol(Socket socket, String buffered) {
    // Processa as linhas já acumuladas no buffer
    final lines = buffered.split('\n');
    for (var i = 0; i < lines.length - 1; i++) {
      final line = lines[i].replaceAll('\r', '');
      unawaited(_handleLine(socket, line));
    }

    // A última parte pode estar incompleta; guarda para o próximo chunk
    final partial = lines.last;
    final partialBuffer = StringBuffer(partial);

    socket.cast<List<int>>().transform(utf8.decoder).listen(
      (chunk) {
        partialBuffer.write(chunk);
        final all = partialBuffer.toString();
        final parts = all.split('\n');
        partialBuffer.clear();
        partialBuffer.write(parts.last);
        for (var i = 0; i < parts.length - 1; i++) {
          final line = parts[i].replaceAll('\r', '');
          unawaited(_handleLine(socket, line));
        }
      },
      onError: (Object error) {
        _log('Erro de comunicação com cliente: $error');
        _removeClient(socket);
      },
      onDone: () => _removeClient(socket),
      cancelOnError: true,
    );
  }

  Future<void> _handleLine(Socket socket, String line) async {
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

  Future<void> _insert(
    Socket socket,
    Map<String, dynamic> request,
  ) async {
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
    await _respond(
      socket,
      status: 'SUCCESS',
      message: 'Registro inserido.',
      data: record,
    );
  }

  Future<void> _update(
    Socket socket,
    Map<String, dynamic> request,
  ) async {
    final table = _requiredString(request, 'table');
    final id = _requiredString(request, 'id');
    final rawData = request['data'];
    if (rawData is! Map) {
      throw const FormatException('O campo data precisa ser um objeto.');
    }

    final record = await database.update(
      table,
      id,
      Map<String, dynamic>.from(rawData),
      _optionalString(request['seedShard']),
    );
    _log('UPDATE em $table: $id.');
    await _respond(
      socket,
      status: 'SUCCESS',
      message: 'Registro atualizado.',
      data: record,
    );
  }

  Future<void> _delete(
    Socket socket,
    Map<String, dynamic> request,
  ) async {
    final table = _requiredString(request, 'table');

    // DELETE de tabela inteira se não vier id
    if (!request.containsKey('id') ||
        request['id']?.toString().trim().isEmpty == true) {
      await database.deleteTable(
        table,
        _optionalString(request['seedShard']),
      );
      _log('DELETE tabela $table.');
      await _respond(
        socket,
        status: 'SUCCESS',
        message: 'Tabela eliminada.',
      );
      return;
    }

    final id = _requiredString(request, 'id');
    final deleted = await database.deleteRecord(
      table,
      id,
      _optionalString(request['seedShard']),
    );
    _log('DELETE em $table: $id.');
    await _respond(
      socket,
      status: deleted ? 'SUCCESS' : 'ERROR',
      message: deleted ? 'Registro eliminado.' : 'Registro não encontrado.',
    );
  }

  Future<void> _findById(
    Socket socket,
    Map<String, dynamic> request,
  ) async {
    final table = _requiredString(request, 'table');
    final id = _requiredString(request, 'id');
    final record = await database.findById(
      table,
      id,
      _optionalString(request['seedShard']),
    );
    _log('FIND_BY_ID em $table: $id.');
    await _respond(
      socket,
      status: record == null ? 'ERROR' : 'SUCCESS',
      message: record == null
          ? 'Registro não encontrado.'
          : 'Registro encontrado.',
      data: record,
    );
  }

  Future<void> _findByIndex(
    Socket socket,
    Map<String, dynamic> request,
  ) async {
    final table = _requiredString(request, 'table');
    final field = _requiredString(request, 'field');
    if (!request.containsKey('value')) {
      throw const FormatException('O campo value é obrigatório.');
    }

    final records = await database.findByIndex(
      table,
      field,
      request['value'],
      _optionalString(request['seedShard']),
    );
    _log('FIND_BY_INDEX em $table.$field.');
    await _respond(
      socket,
      status: 'SUCCESS',
      message: '${records.length} registro(s) encontrado(s).',
      data: records,
    );
  }

  Future<void> _listTables(Socket socket) async {
    final tables = await database.listTables();
    await _respond(
      socket,
      status: 'SUCCESS',
      message: '${tables.length} tabela(s).',
      data: tables,
    );
  }

  Future<void> _listRecords(
    Socket socket,
    Map<String, dynamic> request,
  ) async {
    final table = _requiredString(request, 'table');
    final records = await database.listRecords(
      table,
      _optionalString(request['seedShard']),
    );
    await _respond(
      socket,
      status: 'SUCCESS',
      message: '${records.length} registro(s).',
      data: records,
    );
  }

  Future<void> _respond(
    Socket socket, {
    required String status,
    required String message,
    dynamic data,
  }) {
    if (!_clients.contains(socket)) {
      return Future<void>.value();
    }
    socket.write(
      '${jsonEncode({
            'status': status,
            'message': message,
            'data': data,
          })}\n',
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

  void _removeClient(Socket socket) {
    _clients.remove(socket);
    _authenticated.remove(socket);
    onConnectionsChanged?.call(connectionCount);
    _log('Cliente desconectado.');
  }

  void _log(String message) {
    onLog?.call('[${DateTime.now().toIso8601String()}] $message');
  }
}
