import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

Live2DProfile _profile(String id, {int rev = 1, String file = 'avatar.model3.json'}) =>
    Live2DProfile.fromJson({
      'schemaVersion': 1,
      'modelId': id,
      'profileRev': rev,
      'modelFile': file,
      'paramMap': {
        'mouthOpen': 'ParamMouthOpenY',
        'blinkLeft': 'ParamEyeLOpen',
        'blinkRight': 'ParamEyeROpen',
        'expressions': {'happy': 'F01'},
        'motions': {'wave': 'Motion01'},
      },
    });

void main() {
  group('Live2DModelStore', () {
    test('save/list/order and active selection', () {
      final store = Live2DModelStore()
        ..save(_profile('model.b'))
        ..save(_profile('model.a'))
        ..setActive('model.a');
      expect(store.models.map((m) => m.modelId), ['model.a', 'model.b']);
      expect(store.activeModelId, 'model.a');
      expect(store.active?.modelId, 'model.a');
    });

    test('rejects non-increasing profile revision for same model id', () {
      final store = Live2DModelStore()..save(_profile('model.a', rev: 2));
      expect(() => store.save(_profile('model.a', rev: 2)), throwsFormatException);
      expect(() => store.save(_profile('model.a', rev: 1)), throwsFormatException);
      store.save(_profile('model.a', rev: 3));
      expect(store.models.single.profileRev, 3);
    });

    test('rejects activating unknown model and clears active on removal', () {
      final store = Live2DModelStore();
      expect(() => store.setActive('missing'), throwsStateError);
      store
        ..save(_profile('model.a'))
        ..setActive('model.a')
        ..remove('model.a');
      expect(store.activeModelId, isNull);
      expect(store.models, isEmpty);
    });

    test('export/import round-trips models and active atomically', () {
      final store = Live2DModelStore()
        ..save(_profile('model.a', rev: 2))
        ..save(_profile('model.b'))
        ..setActive('model.b');
      final restored = Live2DModelStore.fromJson(store.toJson());
      expect(restored.models.map((m) => m.modelId), ['model.a', 'model.b']);
      expect(restored.activeModelId, 'model.b');
      expect(restored.active?.paramMap.mouthOpen, 'ParamMouthOpenY');
    });

    test('import rejects invalid snapshot without mutating existing store', () {
      final store = Live2DModelStore()..save(_profile('model.a'));
      final bad = {
        'schemaVersion': 1,
        'activeModelId': 'missing',
        'models': [(_profile('model.b').toJson())],
      };
      expect(() => Live2DModelStore.fromJson(bad), throwsFormatException);
      expect(store.models.map((m) => m.modelId), ['model.a']);
    });

    test('import rejects duplicate model ids and unknown fields', () {
      expect(
        () => Live2DModelStore.fromJson({
          'schemaVersion': 1,
          'models': [_profile('model.a').toJson(), _profile('model.a').toJson()],
        }),
        throwsFormatException,
      );
      expect(
        () => Live2DModelStore.fromJson({
          'schemaVersion': 1,
          'models': [],
          'modelBytes': [1, 2],
        }),
        throwsFormatException,
      );
    });

    test('snapshot contains no model bytes or absolute paths', () {
      final store = Live2DModelStore()..save(_profile('model.a'));
      final json = store.toJson();
      expect(json.containsKey('modelBytes'), isFalse);
      expect(json.toString(), isNot(contains('C:')));
      expect(json.toString(), isNot(contains('https')));
    });

    test('param map and profile toJson round-trip through parse', () {
      final profile = _profile('model.a', rev: 5);
      final reparsed = Live2DProfile.fromJson(profile.toJson());
      expect(reparsed.modelId, profile.modelId);
      expect(reparsed.profileRev, 5);
      expect(reparsed.paramMap.expressions, {'happy': 'F01'});
    });
  });
}
