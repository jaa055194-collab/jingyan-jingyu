import 'dart:io';
import 'package:jingyu_core/jingyu_core.dart';

import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host/src/models/model_runtime.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'trusted process worker configuration assembles runtime without starting a child',
    () async {
      final worker = File('bin/http_worker.dart').absolute.path;
      final envConfig = HostConfig.fromEnvironment({
        'JINGYU_MODEL_WORKER_EXECUTABLE': Platform.resolvedExecutable,
        'JINGYU_MODEL_WORKER_PATH': worker,
      });
      expect(envConfig.modelWorkerPath, worker);
      expect(
        () => defaultModules(
          const HostConfig(modelWorkerPath: 'missing'),
          const SystemClock(),
        ),
        throwsArgumentError,
      );
      final dir = await Directory.systemTemp.createTemp(
        'jingyu-model-runtime-assembly-',
      );
      final host = await buildHost(
        config: HostConfig(
          dataDir: dir.path,
          modelWorkerExecutable: envConfig.modelWorkerExecutable,
          modelWorkerPath: worker,
        ),
      );
      addTearDown(() async {
        await host.shutdown();
        await dir.delete(recursive: true);
      });
      expect(host.registry.services.maybeGet<ModelRuntime>(), isNotNull);
    },
  );

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
        [
          1,
          100,
          200,
          205,
          206,
          300,
          301,
          302,
          303,
          304,
          500,
          501,
          502,
          503,
          504,
        ],
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
        (await host.pipeline.handle(
          HostRequest(
            method: 'GET',
            path: Routes.groupTopics.replaceFirst('{conversationId}', 'group'),
          ),
        )).status,
        401,
      );
      expect(
        (await host.pipeline.handle(
          HostRequest(
            method: 'GET',
            path: Routes.topicReferences.replaceFirst('{topicId}', 'topic'),
          ),
        )).status,
        401,
      );
      expect(
        host.registry.router.describe().any(
          (route) => route.contains(Routes.modelProvider),
        ),
        isTrue,
      );
    },
  );
}
