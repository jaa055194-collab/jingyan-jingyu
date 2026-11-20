import 'dart:collection';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

Map<String, Object?> _mapping() => {
  'mouthOpen': 'ParamMouthOpenY',
  'blinkLeft': 'ParamEyeLOpen',
  'blinkRight': 'ParamEyeROpen',
  'expressions': {'happy': 'F01'},
  'motions': {'wave': 'Motion01'},
};

Map<String, Object?> _profile() => {
  'schemaVersion': 1,
  'modelId': 'model.default',
  'profileRev': 2,
  'modelFile': 'avatar.model3.json',
  'paramMap': _mapping(),
};

void main() {
  group('Live2DProfile', () {
    test('accepts explicit local files and parameter mappings', () {
      final profile = Live2DProfile.fromJson(_profile());
      expect(profile.modelId, 'model.default');
      expect(profile.profileRev, 2);
      expect(profile.modelFile, 'avatar.model3.json');
      expect(profile.paramMap.mouthOpen, 'ParamMouthOpenY');
      expect(profile.paramMap.expressions, {'happy': 'F01'});
      expect(profile.paramMap.motions, {'wave': 'Motion01'});
    });

    for (final path in [
      '../outside.model3.json',
      '/absolute.model3.json',
      r'C:\models\avatar.model3.json',
      'https://example.invalid/avatar.model3.json',
      'folder/../../outside.model3.json',
      'folder/CON.model3.json',
      'folder /avatar.model3.json',
      'folder/avatar\u0001.model3.json',
      'folder//avatar.model3.json',
      './avatar.model3.json',
      'avatar.png',
      ' avatar.model3.json',
      'avatar.model3.json ',
    ]) {
      test('rejects unsafe/noncanonical model path: $path', () {
        // All other fields are valid, so only the path can cause rejection.
        expect(
          () => Live2DProfile.fromJson(_profile()..['modelFile'] = path),
          throwsFormatException,
        );
      });
    }

    test('accepts canonical nested Unicode model path', () {
      final profile = Live2DProfile.fromJson(
        _profile()..['modelFile'] = '模型/大肥鱼.model3.json',
      );
      expect(profile.modelFile, '模型/大肥鱼.model3.json');
    });

    for (final key in [
      'mouthOpen',
      'blinkLeft',
      'blinkRight',
      'expressions',
      'motions',
    ]) {
      test('rejects missing mapping: $key', () {
        expect(
          () => Live2DProfile.fromJson(
            _profile()..['paramMap'] = (_mapping()..remove(key)),
          ),
          throwsFormatException,
        );
      });
    }
    for (final key in ['expressions', 'motions']) {
      test('rejects empty mapping: $key', () {
        expect(
          () => Live2DProfile.fromJson(
            _profile()
              ..['paramMap'] = (_mapping()..[key] = <String, Object?>{}),
          ),
          throwsFormatException,
        );
      });
      test('rejects empty target in mapping: $key', () {
        expect(
          () => Live2DProfile.fromJson(
            _profile()..['paramMap'] = (_mapping()..[key] = {'happy': ' '}),
          ),
          throwsFormatException,
        );
      });
    }
    test('rejects empty required parameter', () {
      expect(
        () => Live2DProfile.fromJson(
          _profile()..['paramMap'] = (_mapping()..['mouthOpen'] = ' '),
        ),
        throwsFormatException,
      );
    });

    for (final value in [null, 0, 2, 1.0, '1']) {
      test(
        'rejects unsupported/noninteger schema: $value (${value.runtimeType})',
        () {
          expect(
            () => Live2DProfile.fromJson(_profile()..['schemaVersion'] = value),
            throwsFormatException,
          );
        },
      );
    }
    for (final value in [null, 0, -1, 1.0, '1']) {
      test('rejects invalid revision: $value (${value.runtimeType})', () {
        expect(
          () => Live2DProfile.fromJson(_profile()..['profileRev'] = value),
          throwsFormatException,
        );
      });
    }
    test(
      'rejects unknown profile fields rather than preserving model data',
      () {
        expect(
          () => Live2DProfile.fromJson(_profile()..['modelBytes'] = [1, 2]),
          throwsFormatException,
        );
      },
    );
    test('rejects unknown parameter mapping fields', () {
      expect(
        () => Live2DProfile.fromJson(
          _profile()..['paramMap'] = (_mapping()..['code'] = 'execute'),
        ),
        throwsFormatException,
      );
    });
    test('mapping snapshot is detached and immutable', () {
      final mapping = _mapping();
      final expressions = mapping['expressions']! as Map<String, String>;
      final profile = Live2DProfile.fromJson(
        _profile()..['paramMap'] = mapping,
      );
      expressions['happy'] = 'changed';
      expect(profile.paramMap.expressions, {'happy': 'F01'});
      expect(
        () => profile.paramMap.expressions['happy'] = 'changed',
        throwsUnsupportedError,
      );
    });
  });

  group('Live2DParamMap.validateTargets', () {
    const parameterIds = {
      'ParamMouthOpenY',
      'ParamEyeLOpen',
      'ParamEyeROpen',
      'CustomJaw',
    };
    const expressionIds = {'F01', 'F02', 'F03'};
    const motionIds = {'Motion01', 'Motion02', 'Motion03'};

    void validate(
      Live2DParamMap mapping, {
      Set<String> parameters = parameterIds,
      Set<String> expressions = expressionIds,
      Set<String> motions = motionIds,
    }) => mapping.validateTargets(
      parameters: parameters,
      expressions: expressions,
      motions: motions,
    );

    test('accepts exact targets in a larger model inventory', () {
      final mapping = Live2DParamMap.fromJson(
        _mapping()
          ..['mouthOpen'] = 'CustomJaw'
          ..['expressions'] = {'happy': 'F01', 'sad': 'F02'}
          ..['motions'] = {'wave': 'Motion01', 'idle': 'Motion02'},
      );

      expect(() => validate(mapping), returnsNormally);
    });

    for (final field in ['mouthOpen', 'blinkLeft', 'blinkRight']) {
      for (final (target, reason) in [
        ('missing', 'missing'),
        ('F01', 'wrong-kind'),
      ]) {
        test('rejects $field mapped to a $reason target', () {
          final mapping = Live2DParamMap.fromJson(_mapping()..[field] = target);

          expect(() => validate(mapping), throwsFormatException);
        });
      }
    }

    for (final (field, semantic, validTarget, wrongKindTarget) in [
      ('expressions', 'happy', 'F01', 'Motion01'),
      ('motions', 'wave', 'Motion01', 'F01'),
    ]) {
      for (final (target, reason) in [
        ('missing', 'missing'),
        (wrongKindTarget, 'wrong-kind'),
      ]) {
        test('rejects a $reason second target in $field', () {
          final mapping = Live2DParamMap.fromJson(
            _mapping()..[field] = {semantic: validTarget, 'another': target},
          );

          expect(() => validate(mapping), throwsFormatException);
        });
      }
    }

    test('rejects a case mismatch even in a case-insensitive input set', () {
      final mapping = Live2DParamMap.fromJson(_mapping());
      final expressions = SplayTreeSet<String>(
        (left, right) => left.toLowerCase().compareTo(right.toLowerCase()),
      )..add('f01');

      expect(
        () => validate(mapping, expressions: expressions),
        throwsFormatException,
      );
    });

    test('does not trim targets supplied by the runtime inventory', () {
      final mapping = Live2DParamMap.fromJson(_mapping());

      expect(
        () => validate(mapping, motions: {' Motion01 '}),
        throwsFormatException,
      );
    });

    for (final kind in ['parameters', 'expressions', 'motions']) {
      test('rejects an empty $kind inventory', () {
        final mapping = Live2DParamMap.fromJson(_mapping());

        expect(
          () => validate(
            mapping,
            parameters: kind == 'parameters' ? const {} : parameterIds,
            expressions: kind == 'expressions' ? const {} : expressionIds,
            motions: kind == 'motions' ? const {} : motionIds,
          ),
          throwsFormatException,
        );
      });
    }
  });
}
