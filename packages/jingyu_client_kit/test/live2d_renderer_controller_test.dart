import 'dart:async';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

final class FakeLive2DRendererHost implements Live2DRendererHost {
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  final List<Map<String, Object?>> commands = <Map<String, Object?>>[];
  Object? sendError;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> send(Map<String, Object?> command) async {
    final error = sendError;
    if (error != null) throw error;
    commands.add(command);
  }

  void emit(Map<String, Object?> event) => _events.add(event);

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
  });
}
