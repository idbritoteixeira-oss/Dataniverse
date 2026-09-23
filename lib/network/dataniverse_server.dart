import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/server_config.dart';
import '../database/enx_db.dart';

typedef ServerLogCallback = void Function(String message);
typedef ConnectionCountCallback = void Function(int count);

class _SessionResult {
  const _SessionResult({
    required this.response,
    required this.authenticated,
  });

  final Map<String, dynamic> response;
  final bool authenticated;
}

/// Servidor Dataniverse com TCP, HTTP REST e WebSocket.
///
/// TCP usa JSON delimitado por quebra de linha na porta [ServerConfig.port].
/// HTTP e WebSocket usam [ServerConfig.httpPort]. O WebSocket fica disponível
/// em `/ws` e a API REST em `/command`.
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

  ServerSocket? _tcpServer;
  StreamSubscription<Socket>? _tcpSubscription;
  HttpServer? _httpServer;
  StreamSubscription<HttpRequest>? _httpSubscription;

  final Set<Socket> _tcpClients = {};
  final Map<Socket, bool> _tcpAuthenticated = {};
  final Set<WebSocket> _webSocketClients = {};
  final Map<WebSocket, bool> _webSocketAuthenticated = {};
  int _activeHttpRequests = 0;

  String? publicIp;

  bool get isRunning => _tcpServer != null || _httpServer != null;
  int get connectionCount =>
      _tcpClients.length + _webSocketClients.length + _activeHttpRequests;

  Future<void> start() async {
    if (isRunning) {
      return;
    }
    if (!config.enableTcp && !config.enableHttp) {
      throw StateError('Ative pelo menos um protocolo do servidor.');
    }
    if (config.enableTcp &&
        config.enableHttp &&
        config.port == config.httpPort) {
      throw StateError(
        'As portas TCP e HTTP precisam ser diferentes.',
      );
    }

    await database.ensureStructure();

    try {
      if (config.enableTcp) {
        _tcpServer = await _bindTcpServer(config.port);
        _tcpSubscription = _tcpServer!.listen(_handleTcpClient);
        _log(
          'Servidor TCP iniciado em ${_tcpServer!.address.address}:'
          '${config.port}.',
        );
      }

      if (config.enableHttp) {
        _httpServer = await _bindHttpServer(config.httpPort);
        _httpSubscription = _httpServer!.listen(_handleHttpRequest);
        _log(
          'Servidor HTTP${config.enableWebSocket ? '/WebSocket' : ''} '
          'iniciado em ${_httpServer!.address.address}:${config.httpPort}.',
        );
      }

      unawaited(_detectPublicIp());
    } catch (_) {
      await _closeResources();
      rethrow;
    }
  }

  Future<ServerSocket> _bindTcpServer(int port) async {
    try {
      return await ServerSocket.bind(
        InternetAddress.anyIPv6,
        port,
        v6Only: false,
      );
    } on SocketException catch (error) {
      _log('IPv6 indisponível para TCP ($error); usando IPv4.');
      return ServerSocket.bind(InternetAddress.anyIPv4, port);
    }
  }

  Future<HttpServer> _bindHttpServer(int port) async {
    try {
      return await HttpServer.bind(
        InternetAddress.anyIPv6,
        port,
        v6Only: false,
      );
    } on SocketException catch (error) {
      _log('IPv6 indisponível para HTTP/WebSocket ($error); usando IPv4.');
      return HttpServer.bind(InternetAddress.anyIPv4, port);
    }
  }

  Future<void> stop() async {
    await _closeResources();
    onConnectionsChanged?.call(0);
    _log('Servidor parado.');
  }

  Future<void> _closeResources() async {
    final tcpServer = _tcpServer;
    final httpServer = _httpServer;
    _tcpServer = null;
    _httpServer = null;

    await _tcpSubscription?.cancel();
    await _httpSubscription?.cancel();
    _tcpSubscription = null;
    _httpSubscription = null;
    await tcpServer?.close();
    await httpServer?.close(force: true);

    for (final socket in _tcpClients.toList()) {
      socket.destroy();
    }
    _tcpClients.clear();
    _tcpAuthenticated.clear();

    for (final webSocket in _webSocketClients.toList()) {
      try {
        await webSocket.close();
      } catch (_) {
        // A conexão pode já ter sido encerrada pelo cliente.
      }
    }
    _webSocketClients.clear();
    _webSocketAuthenticated.clear();
    _activeHttpRequests = 0;
  }

  Future<void> _detectPublicIp() async {
    try {
      final response = await http
          .get(Uri.parse('https://api64.ipify.org'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode == HttpStatus.ok) {
        publicIp = response.body.trim();
        _log('IP público: $publicIp');
      }
    } catch (_) {
      _log('Não foi possível detectar o IP público.');
    }
  }

  void _handleTcpClient(Socket socket) {
    _tcpClients.add(socket);
    _tcpAuthenticated[socket] = false;
    _notifyConnections();
    _log(
      'Cliente TCP conectado: '
      '${socket.remoteAddress.address}:${socket.remotePort}.',
    );

    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => unawaited(_handleTcpLine(socket, line)),
          onError: (Object error) {
            _log('Erro de comunicação TCP: $error');
          },
          onDone: () => _removeTcpClient(socket),
        );
  }

  Future<void> _handleTcpLine(Socket socket, String line) async {
    if (line.trim().isEmpty || !_tcpClients.contains(socket)) {
      return;
    }

    try {
      final request = _decodeRequest(line);
      final result = await _processSessionRequest(
        request,
        authenticated: _tcpAuthenticated[socket] ?? false,
      );
      _tcpAuthenticated[socket] = result.authenticated;
      await _respondSocket(socket, result.response);
    } catch (error) {
      _log('Requisição TCP inválida: $error');
      await _respondSocket(
        socket,
        _response(
          status: 'ERROR',
          message: error.toString(),
        ),
      );
    }
  }

  void _handleHttpRequest(HttpRequest request) {
    unawaited(_processHttpRequest(request));
  }

  Future<void> _processHttpRequest(HttpRequest request) async {
    final connection = request.connectionInfo;
    final clientAddress = connection?.remoteAddress.address ?? 'desconhecido';
    final clientPort = connection?.remotePort;
    _log(
      'Conexão HTTP recebida de $clientAddress:${clientPort ?? '?'} '
      '${request.method} ${request.uri.path}.',
    );
    _addHttpRequest();
    _applyCors(request.response);

    try {
      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }

      final route = request.uri.path;
      if (request.method == 'GET' && (route == '/' || route.isEmpty)) {
        await _serveStatus(request);
        return;
      }
      if (request.method == 'GET' && route == '/health') {
        await _writeHttpJson(
          request,
          HttpStatus.ok,
          _response(
            status: 'SUCCESS',
            message: 'Servidor online.',
            data: {
              'tcp': config.enableTcp,
              'http': config.enableHttp,
              'websocket': config.enableWebSocket,
              'tcpPort': config.port,
              'httpPort': config.httpPort,
            },
          ),
        );
        return;
      }
      if (route == '/ws') {
        await _upgradeWebSocket(request);
        return;
      }
      if (request.method == 'POST' && route == '/command') {
        await _handleHttpCommand(request);
        return;
      }

      await _writeHttpJson(
        request,
        HttpStatus.notFound,
        _response(status: 'ERROR', message: 'Rota não encontrada.'),
      );
    } catch (error) {
      _log('Erro HTTP: $error');
      if (!request.response.headers.contentType.toString().contains('json')) {
        await _writeHttpJson(
          request,
          HttpStatus.internalServerError,
          _response(status: 'ERROR', message: error.toString()),
        );
      }
    } finally {
      _removeHttpRequest();
    }
  }

  Future<void> _handleHttpCommand(HttpRequest request) async {
    final password = request.headers.value('x-password') ?? '';
    if (password != config.password) {
      _log(
        'Tentativa HTTP não autorizada de '
        '${request.connectionInfo?.remoteAddress.address}.',
      );
      await _writeHttpJson(
        request,
        HttpStatus.unauthorized,
        _response(
          status: 'ERROR',
          message: 'Senha inválida. Envie o header X-Password.',
        ),
      );
      return;
    }

    final body = await utf8.decoder.bind(request).join();
    final decoded = _decodeRequest(body);
    _log(
      'Requisição HTTP recebida de '
      '${request.connectionInfo?.remoteAddress.address}.',
    );
    final response = await _executeCommand(decoded);
    final statusCode =
        response['status'] == 'SUCCESS' ? HttpStatus.ok : HttpStatus.badRequest;
    await _writeHttpJson(request, statusCode, response);
  }

  Future<void> _upgradeWebSocket(HttpRequest request) async {
    if (!config.enableWebSocket) {
      await _writeHttpJson(
        request,
        HttpStatus.notFound,
        _response(status: 'ERROR', message: 'WebSocket desativado.'),
      );
      return;
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      await _writeHttpJson(
        request,
        HttpStatus.badRequest,
        _response(
          status: 'ERROR',
          message: 'Use uma requisição WebSocket em /ws.',
        ),
      );
      return;
    }

    final webSocket = await WebSocketTransformer.upgrade(request);
    _webSocketClients.add(webSocket);
    _webSocketAuthenticated[webSocket] = false;
    _notifyConnections();
    final connection = request.connectionInfo;
    _log(
      'Cliente WebSocket conectado de '
      '${connection?.remoteAddress.address ?? 'desconhecido'}:'
      '${connection?.remotePort ?? '?'}.',
    );

    webSocket.listen(
      (message) => unawaited(_handleWebSocketMessage(webSocket, message)),
      onError: (Object error) {
        _log('Erro de comunicação WebSocket: $error');
      },
      onDone: () => _removeWebSocket(webSocket),
    );
  }

  Future<void> _handleWebSocketMessage(
    WebSocket webSocket,
    dynamic message,
  ) async {
    if (!_webSocketClients.contains(webSocket)) {
      return;
    }

    try {
      if (message is! String) {
        throw const FormatException('A mensagem WebSocket precisa ser texto.');
      }
      final request = _decodeRequest(message);
      final result = await _processSessionRequest(
        request,
        authenticated: _webSocketAuthenticated[webSocket] ?? false,
      );
      _webSocketAuthenticated[webSocket] = result.authenticated;
      webSocket.add(jsonEncode(result.response));
    } catch (error) {
      _log('Requisição WebSocket inválida: $error');
      webSocket.add(
        jsonEncode(
          _response(status: 'ERROR', message: error.toString()),
        ),
      );
    }
  }

  Future<_SessionResult> _processSessionRequest(
    Map<String, dynamic> request, {
    required bool authenticated,
  }) async {
    final action = request['action']?.toString().toUpperCase();
    _log('Requisição recebida: ${action ?? 'sem action'}.');

    if (action == 'PING') {
      return _SessionResult(
        response: {
          'status': 'PONG',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        },
        authenticated: authenticated,
      );
    }

    if (!authenticated) {
      if (action != 'AUTH') {
        return const _SessionResult(
          response: {
            'status': 'ERROR',
            'message': 'Autenticação obrigatória. Envie AUTH primeiro.',
            'data': null,
          },
          authenticated: false,
        );
      }
      if (request['password']?.toString() != config.password) {
        _log('Tentativa de autenticação recusada.');
        return const _SessionResult(
          response: {
            'status': 'ERROR',
            'message': 'Senha inválida.',
            'data': null,
          },
          authenticated: false,
        );
      }

      _log('Cliente autenticado.');
      return const _SessionResult(
        response: {
          'status': 'SUCCESS',
          'message': 'Autenticação realizada.',
          'data': null,
        },
        authenticated: true,
      );
    }

    return _SessionResult(
      response: await _executeCommand(request),
      authenticated: true,
    );
  }

  Future<Map<String, dynamic>> _executeCommand(
    Map<String, dynamic> request,
  ) async {
    final action = request['action']?.toString().toUpperCase();
    switch (action) {
      case 'PING':
        return {
          'status': 'PONG',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
        };
      case 'INSERT':
        return _insert(request);
      case 'UPDATE':
        return _update(request);
      case 'DELETE':
        return _delete(request);
      case 'FIND_BY_ID':
        return _findById(request);
      case 'FIND_BY_INDEX':
        return _findByIndex(request);
      case 'LIST_TABLES':
        return _listTables();
      case 'LIST_RECORDS':
        return _listRecords(request);
      default:
        return _response(
          status: 'ERROR',
          message: 'Ação desconhecida: ${request['action']}.',
        );
    }
  }

  Future<Map<String, dynamic>> _insert(Map<String, dynamic> request) async {
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
    return _response(
      status: 'SUCCESS',
      message: 'Registro inserido.',
      data: record,
    );
  }

  Future<Map<String, dynamic>> _update(Map<String, dynamic> request) async {
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
    return _response(
      status: 'SUCCESS',
      message: 'Registro atualizado.',
      data: record,
    );
  }

  Future<Map<String, dynamic>> _delete(Map<String, dynamic> request) async {
    final table = _requiredString(request, 'table');
    final seedShard = _optionalString(request['seedShard']);
    if (!request.containsKey('id') ||
        request['id']?.toString().trim().isEmpty == true) {
      await database.deleteTable(table, seedShard);
      _log('DELETE tabela $table.');
      return _response(
        status: 'SUCCESS',
        message: 'Tabela eliminada.',
      );
    }

    final id = _requiredString(request, 'id');
    final deleted = await database.deleteRecord(table, id, seedShard);
    _log('DELETE em $table: $id.');
    return _response(
      status: deleted ? 'SUCCESS' : 'ERROR',
      message: deleted
          ? 'Registro eliminado.'
          : 'Registro não encontrado.',
    );
  }

  Future<Map<String, dynamic>> _findById(
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
    return _response(
      status: record == null ? 'ERROR' : 'SUCCESS',
      message: record == null
          ? 'Registro não encontrado.'
          : 'Registro encontrado.',
      data: record,
    );
  }

  Future<Map<String, dynamic>> _findByIndex(
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
    return _response(
      status: 'SUCCESS',
      message: '${records.length} registro(s) encontrado(s).',
      data: records,
    );
  }

  Future<Map<String, dynamic>> _listTables() async {
    final tables = await database.listTables();
    return _response(
      status: 'SUCCESS',
      message: '${tables.length} tabela(s).',
      data: tables,
    );
  }

  Future<Map<String, dynamic>> _listRecords(
    Map<String, dynamic> request,
  ) async {
    final table = _requiredString(request, 'table');
    final records = await database.listRecords(
      table,
      _optionalString(request['seedShard']),
    );
    return _response(
      status: 'SUCCESS',
      message: '${records.length} registro(s).',
      data: records,
    );
  }

  Future<void> _serveStatus(HttpRequest request) async {
    final html = '''
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Dataniverse Server</title>
</head>
<body style="font-family:system-ui;background:#0f172a;color:#e2e8f0;padding:32px">
  <h1>Dataniverse Server</h1>
  <p>Servidor online.</p>
  <ul>
    <li>TCP: ${config.enableTcp ? 'porta ${config.port}' : 'desativado'}</li>
    <li>HTTP: ${config.enableHttp ? 'porta ${config.httpPort}' : 'desativado'}</li>
    <li>WebSocket: ${config.enableWebSocket ? '/ws' : 'desativado'}</li>
    <li>IP público: ${publicIp ?? 'detectando...'}</li>
  </ul>
  <p>API REST: <code>POST /command</code> com header <code>X-Password</code>.</p>
</body>
</html>
''';
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(html);
    await request.response.close();
    _log('Página de status servida.');
  }

  Future<void> _writeHttpJson(
    HttpRequest request,
    int statusCode,
    Map<String, dynamic> body,
  ) async {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _respondSocket(
    Socket socket,
    Map<String, dynamic> response,
  ) {
    if (!_tcpClients.contains(socket)) {
      return Future<void>.value();
    }
    socket.write('${jsonEncode(response)}\n');
    return Future<void>.value();
  }

  Map<String, dynamic> _decodeRequest(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('O comando precisa ser um objeto JSON.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Map<String, dynamic> _response({
    required String status,
    required String message,
    dynamic data,
  }) {
    return {
      'status': status,
      'message': message,
      'data': data,
    };
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

  void _applyCors(HttpResponse response) {
    response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..set(
        'Access-Control-Allow-Headers',
        'Content-Type, X-Password',
      );
  }

  void _addHttpRequest() {
    _activeHttpRequests++;
    _notifyConnections();
  }

  void _removeHttpRequest() {
    if (_activeHttpRequests > 0) {
      _activeHttpRequests--;
      _notifyConnections();
    }
  }

  void _removeTcpClient(Socket socket) {
    _tcpClients.remove(socket);
    _tcpAuthenticated.remove(socket);
    _notifyConnections();
    _log('Cliente TCP desconectado.');
  }

  void _removeWebSocket(WebSocket webSocket) {
    _webSocketClients.remove(webSocket);
    _webSocketAuthenticated.remove(webSocket);
    _notifyConnections();
    _log('Cliente WebSocket desconectado.');
  }

  void _notifyConnections() {
    onConnectionsChanged?.call(connectionCount);
  }

  void _log(String message) {
    onLog?.call('[${DateTime.now().toIso8601String()}] $message');
  }
}