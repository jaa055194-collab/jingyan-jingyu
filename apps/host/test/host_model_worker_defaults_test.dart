import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/models/model_runtime.dart';
import 'package:jingyu_host/src/models/models_module.dart';
import 'package:test/test.dart';

void main() {
  final entryPoint = File('bin/server.dart').absolute.uri;
  final sdkExecutable = Platform.resolvedExecutable;

  Future<Directory> isolatedDirectory() async {
    final dir = await Directory.systemTemp.createTemp('jingyu-worker-default-');
    addTearDown(() => dir.delete(recursive: true));
    return dir;
  }

  test('a full environment pair wins over source defaults', () async {
    final dir = await isolatedDirectory();
    final executable = File.fromUri(dir.uri.resolve('custom-dart')).path;
    final worker = File.fromUri(dir.uri.resolve('custom-worker.dart')).path;
    final config = HostConfig.forServer(
      {
        'JINGYU_MODEL_WORKER_EXECUTABLE': executable,
        'JINGYU_MODEL_WORKER_PATH': worker,
      },
      script: entryPoint,
      resolvedExecutable: sdkExecutable,
      onWorkerUnavailable: fail,
    );
    expect(config.modelWorkerExecutable, executable);
    expect(config.modelWorkerPath, worker);
  });

  test('a partial override does not mix explicit and default paths', () {
    final worker = File('bin/http_worker.dart').absolute.path;
    final config = HostConfig.forServer(
      {'JINGYU_MODEL_WORKER_PATH': worker},
      script: entryPoint,
      resolvedExecutable: sdkExecutable,
      onWorkerUnavailable: fail,
    );
    expect(config.modelWorkerPath, worker);
    expect(config.modelWorkerExecutable, isNull);
    expect(
      () => defaultModules(config, const SystemClock()),
      throwsArgumentError,
    );
  });

  test('source default comes from the entry point, not the cwd', () async {
    final dir = await isolatedDirectory();
    final worker = File.fromUri(dir.uri.resolve('bin/http_worker.dart'));
    await worker.create(recursive: true);
    final config = HostConfig.forServer(
      {'JINGYU_DATA_DIR': dir.path},
      script: dir.uri.resolve('bin/server.dart'),
      resolvedExecutable: sdkExecutable,
      onWorkerUnavailable: fail,
    );
    expect(config.modelWorkerExecutable, sdkExecutable);
    expect(config.modelWorkerPath, worker.path);
  });

  test(
    'plain source startup assembles and launches the packaged worker',
    () async {
      final dir = await isolatedDirectory();
      final config = HostConfig.forServer(
        {'JINGYU_DATA_DIR': dir.path},
        script: entryPoint,
        resolvedExecutable: sdkExecutable,
        onWorkerUnavailable: fail,
      );
      expect(
        config.modelWorkerPath,
        File.fromUri(
          Directory.current.uri.resolve('bin/http_worker.dart'),
        ).path,
      );
      final modules = defaultModules(config, const SystemClock());
      final host = await buildHost(config: config, modules: modules);
      addTearDown(host.shutdown);
      expect(host.registry.services.maybeGet<ModelRuntime>(), isNotNull);

      // No parent URL check is involved here. The structured forbidden response
      // proves the actual child launched and rejected loopback before any I/O.
      final request = modules
          .whereType<ModelsModule>()
          .single
          .providerDiscoveryRequest!;
      final result = await request(
        'GET',
        Uri.parse('http://127.0.0.1/v1/models'),
      );
      expect(result.failureOrNull?.code, FailureCode.forbidden);
      print(
        'PACKAGED_WORKER runtime=registered launch=confirmed loopback=forbidden',
      );
    },
  );

  test(
    'missing default worker reports the problem and leaves chat disabled',
    () async {
      final dir = await isolatedDirectory();
      final diagnostics = <String>[];
      final config = HostConfig.forServer(
        {'JINGYU_DATA_DIR': dir.path},
        script: dir.uri.resolve('bin/server.dart'),
        resolvedExecutable: sdkExecutable,
        onWorkerUnavailable: diagnostics.add,
      );
      expect(config.modelWorkerExecutable, isNull);
      expect(config.modelWorkerPath, isNull);
      expect(diagnostics.single, contains('http_worker.dart'));
      final host = await buildHost(config: config);
      addTearDown(host.shutdown);
      expect(host.registry.services.maybeGet<ModelRuntime>(), isNull);
    },
  );

  test('missing default SDK executable cannot enable the worker', () async {
    final dir = await isolatedDirectory();
    final diagnostics = <String>[];
    final config = HostConfig.forServer(
      {'JINGYU_DATA_DIR': dir.path},
      script: entryPoint,
      resolvedExecutable: File.fromUri(dir.uri.resolve('missing-dart')).path,
      onWorkerUnavailable: diagnostics.add,
    );
    expect(config.modelWorkerExecutable, isNull);
    expect(config.modelWorkerPath, isNull);
    expect(diagnostics.single, contains('Dart'));
  });
}
