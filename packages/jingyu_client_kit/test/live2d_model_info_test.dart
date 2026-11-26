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

    test('supplies the runtime ID set that Live2DParamMap checks', () {
      final info = Live2DModelInfo.fromReadyEvent(
        readyEvent({
          'parameters': [
            {'id': 'ParamMouthOpenY'},
            {'id': 'ParamEyeLOpen'},
            {'id': 'ParamEyeROpen'},
          ],
        }),
      );
      Live2DParamMap mapWithRightEye(String target) => Live2DParamMap.fromJson({
        'mouthOpen': 'ParamMouthOpenY',
        'blinkLeft': 'ParamEyeLOpen',
        'blinkRight': target,
        'expressions': {'happy': 'Smile'},
        'motions': {'idle': 'Idle'},
      });
      void check(Live2DParamMap map) => map.validateTargets(
        parameters: info.parameterIds!,
        expressions: const {'Smile'},
        motions: const {'Idle'},
      );

      check(mapWithRightEye('ParamEyeROpen'));
      expect(
        () => check(mapWithRightEye('ParamEyeRopen')),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('blinkRight'),
          ),
        ),
      );
    });
  });
}
