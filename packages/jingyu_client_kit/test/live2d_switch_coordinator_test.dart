import 'dart:async';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

final class _FakeHost implements Live2DRendererHost {
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  final List<Map<String, Object?>> commands = <Map<String, Object?>>[];

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> send(Map<String, Object?> command) async {
    commands.add(command);
  }

  void emit(Map<String, Object?> event) => _events.add(event);
  Future<void> close() => _events.close();
}

void main() {
  test('preload sends the staged model fields and waits for preloaded',
      () async {
    final host = _FakeHost();
    addTearDown(host.close);
    final coordinator = Live2DSwitchCoordinator(host: host);
    addTearDown(coordinator.close);

    final future = coordinator.preload(
      loadId: 's1',
      modelId: 'm2',
      model3Url: 'https://example.test/m2/model.model3.json',
      textureUrls: const <String>[],
      profileRev: 2,
    );
    expect(host.commands.single, {
      'cmd': 'preload',
      'loadId': 's1',
      'modelId': 'm2',
      'model3': 'https://example.test/m2/model.model3.json',
      'textureUrls': <String>[],
      'profileRev': 2,
    });
    host.emit(<String, Object?>{'event': 'preloaded', 'loadId': 's1'});
    expect((await future)['event'], 'preloaded');
  });

  test('preload rejection carries the viewer code', () async {
    final host = _FakeHost();
    addTearDown(host.close);
    final coordinator = Live2DSwitchCoordinator(host: host);
    addTearDown(coordinator.close);

    final future = coordinator.preload(
      loadId: 's1',
      modelId: 'm2',
      model3Url: 'u',
      textureUrls: const <String>[],
      profileRev: 1,
    );
    host.emit(<String, Object?>{
      'event': 'preload_rejected',
      'loadId': 's1',
      'code': 'texture_budget',
    });
    await expectLater(
      future,
      throwsA(
        isA<Live2DSwitchException>().having(
          (error) => error.code,
          'code',
          'texture_budget',
        ),
      ),
    );
  });

  test('swap waits for swapped and reports swap_failed', () async {
    final host = _FakeHost();
    addTearDown(host.close);
    final coordinator = Live2DSwitchCoordinator(host: host);
    addTearDown(coordinator.close);

    final future = coordinator.swap(loadId: 's1', fadeMs: 300);
    expect(host.commands.single, {
      'cmd': 'swap',
      'loadId': 's1',
      'fadeMs': 300,
    });
    host.emit(<String, Object?>{'event': 'swapped', 'loadId': 's1'});
    expect((await future)['event'], 'swapped');

    final failed = coordinator.swap(loadId: 's2');
    host.emit(<String, Object?>{
      'event': 'swap_failed',
      'loadId': 's2',
      'code': 'render_failed',
      'message': 'incoming first frame failed',
    });
    await expectLater(
      failed,
      throwsA(
        isA<Live2DSwitchException>().having(
          (error) => error.code,
          'code',
          'render_failed',
        ),
      ),
    );
  });

  test('close fails pending calls and prevents new ones', () async {
    final host = _FakeHost();
    addTearDown(host.close);
    final coordinator = Live2DSwitchCoordinator(host: host);

    final pending = coordinator.preload(
      loadId: 's1',
      modelId: 'm2',
      model3Url: 'u',
      textureUrls: const <String>[],
      profileRev: 1,
    );
    final pendingError = expectLater(
      pending,
      throwsA(
        isA<Live2DSwitchException>().having(
          (error) => error.code,
          'code',
          'disposed',
        ),
      ),
    );
    await coordinator.close();
    await pendingError;
    expect(
      () => coordinator.preload(
        loadId: 's2',
        modelId: 'm2',
        model3Url: 'u',
        textureUrls: const <String>[],
        profileRev: 1,
      ),
      throwsStateError,
    );
  });
}
