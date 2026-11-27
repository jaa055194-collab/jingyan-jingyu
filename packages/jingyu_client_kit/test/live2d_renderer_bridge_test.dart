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
      expect(
        () => bridge.parameterCommand('x', double.infinity),
        throwsFormatException,
      );
      // Without a model report, any finite value in the parameter's own
      // units is passed on.
      expect(bridge.parameterCommand('x', -12.5)['value'], -12.5);
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

    test('setParameter checks the reported IDs and ranges', () {
      final bridge = Live2DRendererBridge()..markLoading('m');
      bridge.handleEvent({
        'event': 'ready',
        'modelId': 'm',
        'profileRev': 1,
        'parameters': [
          {'id': 'ParamAngleX', 'min': -30, 'max': 30, 'default': 0},
          {'id': 'ParamOpen', 'default': 0},
        ],
        'parts': <String>[],
      });
      expect(bridge.parameterCommand('ParamAngleX', -30)['value'], -30);
      expect(bridge.parameterCommand('ParamAngleX', 12.5)['value'], 12.5);
      expect(bridge.parameterCommand('ParamOpen', 99)['value'], 99);
      expect(
        () => bridge.parameterCommand('ParamAngleX', 30.5),
        throwsFormatException,
      );
      expect(
        () => bridge.parameterCommand('ParamAngleX', -31),
        throwsFormatException,
      );
      expect(
        () => bridge.parameterCommand('ParamMissing', 0),
        throwsFormatException,
      );
    });

    test('a ready event records the reported model info', () {
      final bridge = Live2DRendererBridge()..markLoading('m');
      expect(bridge.modelInfo, isNull);
      bridge.handleEvent({
        'event': 'ready',
        'modelId': 'm',
        'profileRev': 1,
        'parameters': [
          {'id': 'ParamMouthOpenY', 'min': 0, 'max': 1, 'default': 0},
        ],
        'parts': ['PartMouth'],
      });
      expect(bridge.state, Live2DRendererState.ready);
      expect(bridge.modelInfo!.parameterIds, {'ParamMouthOpenY'});
      expect(bridge.modelInfo!.partIds, {'PartMouth'});
      expect(bridge.modelInfoError, isNull);
    });

    test('a ready event without ID lists reports them as unknown', () {
      final bridge = Live2DRendererBridge()
        ..markLoading('m')
        ..handleEvent({'event': 'ready', 'modelId': 'm', 'profileRev': 1});
      expect(bridge.modelInfo!.parameters, isNull);
      expect(bridge.modelInfo!.parts, isNull);
      expect(bridge.modelInfo!.expressions, isNull);
      expect(bridge.modelInfo!.motions, isNull);
      expect(bridge.modelInfoError, isNull);
    });

    test('a ready event records reported expressions and motions', () {
      final bridge = Live2DRendererBridge()..markLoading('m');
      bridge.handleEvent({
        'event': 'ready',
        'modelId': 'm',
        'profileRev': 1,
        'expressions': ['F01'],
        'motions': [
          {'group': 'Idle', 'count': 2},
        ],
      });
      expect(bridge.state, Live2DRendererState.ready);
      expect(bridge.modelInfo!.expressionNames, {'F01'});
      expect(bridge.modelInfo!.motionCount('Idle'), 2);
      expect(bridge.modelInfoError, isNull);
    });

    test('a malformed model report does not fail the ready event', () {
      final bridge = Live2DRendererBridge()..markLoading('m');
      bridge.handleEvent({
        'event': 'ready',
        'modelId': 'm',
        'profileRev': 1,
        'parts': ['PartMouth', 'PartMouth'],
      });
      expect(bridge.state, Live2DRendererState.ready);
      expect(bridge.lastError, isNull);
      expect(bridge.modelInfo, isNull);
      expect(bridge.modelInfoError, contains('repeats'));
    });

    test('a bad expression or motion list keeps the preview ready', () {
      final bad = <String, Map<String, Object?>>{
        'expressions must be a list': {'expressions': 'F01'},
        'motions[0].count must be an integer': {
          'motions': [
            {'group': 'Idle', 'count': 0},
          ],
        },
      };
      for (final entry in bad.entries) {
        final bridge = Live2DRendererBridge()..markLoading('m');
        bridge.handleEvent({
          'event': 'ready',
          'modelId': 'm',
          'profileRev': 1,
          'parameters': [
            {'id': 'ParamMouthOpenY'},
          ],
          ...entry.value,
        });
        expect(bridge.state, Live2DRendererState.ready);
        expect(bridge.lastError, isNull);
        expect(bridge.modelInfo, isNull);
        expect(bridge.modelInfoError, contains(entry.key));
      }
    });

    test('a new load, an error or dispose clears the model info', () {
      Live2DRendererBridge reported(Object? parts) => Live2DRendererBridge()
        ..markLoading('m')
        ..handleEvent({
          'event': 'ready',
          'modelId': 'm',
          'profileRev': 1,
          'parts': parts,
        });

      expect((reported(['A'])..markLoading('n')).modelInfo, isNull);
      expect((reported(['A'])..markError('boom')).modelInfo, isNull);
      expect(
        (reported(['A'])..handleEvent({'event': 'error', 'message': 'lost'}))
            .modelInfo,
        isNull,
      );
      expect((reported(['A'])..dispose()).modelInfo, isNull);

      final rejected = reported('A');
      expect(rejected.modelInfoError, isNotNull);
      rejected.markLoading('m');
      expect(rejected.modelInfoError, isNull);
    });
  });
}
