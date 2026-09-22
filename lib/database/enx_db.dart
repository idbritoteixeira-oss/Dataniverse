import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

class EnXDB {
  EnXDB({required this.basePath});

  final String basePath;
  final Map<String, Future<void>> _locks = {};

  Future<Map<String, dynamic>> insert(
    String table,
    Map<String, dynamic> data, [
    String? seedShard,
  ]) async {
    final tableDirectory = _tableDirectory(table, seedShard);
    final lockKey = tableDirectory.path;

    return _withLock(lockKey, () async {
      final recordsDirectory = Directory(
        path.join(tableDirectory.path, 'records'),
      );
      final indexDirectory = Directory(
        path.join(tableDirectory.path, 'index'),
      );
      await recordsDirectory.create(recursive: true);
      await indexDirectory.create(recursive: true);

      final record = Map<String, dynamic>.from(data);
      final requestedId = (record['id']?.toString().trim().isNotEmpty ?? false)
          ? record['id'].toString()
          : _generateId(record);
      final id = _safeSegment(requestedId);

      record['id'] = id;
      record.putIfAbsent(
        'created_at',
        () => DateTime.now().toUtc().toIso8601String(),
      );
      record.remove('action_hash');
      record['action_hash'] =
          sha256.convert(utf8.encode(jsonEncode(record))).toString();

      final recordFile = File(path.join(recordsDirectory.path, '$id.json'));
      await recordFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(record),
        flush: true,
      );
      await _updateIndexes(indexDirectory, id, record);

      return record;
    });
  }

  Future<Map<String, dynamic>?> findById(
    String table,
    String id, [
    String? seedShard,
  ]) async {
    final tableDirectory = _tableDirectory(table, seedShard);
    final recordFile = File(
      path.join(tableDirectory.path, 'records', '${_safeSegment(id)}.json'),
    );
    if (!await recordFile.exists()) {
      return null;
    }

    final decoded = jsonDecode(await recordFile.readAsString());
    if (decoded is! Map) {
      return null;
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<List<Map<String, dynamic>>> findByIndex(
    String table,
    String field,
    dynamic value, [
    String? seedShard,
  ]) async {
    final tableDirectory = _tableDirectory(table, seedShard);
    final indexFile = File(
      path.join(
        tableDirectory.path,
        'index',
        'idx_${_safeField(field)}.db',
      ),
    );
    if (!await indexFile.exists()) {
      return [];
    }

    final decoded = jsonDecode(await indexFile.readAsString());
    if (decoded is! Map) {
      return [];
    }

    final ids = List<String>.from(decoded[_indexKey(value)] ?? const []);
    final results = <Map<String, dynamic>>[];
    for (final id in ids) {
      final record = await findById(table, id, seedShard);
      if (record != null) {
        results.add(record);
      }
    }
    return results;
  }

  Directory _tableDirectory(String table, String? seedShard) {
    final tableSegments = _routeSegments(table);
    final routeSegments = <String>[
      ...tableSegments,
      if (seedShard != null && seedShard.trim().isNotEmpty)
        _safeSegment(seedShard),
    ];
    return Directory(path.joinAll([basePath, ...routeSegments]));
  }

  List<String> _routeSegments(String table) {
    final normalized = table.trim().replaceAll('\\', '/');
    if (normalized.isEmpty) {
      throw const FormatException('A tabela é obrigatória.');
    }

    final segments = normalized.split('/');
    if (segments.any((segment) => segment.isEmpty)) {
      throw const FormatException('Rota de tabela inválida.');
    }
    return segments.map(_safeSegment).toList(growable: false);
  }

  String _safeSegment(String value) {
    final segment = value.trim();
    if (segment.isEmpty || segment == '.' || segment == '..') {
      throw const FormatException('Segmento de caminho inválido.');
    }
    if (segment.contains('/') || segment.contains('\\')) {
      throw const FormatException('Segmento de caminho inválido.');
    }
    return segment;
  }

  String _safeField(String field) {
    final normalized = field.trim();
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(normalized)) {
      throw const FormatException('Nome de campo inválido para índice.');
    }
    return normalized;
  }

  Future<void> _updateIndexes(
    Directory indexDirectory,
    String id,
    Map<String, dynamic> record,
  ) async {
    for (final entry in record.entries) {
      final field = entry.key;
      if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(field)) {
        continue;
      }

      final indexFile = File(
        path.join(indexDirectory.path, 'idx_$field.db'),
      );
      Map<String, dynamic> index = {};
      if (await indexFile.exists()) {
        final existing = jsonDecode(await indexFile.readAsString());
        if (existing is Map) {
          index = Map<String, dynamic>.from(existing);
        }
      }

      final key = _indexKey(entry.value);
      final ids = List<String>.from(index[key] ?? const []);
      if (!ids.contains(id)) {
        ids.add(id);
      }
      index[key] = ids;
      await indexFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(index),
        flush: true,
      );
    }
  }

  String _indexKey(dynamic value) => jsonEncode(value);

  String _generateId(Map<String, dynamic> data) {
    final source =
        '${DateTime.now().microsecondsSinceEpoch}:${jsonEncode(data)}';
    return sha256.convert(utf8.encode(source)).toString().substring(0, 24);
  }

  Future<T> _withLock<T>(
    String key,
    Future<T> Function() action,
  ) async {
    final previous = _locks[key] ?? Future<void>.value();
    final release = Completer<void>();
    _locks[key] = release.future;

    try {
      await previous;
      return await action();
    } finally {
      release.complete();
      if (identical(_locks[key], release.future)) {
        _locks.remove(key);
      }
    }
  }
}