import 'dart:io';

import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'default host assembles provider and AI identity migrations and authenticated routes',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'jingyu-model-assembly-',
      );
      final host = await buildHost(config: HostConfig(dataDir: dir.path));
      addTearDown(() async {
        await host.shutdown();
        await dir.delete(recursive: true);
      });
      final db = host.registry.services.get<Database>();
      expect(
        (await db.query(
          'SELECT version FROM schema_migrations ORDER BY version',
        )).map((row) => row['version']),
        [1, 100, 200, 300, 500, 501],
      );
      expect(
        await db.query(
          'SELECT name FROM sqlite_master WHERE type = ? AND name IN (?, ?)',
          ['table', 'providers', 'ai_profile'],
        ),
        hasLength(2),
      );
      final result = await host.pipeline.handle(
        HostRequest(method: 'GET', path: Routes.modelProviders),
      );
      expect(result.status, 401);
      expect(
        host.registry.router.describe().any(
          (route) => route.contains(Routes.modelProvider),
        ),
        isTrue,
      );
    },
  );
}
