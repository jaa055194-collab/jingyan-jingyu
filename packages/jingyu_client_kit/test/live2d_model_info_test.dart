import 'dart:convert';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

Map<String, Object?> readyEvent([Map<String, Object?> fields = const {}]) => {
  'event': 'ready',
  'modelId': 'm',
  'profileRev': 1,
  ...fields,
};

void main() {
  group('Live2DModelInfo.fromReadyEvent', () {
    test('reads parameters and parts in runtime order', () {
      final info = Live2DModelInfo.fromReadyEvent(
        readyEvent({
          'parameters': [
            {'id': 'ParamAngleX', 'min': -30, 'max': 30, 'default': 0},
            {'id': 'ParamMouthOpenY', 'min': 0, 'max': 1.5, 'default': 0.25},
          ],
          'parts': ['PartArmB', 'PartArmA'],
        }),
      );
      expect(info.parameters!.map((parameter) => parameter.id), [
        'ParamAngleX',
        'ParamMouthOpenY',
      ]);
      final angle = info.parameter('ParamAngleX')!;
      expect(angle.min, -30.0);
      expect(angle.max, 30.0);
      expect(angle.defaultValue, 0.0);
      expect(info.parameter('ParamMouthOpenY')!.max, 1.5);
      expect(info.parameterIds, {'ParamAngleX', 'ParamMouthOpenY'});
      expect(info.parts, ['PartArmB', 'PartArmA']);
      expect(info.partIds, {'PartArmA', 'PartArmB'});
      expect(info.parameter('ParamAngleY'), isNull);
      expect(info.parameter('paramanglex'), isNull);
    });

    test('reads an event decoded from JSON, as the Android host does', () {
      final event =
          jsonDecode(
                '{"event":"ready","modelId":"m","profileRev":1,'
                '"parameters":[{"id":"ParamEyeLOpen","min":0,"max":1,"default":1}],'
                '"parts":["PartEye"]}',
              )
              as Map<String, Object?>;
      final info = Live2DModelInfo.fromReadyEvent(event);
      expect(info.parameter('ParamEyeLOpen')!.defaultValue, 1.0);
      expect(info.partIds, {'PartEye'});
    });

    test('leaves out lists the viewer did not report', () {
      for (final fields in <Map<String, Object?>>[
        {},
        {'parameters': null, 'parts': null},
      ]) {
        final info = Live2DModelInfo.fromReadyEvent(readyEvent(fields));
        expect(info.parameters, isNull);
        expect(info.parameterIds, isNull);
        expect(info.parts, isNull);
        expect(info.partIds, isNull);
        expect(info.parameter('ParamAngleX'), isNull);
      }
    });

    test('keeps a reported empty list apart from a missing one', () {
      final info = Live2DModelInfo.fromReadyEvent(
        readyEvent({'parameters': <Object?>[], 'parts': <Object?>[]}),
      );
      expect(info.parameters, isEmpty);
      expect(info.parameterIds, isEmpty);
      expect(info.parts, isEmpty);
    });

    test('allows a parameter without range values', () {
      final info = Live2DModelInfo.fromReadyEvent(
        readyEvent({
          'parameters': [
            {'id': 'P', 'max': 1},
          ],
        }),
      );
      final parameter = info.parameter('P')!;
      expect(parameter.min, isNull);
      expect(parameter.max, 1.0);
      expect(parameter.defaultValue, isNull);
    });

    test('accepts IDs and lists at their size limits', () {
      final info = Live2DModelInfo.fromReadyEvent(
        readyEvent({
          'parts': [
            'x' * Live2DModelInfo.maxIdLength,
            for (var i = 1; i < Live2DModelInfo.maxEntries; i++) 'Part$i',
          ],
        }),
      );
      expect(info.parts, hasLength(Live2DModelInfo.maxEntries));
    });

    test('rejects a malformed list as a whole', () {
      final cases = <String, Map<String, Object?>>{
        'parameters not a list': {'parameters': 'ParamAngleX'},
        'parts not a list': {
          'parts': {'id': 'PartArm'},
        },
        'parameter not an object': {
          'parameters': ['ParamAngleX'],
        },
        'parameter without id': {
          'parameters': [
            {'min': 0},
          ],
        },
        'empty parameter id': {
          'parameters': [
            {'id': ''},
          ],
        },
        'non-numeric minimum': {
          'parameters': [
            {'id': 'P', 'min': '0'},
          ],
        },
        'NaN minimum': {
          'parameters': [
            {'id': 'P', 'min': double.nan},
          ],
        },
        'infinite maximum': {
          'parameters': [
            {'id': 'P', 'max': double.infinity},
          ],
        },
        'boolean default': {
          'parameters': [
            {'id': 'P', 'default': true},
          ],
        },
        'minimum above maximum': {
          'parameters': [
            {'id': 'P', 'min': 1, 'max': 0},
          ],
        },
        'repeated parameter id': {
          'parameters': [
            {'id': 'P'},
            {'id': 'P'},
          ],
        },
        'repeated part id': {
          'parts': ['A', 'A'],
        },
        'empty part id': {
          'parts': [''],
        },
        'non-string part id': {
          'parts': [7],
        },
        'over-long id': {
          'parts': ['x' * (Live2DModelInfo.maxIdLength + 1)],
        },
        'too many entries': {
          'parts': [
            for (var i = 0; i <= Live2DModelInfo.maxEntries; i++) 'Part$i',
          ],
        },
      };
      for (final entry in cases.entries) {
        expect(
          () => Live2DModelInfo.fromReadyEvent(readyEvent(entry.value)),
          throwsFormatException,
          reason: entry.key,
        );
      }
    });

    test('returns read-only collections', () {
      final info = Live2DModelInfo.fromReadyEvent(
        readyEvent({
          'parameters': [
            {'id': 'P'},
          ],
          'parts': ['A'],
        }),
      );
      expect(() => info.parameters!.clear(), throwsUnsupportedError);
      expect(() => info.parameterIds!.add('Q'), throwsUnsupportedError);
      expect(() => info.parts!.add('B'), throwsUnsupportedError);
      expect(() => info.partIds!.remove('A'), throwsUnsupportedError);
    });

    test('supplies the runtime inventory that Live2DParamMap checks', () {
      final info = Live2DModelInfo.fromReadyEvent(
        readyEvent({
          'parameters': [
            {'id': 'ParamMouthOpenY'},
            {'id': 'ParamEyeLOpen'},
            {'id': 'ParamEyeROpen'},
          ],
          'expressions': ['Smile'],
          'motions': [
            {'group': 'Idle', 'count': 1},
          ],
        }),
      );
      Live2DParamMap mapWithRightEye(String target) => Live2DParamMap.fromJson({
        'mouthOpen': 'ParamMouthOpenY',
        'blinkLeft': 'ParamEyeLOpen',
        'blinkRight': target,
        'noExpressions': false,
        'noMotions': false,
        'expressions': {'happy': 'Smile'},
        'motions': {
          'idle': {'group': 'Idle', 'index': 0},
        },
      });

      mapWithRightEye('ParamEyeROpen').validateTargets(info);
      expect(
        () => mapWithRightEye('ParamEyeRopen').validateTargets(info),
        throwsA(
          isA<Live2DTargetException>()
              .having(
                (error) => [for (final miss in error.misses) miss.field],
                'miss fields',
                ['blinkRight'],
              )
              .having(
                (error) => error.message,
                'message',
                contains('blinkRight'),
              ),
        ),
      );
    });
  });

  group('Live2DModelInfo expressions and motions', () {
    Live2DModelInfo read(Map<String, Object?> fields) =>
        Live2DModelInfo.fromReadyEvent(readyEvent(fields));

    test('reads expression names and motion groups in model3 order', () {
      final info = read({
        'expressions': ['F02', 'F01', 'f01'],
        'motions': [
          {'group': 'TapBody', 'count': 3},
          {'group': '', 'count': 1},
          {'group': 'Idle', 'count': 2, 'file': 'not read'},
        ],
      });
      expect(info.expressions, ['F02', 'F01', 'f01']);
      expect(info.expressionNames, {'F02', 'F01', 'f01'});
      expect(
        [for (final motion in info.motions!) (motion.group, motion.count)],
        [('TapBody', 3), ('', 1), ('Idle', 2)],
      );
      expect(info.motionCount('TapBody'), 3);
      expect(info.motionCount(''), 1);
      expect(info.motionCount('Idle'), 2);
      expect(info.motionCount('idle'), isNull);
      expect(info.motionCount('Missing'), isNull);
    });

    test('reads expressions and motions from a JSON-decoded event', () {
      final event = jsonDecode(
        '{"event": "ready", "modelId": "m", "profileRev": 1, '
        '"expressions": ["F01"], "motions": [{"group": "Idle", "count": 2}]}',
      );
      final info = Live2DModelInfo.fromReadyEvent(
        event as Map<String, Object?>,
      );
      expect(info.expressions, ['F01']);
      expect(info.motionCount('Idle'), 2);
    });

    test('leaves expressions and motions null when the viewer omits them', () {
      for (final fields in <Map<String, Object?>>[
        {},
        {'expressions': null, 'motions': null},
      ]) {
        final info = read(fields);
        expect(info.expressions, isNull);
        expect(info.expressionNames, isNull);
        expect(info.motions, isNull);
        expect(info.motionCount('Idle'), isNull);
      }
    });

    test('keeps reported empty lists apart from missing ones', () {
      final info = read({'expressions': <Object?>[], 'motions': <Object?>[]});
      expect(info.expressions, isEmpty);
      expect(info.expressionNames, isEmpty);
      expect(info.motions, isEmpty);
      expect(info.motionCount('Idle'), isNull);
    });

    test('accepts expressions and motion groups at their size limits', () {
      final group = 'x' * Live2DModelInfo.maxIdLength;
      final info = read({
        'expressions': [
          for (var i = 0; i < Live2DModelInfo.maxExpressions; i++) 'E$i',
        ],
        'motions': [
          for (var i = 1; i < Live2DModelInfo.maxEntries; i++)
            {'group': 'G$i', 'count': 1},
          {'group': group, 'count': Live2DModelInfo.maxMotionsPerGroup},
        ],
      });
      expect(info.expressions, hasLength(Live2DModelInfo.maxExpressions));
      expect(info.motions, hasLength(Live2DModelInfo.maxEntries));
      expect(info.motionCount(group), Live2DModelInfo.maxMotionsPerGroup);
    });

    test('returns read-only expressions and motions', () {
      final info = read({
        'expressions': ['F01'],
        'motions': [
          {'group': 'Idle', 'count': 1},
        ],
      });
      expect(() => info.expressions!.add('F02'), throwsUnsupportedError);
      expect(() => info.expressionNames!.remove('F01'), throwsUnsupportedError);
      expect(() => info.motions!.clear(), throwsUnsupportedError);
    });

    // Each bad shape also names the parser branch that must reject it. Like a
    // bad parameters list, it fails the whole event.
    final long = 'x' * (Live2DModelInfo.maxIdLength + 1);
    for (final (reason, fields, message)
        in <(String, Map<String, Object?>, String)>[
          (
            'expressions that are not a list',
            {'expressions': 'F01'},
            'expressions must be a list',
          ),
          (
            'a non-string expression name',
            {
              'expressions': [1],
            },
            'expressions[0] must be a non-empty string',
          ),
          (
            'an empty expression name',
            {
              'expressions': ['F01', ''],
            },
            'expressions[1] must be a non-empty string',
          ),
          (
            'an over-long expression name',
            {
              'expressions': [long],
            },
            'expressions[0] must be a non-empty string',
          ),
          (
            'a repeated expression name',
            {
              'expressions': ['F01', 'F01'],
            },
            'expressions[1] repeats an earlier ID',
          ),
          (
            'more than maxExpressions expressions',
            {
              'expressions': [
                for (var i = 0; i <= Live2DModelInfo.maxExpressions; i++) 'E$i',
              ],
            },
            'expressions has more than ${Live2DModelInfo.maxExpressions} entries',
          ),
          (
            'motions that are not a list',
            {
              'motions': {'group': 'Idle', 'count': 1},
            },
            'motions must be a list',
          ),
          (
            'a motion group that is not an object',
            {
              'motions': ['Idle'],
            },
            'motions[0] must be an object',
          ),
          (
            'a motion group without a name',
            {
              'motions': [
                {'count': 1},
              ],
            },
            'motions[0].group must be a string',
          ),
          (
            'a non-string group name',
            {
              'motions': [
                {'group': 1, 'count': 1},
              ],
            },
            'motions[0].group must be a string',
          ),
          (
            'an over-long group name',
            {
              'motions': [
                {'group': long, 'count': 1},
              ],
            },
            'motions[0].group must be a string',
          ),
          (
            'a repeated group name',
            {
              'motions': [
                {'group': '', 'count': 1},
                {'group': '', 'count': 2},
              ],
            },
            'motions[1].group repeats an earlier group',
          ),
          (
            'a motion group without a count',
            {
              'motions': [
                {'group': 'Idle'},
              ],
            },
            'motions[0].count must be an integer',
          ),
          for (final count in <Object?>[
            0,
            -1,
            1.5,
            '1',
            Live2DModelInfo.maxMotionsPerGroup + 1,
          ])
            (
              'motion count $count (${count.runtimeType})',
              {
                'motions': [
                  {'group': 'Idle', 'count': count},
                ],
              },
              'motions[0].count must be an integer',
            ),
          (
            'more than maxEntries motion groups',
            {
              'motions': [
                for (var i = 0; i <= Live2DModelInfo.maxEntries; i++)
                  {'group': 'G$i', 'count': 1},
              ],
            },
            'motions has more than ${Live2DModelInfo.maxEntries} entries',
          ),
        ]) {
      test('rejects $reason', () {
        expect(
          () => read(fields),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains(message),
            ),
          ),
        );
      });
    }

    test('rejects the event when one list is bad and the others are good', () {
      expect(
        () => read({
          'parameters': [
            {'id': 'ParamAngleX'},
          ],
          'parts': ['PartArm'],
          'expressions': ['F01'],
          'motions': [
            {'group': 'Idle', 'count': 0},
          ],
        }),
        throwsFormatException,
      );
    });
  });
}
