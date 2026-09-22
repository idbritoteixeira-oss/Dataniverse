import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  bool get isRunning => _serverSocket != null;
  int get connectionCount => _clients.length;

  Future<void> start() async {
    if (isRunning) {
      return;
    }

    _serverSocket = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      config.port,
    );
    _serverSubscription = _serverSocket!.listen(_handleClient);
    _log('Servidor iniciado na porta ${config.port}.');
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

  void _handleClient(Socket socket) {
    _clients.add(socket);
    _authenticated[socket] = false;
    onConnectionsChanged?.call(connectionCount);
    _log(
      'Cliente conectado: ${socket.remoteAddress.address}:${socket.remotePort}.',
    );

    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _handleLine(socket, line),
          onError: (Object error) {
            _log('Erro de comunicação com cliente: $error');
          },
          onDone: () => _removeClient(socket),
        );
  }

  Future<void> _handleLine(Socket socket, String line) async {
    if (line.trim().isEmpty) {
      return;
    }

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
        case 'FIND_BY_ID':
          await _findById(socket, request);
          break;
        case 'FIND_BY_INDEX':
          await _findByIndex(socket, request);
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
      message: record == null ? 'Registro não encontrado.' : 'Registro encontrado.',
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