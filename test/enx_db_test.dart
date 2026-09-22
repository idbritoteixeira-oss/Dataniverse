import 'dart:io';

import 'package:dataniverse_server/database/enx_db.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('insere e consulta registros por ID e índice', () async {
    final temporaryDirectory =
        await Directory.systemTemp.createTemp('dataniverse_db_test_');

    try {
      final database = EnXDB(basePath: temporaryDirectory.path);
      final inserted = await database.insert(
        'ottsvision/logs',
        {
          'level': 'info',
          'message': 'servidor online',
        },
        'seed_1',
      );

      final byId = await database.findById(
        'ottsvision/logs',
        inserted['id'] as String,
        'seed_1',
      );
      final byIndex = await database.findByIndex(
        'ottsvision/logs',
        'level',
        'info',
        'seed_1',
      );

      expect(byId?['message'], 'servidor online');
      expect(byId?['action_hash'], isA<String>());
      expect(byIndex, hasLength(1));
      expect(
        File(
          '${temporaryDirectory.path}/ottsvision/logs/seed_1/records/'
          '${inserted['id']}.json',
        ).existsSync(),
        isTrue,
      );
    } finally {
      await temporaryDirectory.delete(recursive: true);
    }
  });
}