import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

void main() {
  group('Live2DRendererBridge', () {
    test('starts idle and transitions loading -> ready', () {
      final bridge = Live2DRendererBridge();
      expect(bridge.state, Live2DRendererState.idle);
      bridge.markLoading('model.a');
      expect(bridge.state, Live2DRendererState.loading);
      expect(bridge.modelId, 'model.a');
      bridge.markReady('model.a', profileRev: 2);
      expect(bridge.state, Live2DRendererState.ready);
      expect(bridge.profileRev, 2);
    });

    test('rejects ready before loading', () {
      final bridge = Live2DRendererBridge();
      expect(
        () => bridge.markReady('model.a', profileRev: 1),
        throwsStateError,
      );
    });

    test('captures error and allows reload', () {
      final bridge = Live2DRendererBridge()..markLoading('model.a');
      bridge.markError('gpu out of memory');
      expect(bridge.state, Live2DRendererState.error);
      expect(bridge.lastError, 'gpu out of memory');
      bridge.markLoading('model.b');
      expect(bridge.state, Live2DRendererState.loading);
      expect(bridge.lastError, isNull);
    });

    test('builds load command without model bytes', () {
      final bridge = Live2DRendererBridge();
      final cmd = bridge.loadCommand(
        modelId: 'model.a',
        model3Url: 'app://live2d/model/a.model3.json',
        textureUrls: const ['app://live2d/model/tex0.png'],
        profileRev: 3,
      );
      expect(cmd['cmd'], 'load');
      expect(cmd['modelId'], 'model.a');
      expect(cmd['profileRev'], 3);
      expect((cmd['textureUrls'] as List).length, 1);
      expect(cmd.containsKey('bytes'), isFalse);
    });

    test('load command keeps the viewer protocol texture key', () {
      final bridge = Live2DRendererBridge();
      final cmd = bridge.loadCommand(
        modelId: 'm',
        model3Url: 'http://127.0.0.1:8000/model.model3.json',
        textureUrls: const ['http://127.0.0.1:8000/texture-0.png'],
        profileRev: 1,
      );
      expect(cmd['textureUrls'], ['http://127.0.0.1:8000/texture-0.png']);
      expect(cmd.containsKey('textures'), isFalse);
    });

    test('validates parameter and expression commands', () {
      final bridge = Live2DRendererBridge()
        ..markLoading('m')
        ..markReady('m', profileRev: 1);
      expect(bridge.parameterCommand('ParamMouthOpenY', 0.5)['value'], 0.5);
      expect(() => bridge.parameterCommand('', 0.5), throwsFormatException);
      expect(
        () => bridge.parameterCommand('x', double.nan),
        throwsFormatException,
      );
      expect(() => bridge.parameterCommand('x', 1.5), throwsFormatException);
      expect(bridge.expressionCommand('happy')['name'], 'happy');
      expect(() => bridge.expressionCommand(' '), throwsFormatException);
      expect(bridge.motionCommand('Idle', 0)['group'], 'Idle');
      expect(() => bridge.motionCommand('Idle', -1), throwsFormatException);
    });

    test('parses incoming events strictly', () {
      final bridge = Live2DRendererBridge()..markLoading('m');
      bridge.handleEvent({'event': 'ready', 'modelId': 'm', 'profileRev': 1});
      expect(bridge.state, Live2DRendererState.ready);
      expect(
        () => bridge.handleEvent({'event': 'unknown'}),
        throwsFormatException,
      );
      expect(
        () => bridge.handleEvent({'event': 'error'}),
        throwsFormatException,
      );
    });

    test('rejects duplicate ready and mismatched ready events', () {
      final bridge = Live2DRendererBridge()..markLoading('m');
      bridge.handleEvent({'event': 'ready', 'modelId': 'm', 'profileRev': 1});
      expect(
        () => bridge.handleEvent({
          'event': 'ready',
          'modelId': 'm',
          'profileRev': 1,
        }),
        throwsStateError,
      );

      final other = Live2DRendererBridge()..markLoading('m');
      expect(
        () => other.handleEvent({
          'event': 'ready',
          'modelId': 'other',
          'profileRev': 1,
        }),
        throwsStateError,
      );
      expect(
        () => other.handleEvent({
          'event': 'ready',
          'modelId': 'm',
          'profileRev': 0,
        }),
        throwsFormatException,
      );
    });

    test('rejects an error event before any load starts', () {
      final bridge = Live2DRendererBridge();
      expect(
        () => bridge.handleEvent({'event': 'error', 'message': 'boom'}),
        throwsStateError,
      );
    });

    test('accepts a runtime error after ready and records it', () {
      final bridge = Live2DRendererBridge()
        ..markLoading('m')
        ..markReady('m', profileRev: 1);
      bridge.handleEvent({'event': 'error', 'message': 'context lost'});
      expect(bridge.state, Live2DRendererState.error);
      expect(bridge.lastError, 'context lost');
      expect(() => bridge.parameterCommand('p', 0.1), throwsStateError);
    });

    test('dispose is terminal and idempotent', () {
      final bridge = Live2DRendererBridge()..markLoading('m');
      bridge.dispose();
      expect(bridge.state, Live2DRendererState.disposed);
      bridge.dispose();
      expect(bridge.state, Live2DRendererState.disposed);
      expect(() => bridge.markLoading('m'), throwsStateError);
      expect(bridge.disposeCommand()['cmd'], 'dispose');
    });

    test('setParameter refused unless ready', () {
      final bridge = Live2DRendererBridge();
      expect(() => bridge.parameterCommand('p', 0.1), throwsStateError);
    });
  });
}
