import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class ServerConfig {
  static const int defaultPort = 8081;
  static const int defaultHttpPort = 8080;
  static const String defaultPassword = 'abc123';

  const ServerConfig({
    required this.port,
    required this.password,
    required this.basePath,
    this.httpPort = defaultHttpPort,
    this.enableTcp = true,
    this.enableHttp = true,
    this.enableWebSocket = true,
  });

  final int port;
  final String password;
  final String basePath;
  final int httpPort;
  final bool enableTcp;
  final bool enableHttp;
  final bool enableWebSocket;

  ServerConfig copyWith({
    int? port,
    String? password,
    String? basePath,
    int? httpPort,
    bool? enableTcp,
    bool? enableHttp,
    bool? enableWebSocket,
  }) {
    return ServerConfig(
      port: port ?? this.port,
      password: password ?? this.password,
      basePath: basePath ?? this.basePath,
      httpPort: httpPort ?? this.httpPort,
      enableTcp: enableTcp ?? this.enableTcp,
      enableHttp: enableHttp ?? this.enableHttp,
      enableWebSocket: enableWebSocket ?? this.enableWebSocket,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'port': port,
      'httpPort': httpPort,
      'password': password,
      'basePath': basePath,
      'enableTcp': enableTcp,
      'enableHttp': enableHttp,
      'enableWebSocket': enableWebSocket,
    };
  }

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    final rawPort = json['port'];
    final parsedPort = rawPort is int
        ? rawPort
        : int.tryParse(rawPort?.toString() ?? '') ?? defaultPort;
    final safePort = parsedPort.clamp(1, 65535).toInt();
    final hasHttpPort = json.containsKey('httpPort');
    final rawHttpPort = json['httpPort'];
    final parsedHttpPort = rawHttpPort is int
        ? rawHttpPort
        : int.tryParse(rawHttpPort?.toString() ?? '') ?? defaultHttpPort;
    final safeHttpPort = (hasHttpPort
            ? parsedHttpPort
            : safePort == defaultHttpPort
                ? defaultPort
                : defaultHttpPort)
        .clamp(1, 65535)
        .toInt();
    final password = json['password']?.toString().trim();
    final basePath = json['basePath']?.toString().trim();

    return ServerConfig(
      port: safePort,
      httpPort: safeHttpPort,
      password: password == null || password.isEmpty
          ? defaultPassword
          : password,
      basePath: basePath == null || basePath.isEmpty
          ? ''
          : path.normalize(basePath),
      enableTcp: _parseBool(json['enableTcp'], true),
      enableHttp: _parseBool(json['enableHttp'], true),
      enableWebSocket: _parseBool(json['enableWebSocket'], true),
    );
  }

  static bool _parseBool(dynamic value, bool fallback) {
    if (value is bool) {
      return value;
    }
    switch (value?.toString().trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
      case 'sim':
        return true;
      case 'false':
      case '0':
      case 'no':
      case 'nao':
      case 'não':
        return false;
      default:
        return fallback;
    }
  }

  static Future<Directory> _documentsDirectory() async {
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      // This fallback keeps configuration loading usable in Dart tests and
      // environments where the platform path_provider is not registered.
      return Directory.current;
    }
  }

  static Future<File> _configFile() async {
    final directory = await _documentsDirectory();
    return File(path.join(directory.path, 'config.json'));
  }

  static Future<String> defaultBasePath() async {
    final directory = await _documentsDirectory();
    return path.join(directory.path, 'dataniverse_data');
  }

  static Future<ServerConfig> load() async {
    final file = await _configFile();
    if (!await file.exists()) {
      return ServerConfig(
        port: defaultPort,
        password: defaultPassword,
        basePath: await defaultBasePath(),
      );
    }

    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        throw const FormatException('config.json precisa conter um objeto.');
      }

      final loaded = ServerConfig.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      return loaded.basePath.isEmpty
          ? loaded.copyWith(basePath: await defaultBasePath())
          : loaded;
    } catch (_) {
      return ServerConfig(
        port: defaultPort,
        password: defaultPassword,
        basePath: await defaultBasePath(),
      );
    }
  }

  Future<File> save() async {
    final file = await _configFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
      flush: true,
    );
    return file;
  }
}