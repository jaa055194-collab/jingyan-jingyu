import 'dart:async';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

final class FakeLive2DRendererHost implements Live2DRendererHost {
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  final List<Map<String, Object?>> commands = <Map<String, Object?>>[];
  Object? sendError;

  /// Runs inside [send] after the command is recorded and before [send]
  /// completes, so a test can deliver events while a command is in flight.
  Future<void> Function(Map<String, Object?> command)? onSend;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> send(Map<String, Object?> command) async {
    final error = sendError;
    if (error != null) throw error;
    commands.add(command);
    final hook = onSend;
    if (hook != null) await hook(command);
  }

  void emit(Map<String, Object?> event) => _events.add(event);

  void emitError(Object error) => _events.addError(error);

  Future<void> close() => _events.close();
}

void main() {
  group('Live2DPreviewController', () {
    late FakeLive2DRendererHost host;
    late Live2DPreviewController controller;

    setUp(() {
      host = FakeLive2DRendererHost();
      controller = Live2DPreviewController(host: host);
    });

    tearDown(() async {
      await controller.close();
      await host.close();
    });

    test(
      'starts loading, sends the load command and waits for first frame',
      () async {
        final ready = controller.start(
          modelId: 'model.a',
          model3Url: 'http://127.0.0.1:8000/model.model3.json',
          textureUrls: const ['http://127.0.0.1:8000/texture-0.png'],
          profileRev: 2,
        );
        expect(controller.state, Live2DPreviewState.loading);
        expect(host.commands, hasLength(1));
        expect(host.commands.single['cmd'], 'load');
        expect(host.commands.single['modelId'], 'model.a');
        expect(host.commands.single['profileRev'], 2);
        expect(host.commands.single['textureUrls'], hasLength(1));
        expect(host.commands.single.containsKey('bytes'), isFalse);

        host.emit({'event': 'ready', 'modelId': 'model.a', 'profileRev': 2});
        await ready;
        expect(controller.state, Live2DPreviewState.ready);
        expect(controller.error, isNull);
      },
    );

    test('an error event fails the preview and can be retried', () async {
      final first = controller.start(
        modelId: 'model.a',
        model3Url: 'http://127.0.0.1:8000/model.model3.json',
        textureUrls: const [],
        profileRev: 1,
      );
      host.emit({'event': 'error', 'message': 'texture upload failed'});
      await expectLater(
        first,
        throwsA(
          isA<Live2DPreviewException>().having(
            (error) => error.message,
            'message',
            contains('texture upload'),
          ),
        ),
      );
      expect(controller.state, Live2DPreviewState.failed);

      final second = controller.retry();
      expect(controller.state, Live2DPreviewState.loading);
      expect(host.commands, hasLength(2));
      host.emit({'event': 'ready', 'modelId': 'model.a', 'profileRev': 1});
      await second;
      expect(controller.state, Live2DPreviewState.ready);
    });

    test(
      'a host send failure fails the preview without waiting for events',
      () async {
        host.sendError = StateError('webview disposed');
        await expectLater(
          controller.start(
            modelId: 'model.a',
            model3Url: 'http://127.0.0.1:8000/model.model3.json',
            textureUrls: const [],
            profileRev: 1,
          ),
          throwsA(isA<Live2DPreviewException>()),
        );
        expect(controller.state, Live2DPreviewState.failed);
      },
    );

    test(
      'first-frame timeout fails, sends dispose and ignores a late ready',
      () async {
        final controller = Live2DPreviewController(
          host: host,
          firstFrameTimeout: const Duration(milliseconds: 30),
        );
        addTearDown(controller.close);
        final loading = controller.start(
          modelId: 'model.a',
          model3Url: 'http://127.0.0.1:8000/model.model3.json',
          textureUrls: const [],
          profileRev: 1,
        );
        await expectLater(
          loading,
          throwsA(
            isA<Live2DPreviewException>().having(
              (error) => error.timedOut,
              'timedOut',
              isTrue,
            ),
          ),
        );
        expect(controller.state, Live2DPreviewState.failed);
        expect(
          host.commands.map((command) => command['cmd']),
          containsAllInOrder(['load', 'dispose']),
        );

        host.emit({'event': 'ready', 'modelId': 'model.a', 'profileRev': 1});
        await Future<void>.delayed(Duration.zero);
        expect(controller.state, Live2DPreviewState.failed);
      },
    );

    test('an invalid ready event fails the preview', () async {
      final loading = controller.start(
        modelId: 'model.a',
        model3Url: 'http://127.0.0.1:8000/model.model3.json',
        textureUrls: const [],
        profileRev: 1,
      );
      host.emit({'event': 'ready', 'modelId': 'model.b', 'profileRev': 1});
      await expectLater(loading, throwsA(isA<Live2DPreviewException>()));
      expect(controller.state, Live2DPreviewState.failed);
    });

    test('close is idempotent, sends dispose once and is terminal', () async {
      await controller.close();
      await controller.close();
      expect(controller.state, Live2DPreviewState.disposed);
      expect(host.commands, hasLength(1));
      expect(host.commands.single['cmd'], 'dispose');
      expect(
        () => controller.start(
          modelId: 'model.a',
          model3Url: 'http://127.0.0.1:8000/model.model3.json',
          textureUrls: const [],
          profileRev: 1,
        ),
        throwsStateError,
      );
    });

    test('events before a load are ignored', () async {
      host.emit({'event': 'error', 'message': 'stray'});
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, Live2DPreviewState.idle);
      expect(controller.error, isNull);
    });

    test('closing while loading completes with a failure', () async {
      final loading = controller.start(
        modelId: 'model.a',
        model3Url: 'http://127.0.0.1:8000/model.model3.json',
        textureUrls: const [],
        profileRev: 1,
      );
      final expectation = expectLater(
        loading,
        throwsA(
          isA<Live2DPreviewException>().having(
            (error) => error.message,
            'message',
            'preview closed',
          ),
        ),
      );
      await controller.close();
      await expectation;
      expect(controller.state, Live2DPreviewState.disposed);
    });

    Future<void> startReady() async {
      final ready = controller.start(
        modelId: 'model.a',
        model3Url: 'http://127.0.0.1:8000/model.model3.json',
        textureUrls: const [],
        profileRev: 1,
      );
      host.emit({'event': 'ready', 'modelId': 'model.a', 'profileRev': 1});
      await ready;
      expect(controller.state, Live2DPreviewState.ready);
    }

    test('host errors before a load are ignored', () async {
      host.emitError(StateError('stray'));
      await pumpEventQueue();
      expect(controller.state, Live2DPreviewState.idle);
      expect(controller.failure, isNull);
    });

    test(
      'a viewer error after ready fails the preview with its message',
      () async {
        await startReady();
        host.emit({'event': 'error', 'message': 'WebGL context lost'});
        await pumpEventQueue();
        expect(controller.state, Live2DPreviewState.failed);
        expect(controller.error, 'WebGL context lost');
        expect(controller.failure?.message, 'WebGL context lost');
        expect(controller.failure?.timedOut, isFalse);
        expect(controller.failure?.cause, isNull);
      },
    );

    test(
      'a host stream error after ready fails the preview with its cause',
      () async {
        await startReady();
        final gone = StateError('render process gone');
        host.emitError(gone);
        await pumpEventQueue();
        expect(controller.state, Live2DPreviewState.failed);
        expect(controller.error, contains('render process gone'));
        expect(controller.failure?.cause, same(gone));
      },
    );

    test(
      'a host stream error while loading rejects start with its cause',
      () async {
        final loading = controller.start(
          modelId: 'model.a',
          model3Url: 'http://127.0.0.1:8000/model.model3.json',
          textureUrls: const [],
          profileRev: 1,
        );
        final failure = StateError('page load failed');
        host.emitError(failure);
        await expectLater(
          loading,
          throwsA(
            isA<Live2DPreviewException>().having(
              (error) => error.cause,
              'cause',
              same(failure),
            ),
          ),
        );
        expect(controller.state, Live2DPreviewState.failed);
        expect(controller.failure?.cause, same(failure));
      },
    );

    test(
      'frame pings and repeated ready events after ready change nothing',
      () async {
        await startReady();
        host
          ..emit({'event': 'frame'})
          ..emit({'event': 'ready', 'modelId': 'model.a', 'profileRev': 1});
        await pumpEventQueue();
        expect(controller.state, Live2DPreviewState.ready);
        expect(controller.failure, isNull);
      },
    );

    test('a failure after ready can be retried', () async {
      await startReady();
      host.emit({'event': 'error', 'message': 'WebGL context lost'});
      await pumpEventQueue();
      expect(controller.state, Live2DPreviewState.failed);

      final again = controller.retry();
      expect(controller.state, Live2DPreviewState.loading);
      expect(controller.failure, isNull);
      expect(
        host.commands.where((command) => command['cmd'] == 'load'),
        hasLength(2),
      );
      host.emit({'event': 'ready', 'modelId': 'model.a', 'profileRev': 1});
      await again;
      expect(controller.state, Live2DPreviewState.ready);
    });

    test('states reports each change in order and close() ends it', () async {
      expect(controller.states.isBroadcast, isTrue);
      final seen = controller.states.toList();
      await startReady();
      host.emit({'event': 'error', 'message': 'WebGL context lost'});
      await pumpEventQueue();
      final again = controller.retry();
      host.emit({'event': 'ready', 'modelId': 'model.a', 'profileRev': 1});
      await again;
      await controller.close();
      expect(await seen, [
        Live2DPreviewState.loading,
        Live2DPreviewState.ready,
        Live2DPreviewState.failed,
        Live2DPreviewState.loading,
        Live2DPreviewState.ready,
        Live2DPreviewState.disposed,
      ]);
    });

    test(
      'a ready that lands while the load command is in flight does not '
      'time out later',
      () async {
        final controller = Live2DPreviewController(
          host: host,
          firstFrameTimeout: const Duration(milliseconds: 30),
        );
        addTearDown(controller.close);
        host.onSend = (command) async {
          if (command['cmd'] != 'load') return;
          host.emit({'event': 'ready', 'modelId': 'model.a', 'profileRev': 1});
          await pumpEventQueue();
        };
        await controller.start(
          modelId: 'model.a',
          model3Url: 'http://127.0.0.1:8000/model.model3.json',
          textureUrls: const [],
          profileRev: 1,
        );
        expect(controller.state, Live2DPreviewState.ready);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(controller.state, Live2DPreviewState.ready);
        expect(host.commands.map((command) => command['cmd']).toList(), [
          'load',
        ]);
      },
    );

    test(
      'a late send failure from a superseded load does not fail the newer one',
      () async {
        final firstSend = Completer<void>();
        host.onSend = (command) => host.commands.length == 1
            ? firstSend.future
            : Future<void>.value();
        final first = controller.start(
          modelId: 'model.a',
          model3Url: 'http://127.0.0.1:8000/a.model3.json',
          textureUrls: const [],
          profileRev: 1,
        );
        final superseded = expectLater(
          first,
          throwsA(
            isA<Live2DPreviewException>().having(
              (error) => error.message,
              'message',
              'preview superseded',
            ),
          ),
        );
        final second = controller.start(
          modelId: 'model.b',
          model3Url: 'http://127.0.0.1:8000/b.model3.json',
          textureUrls: const [],
          profileRev: 1,
        );
        firstSend.completeError(StateError('old webview gone'));
        await superseded;
        await pumpEventQueue();
        expect(controller.state, Live2DPreviewState.loading);

        host.emit({'event': 'ready', 'modelId': 'model.b', 'profileRev': 1});
        await second;
        expect(controller.state, Live2DPreviewState.ready);
      },
    );

    test(
      'exposes the model report while ready and replaces it on retry',
      () async {
        final first = controller.start(
          modelId: 'model.a',
          model3Url: 'http://127.0.0.1:8000/model.model3.json',
          textureUrls: const [],
          profileRev: 1,
        );
        expect(controller.modelInfo, isNull);
        host.emit({
          'event': 'ready',
          'modelId': 'model.a',
          'profileRev': 1,
          'parameters': [
            {'id': 'ParamEyeLOpen', 'min': 0, 'max': 1, 'default': 1},
          ],
          'parts': ['PartEye'],
        });
        await first;
        final info = controller.modelInfo!;
        expect(info.parameter('ParamEyeLOpen')!.defaultValue, 1.0);
        expect(info.partIds, {'PartEye'});
        expect(controller.modelInfoError, isNull);

        host.emit({'event': 'error', 'message': 'context lost'});
        await pumpEventQueue();
        expect(controller.state, Live2DPreviewState.failed);
        expect(controller.modelInfo, isNull);

        final second = controller.retry();
        expect(controller.modelInfo, isNull);
        host.emit({
          'event': 'ready',
          'modelId': 'model.a',
          'profileRev': 1,
          'parts': ['PartMouth'],
        });
        await second;
        expect(controller.modelInfo!.parameters, isNull);
        expect(controller.modelInfo!.partIds, {'PartMouth'});
      },
    );

    test('a malformed model report keeps the preview ready', () async {
      final ready = controller.start(
        modelId: 'model.a',
        model3Url: 'http://127.0.0.1:8000/model.model3.json',
        textureUrls: const [],
        profileRev: 1,
      );
      host.emit({
        'event': 'ready',
        'modelId': 'model.a',
        'profileRev': 1,
        'parameters': [
          {'id': 'ParamAngleX', 'min': 30, 'max': -30},
        ],
      });
      await ready;
      expect(controller.state, Live2DPreviewState.ready);
      expect(controller.error, isNull);
      expect(controller.modelInfo, isNull);
      expect(controller.modelInfoError, contains('minimum above its maximum'));
    });
  });
}
