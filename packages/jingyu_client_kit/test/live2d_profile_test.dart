import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

Map<String, Object?> _mapping() => {
  'mouthOpen': 'ParamMouthOpenY',
  'blinkLeft': 'ParamEyeLOpen',
  'blinkRight': 'ParamEyeROpen',
  'noExpressions': false,
  'noMotions': false,
  'expressions': {'happy': 'F01'},
  'motions': {
    'wave': {'group': 'Idle', 'index': 0},
  },
};

Map<String, Object?> _profile() => {
  'schemaVersion': 1,
  'modelId': 'model.default',
  'profileRev': 2,
  'modelFile': 'avatar.model3.json',
  'paramMap': _mapping(),
};

// A FormatException whose message pins the parser branch that rejected.
Matcher _throwsFormat(String text) => throwsA(
  isA<FormatException>().having((e) => e.message, 'message', contains(text)),
);

void main() {
  group('Live2DProfile', () {
    test('accepts explicit local files and parameter mappings', () {
      final profile = Live2DProfile.fromJson(_profile());
      expect(profile.modelId, 'model.default');
      expect(profile.profileRev, 2);
      expect(profile.modelFile, 'avatar.model3.json');
      expect(profile.paramMap.mouthOpen, 'ParamMouthOpenY');
      expect(profile.paramMap.expressions, {'happy': 'F01'});
      expect(profile.paramMap.noExpressions, isFalse);
      expect(profile.paramMap.noMotions, isFalse);
      expect(profile.paramMap.toJson()['motions'], {
        'wave': {'group': 'Idle', 'index': 0},
      });
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

  group('D1-B expressions and motions', () {
    for (final (key, flag) in [
      ('expressions', 'noExpressions'),
      ('motions', 'noMotions'),
    ]) {
      test('accepts an empty $key map when $flag is true', () {
        final profile = Live2DProfile.fromJson(
          _profile()
            ..['paramMap'] = (_mapping()
              ..[flag] = true
              ..[key] = <String, Object?>{}),
        );
        final json = profile.paramMap.toJson();
        expect(json[flag], isTrue);
        expect(json[key], isEmpty);
        expect(
          Live2DProfile.fromJson(profile.toJson()).toJson(),
          profile.toJson(),
        );
      });

      // Each case also names the parser branch that must reject it.
      for (final (reason, mapping, message) in [
        (
          'a full map, $flag true',
          _mapping()..[flag] = true,
          'must be empty when $flag is true',
        ),
        (
          'an empty map, $flag false',
          _mapping()..[key] = <String, Object?>{},
          'may be empty only when $flag is true',
        ),
        (
          'an empty map, $flag absent',
          _mapping()
            ..remove(flag)
            ..[key] = <String, Object?>{},
          '$flag must be true or false',
        ),
        (
          'a full map, $flag absent',
          _mapping()..remove(flag),
          '$flag must be true or false',
        ),
        (
          'no map, $flag true',
          _mapping()
            ..[flag] = true
            ..remove(key),
          '$key must be explicitly configured',
        ),
        for (final value in <Object?>[null, 'true', 1, 0])
          (
            '$flag ${value.runtimeType} $value',
            _mapping()..[flag] = value,
            '$flag must be true or false',
          ),
        for (final value in <Object?>[null, <Object?>[], 'none'])
          (
            '$key ${value.runtimeType}',
            _mapping()..[key] = value,
            '$key must be an object',
          ),
      ]) {
        test('rejects $key: $reason', () {
          expect(
            () => Live2DParamMap.fromJson(mapping),
            _throwsFormat(message),
          );
        });
      }
    }

    Map<String, Object?> modelWithNone() => _mapping()
      ..['noExpressions'] = true
      ..['noMotions'] = true
      ..['expressions'] = <String, Object?>{}
      ..['motions'] = <String, Object?>{};

    test('accepts a model with neither expressions nor motions', () {
      final map = Live2DParamMap.fromJson(modelWithNone());
      expect([map.noExpressions, map.noMotions], [true, true]);
      expect(map.expressions, isEmpty);
      expect(map.motions, isEmpty);
    });

    for (final field in ['mouthOpen', 'blinkLeft', 'blinkRight']) {
      test('true flags do not relax the $field mapping', () {
        expect(
          () => Live2DParamMap.fromJson(modelWithNone()..remove(field)),
          _throwsFormat('$field must be a non-empty string'),
        );
      });
    }

    test('accepts the VRM expression preset keys and no other key', () {
      final all = {
        for (final key in Live2DParamMap.expressionKeys) key: 'F_$key',
      };
      final map = Live2DParamMap.fromJson(_mapping()..['expressions'] = all);
      expect(map.expressions, all);
      for (final key in ['Happy', 'joy', 'wave']) {
        expect(
          () => Live2DParamMap.fromJson(
            _mapping()..['expressions'] = {key: 'F01'},
          ),
          _throwsFormat('must be one of'),
        );
      }
    });
  });

  group('Live2DParamMap.validateTargets', () {
    const parameter = Live2DTargetKind.parameter;
    const expression = Live2DTargetKind.expression;
    const motion = Live2DTargetKind.motion;

    // The runtime's ready event; tests change one kind at a time.
    Map<String, Object?> ready() => {
      'parameters': [
        for (final id in [
          'ParamMouthOpenY',
          'ParamEyeLOpen',
          'ParamEyeROpen',
          'CustomJaw',
        ])
          {'id': id},
      ],
      'expressions': ['F01', 'F02', 'F03'],
      'motions': [
        {'group': 'Idle', 'count': 2},
        {'group': '', 'count': 1},
      ],
    };

    Live2DModelInfo info([Map<String, Object?>? event]) =>
        Live2DModelInfo.fromReadyEvent(event ?? ready());

    // Every miss of a rejected mapping, or an empty list when it passes.
    List<(String, Live2DTargetKind, String, int?, bool)> misses(
      Live2DParamMap mapping,
      Live2DModelInfo model,
    ) {
      try {
        mapping.validateTargets(model);
        return const [];
      } on Live2DTargetException catch (error) {
        return [
          for (final miss in error.misses)
            (miss.field, miss.kind, miss.target, miss.index, miss.reported),
        ];
      }
    }

    test('accepts exact targets in a larger model inventory', () {
      final mapping = Live2DParamMap.fromJson(
        _mapping()
          ..['mouthOpen'] = 'CustomJaw'
          ..['expressions'] = {'happy': 'F01', 'sad': 'F03'}
          ..['motions'] = {
            'wave': {'group': 'Idle', 'index': 1},
            'nod': {'group': '', 'index': 0},
          },
      );
      expect(misses(mapping, info()), isEmpty);
    });

    test('lists every missing target in mapping order', () {
      final mapping = Live2DParamMap.fromJson(
        _mapping()
          ..['mouthOpen'] = 'F01'
          ..['blinkRight'] = 'Missing'
          ..['expressions'] = {
            'happy': 'ParamEyeLOpen',
            'sad': 'F02',
            'angry': 'F09',
          }
          ..['motions'] = {
            'wave': {'group': 'Idle', 'index': 2},
            'nod': {'group': 'F01', 'index': 0},
            'idle': {'group': 'Idle', 'index': 1},
          },
      );
      expect(misses(mapping, info()), [
        ('mouthOpen', parameter, 'F01', null, true),
        ('blinkRight', parameter, 'Missing', null, true),
        ('expressions[happy]', expression, 'ParamEyeLOpen', null, true),
        ('expressions[angry]', expression, 'F09', null, true),
        ('motions[wave]', motion, 'Idle', 2, true),
        ('motions[nod]', motion, 'F01', 0, true),
      ]);
    });

    test('matches runtime names exactly, with no case folding or trim', () {
      final model = info(
        ready()
          ..['parameters'] = [
            {'id': 'parammouthopeny'},
            {'id': ' ParamEyeLOpen '},
            {'id': 'ParamEyeROpen'},
          ]
          ..['expressions'] = ['f01', ' F01 ']
          ..['motions'] = [
            {'group': 'idle', 'count': 1},
            {'group': ' Idle ', 'count': 1},
          ],
      );
      expect(misses(Live2DParamMap.fromJson(_mapping()), model), [
        ('mouthOpen', parameter, 'ParamMouthOpenY', null, true),
        ('blinkLeft', parameter, 'ParamEyeLOpen', null, true),
        ('expressions[happy]', expression, 'F01', null, true),
        ('motions[wave]', motion, 'Idle', 0, true),
      ]);
    });

    for (final (kind, fields) in [
      ('parameters', ['mouthOpen', 'blinkLeft', 'blinkRight']),
      ('expressions', ['expressions[happy]']),
      ('motions', ['motions[wave]']),
    ]) {
      test('lists every target as unchecked when the runtime omits $kind', () {
        final mapping = Live2DParamMap.fromJson(_mapping());
        final found = misses(mapping, info(ready()..remove(kind)));
        expect([for (final miss in found) miss.$1], fields);
        expect(found.any((miss) => miss.$5), isFalse);
      });

      test('rejects every target when the runtime reports no $kind', () {
        final mapping = Live2DParamMap.fromJson(_mapping());
        final found = misses(mapping, info(ready()..[kind] = <Object?>[]));
        expect([for (final miss in found) miss.$1], fields);
        expect(found.every((miss) => miss.$5), isTrue);
      });
    }

    test('checks no expression or motion when the model has none', () {
      final mapping = Live2DParamMap.fromJson(
        _mapping()
          ..['noExpressions'] = true
          ..['noMotions'] = true
          ..['expressions'] = <String, Object?>{}
          ..['motions'] = <String, Object?>{},
      );
      final model = info(
        ready()
          ..remove('expressions')
          ..remove('motions'),
      );
      expect(misses(mapping, model), isEmpty);
    });

    test('throws a FormatException that names every miss', () {
      final mapping = Live2DParamMap.fromJson(_mapping()..['blinkLeft'] = 'X');
      expect(
        () => mapping.validateTargets(info(ready()..remove('motions'))),
        throwsA(
          isA<Live2DTargetException>()
              .having((e) => e.misses, 'misses', hasLength(2))
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('paramMap.blinkLeft: unknown parameter target "X"'),
                  contains(
                    'paramMap.motions[wave]: the runtime did not report',
                  ),
                ),
              ),
        ),
      );
    });
  });

  group('Live2DMotionTarget', () {
    Live2DParamMap withMotions(Map<String, Object?> motions) =>
        Live2DParamMap.fromJson(_mapping()..['motions'] = motions);
    const last = Live2DModelInfo.maxMotionsPerGroup - 1;

    test('reads a group and an index and writes them back', () {
      final map = withMotions({
        'wave': {'group': 'Idle', 'index': 3},
        'nod': {'group': '', 'index': last},
      });
      expect(map.motions['wave']!.group, 'Idle');
      expect(map.motions['wave']!.index, 3);
      expect(map.motions['nod']!.group, isEmpty);
      expect(map.motions['nod']!.index, last);
      expect(Live2DParamMap.fromJson(map.toJson()).motions, map.motions);
    });

    final long = 'x' * (Live2DModelInfo.maxIdLength + 1);
    for (final (target, reason) in <(Object?, String)>[
      ('Motion01', 'a bare name'),
      (null, 'null'),
      ({'group': 'Idle'}, 'no index'),
      ({'index': 0}, 'no group'),
      (
        {'group': 'Idle', 'index': 0, 'file': 'a.motion3.json'},
        'an extra field',
      ),
      ({'group': 1, 'index': 0}, 'a non-string group'),
      ({'group': long, 'index': 0}, 'an over-long group'),
      ({'group': 'Idle', 'index': -1}, 'a negative index'),
      ({'group': 'Idle', 'index': 1.5}, 'a fractional index'),
      ({'group': 'Idle', 'index': '0'}, 'a string index'),
      ({'group': 'Idle', 'index': last + 1}, 'an index past the cap'),
    ]) {
      test('rejects a motion target with $reason', () {
        expect(() => withMotions({'wave': target}), throwsFormatException);
      });
    }

    test('holds at most maxMotions mappings, keyed once each', () {
      const max = Live2DParamMap.maxMotions;
      Map<String, Object?> motions(int count) => {
        for (var i = 0; i < count; i++) 'm$i': {'group': 'Idle', 'index': 0},
      };
      expect(withMotions(motions(max)).motions, hasLength(max));
      expect(
        () => withMotions(motions(max + 1)),
        _throwsFormat('more than $max'),
      );
      expect(
        () => withMotions({
          'wave': {'group': 'Idle', 'index': 0},
          ' wave ': {'group': 'Idle', 'index': 1},
        }),
        _throwsFormat('repeats the key "wave"'),
      );
    });
  });
}
