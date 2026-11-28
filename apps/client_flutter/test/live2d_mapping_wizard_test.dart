// Widget tests for the Live2D mapping wizard against an in-memory store
// (live2d_fake_store.dart).
import 'dart:async';

import 'package:client_flutter/features/world/live2d_mapping_wizard.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'live2d_fake_store.dart';

const _standard = <Map<String, Object?>>[
  {'id': 'ParamMouthOpenY', 'min': 0, 'max': 1, 'default': 0},
  {'id': 'ParamEyeLOpen', 'min': 0, 'max': 1, 'default': 1},
  {'id': 'ParamEyeROpen', 'min': 0, 'max': 1, 'default': 1},
  {'id': 'ParamAngleX', 'min': -30, 'max': 30, 'default': 0},
];

Live2DModelInfo _info({
  List<Map<String, Object?>>? parameters = _standard,
  List<String>? expressions = const ['Smile', 'Angry'],
  List<Map<String, Object?>>? motions = const [
    {'group': 'Idle', 'count': 2},
  ],
}) => Live2DModelInfo.fromReadyEvent({
  'parameters': ?parameters,
  'parts': const <String>[],
  'expressions': ?expressions,
  'motions': ?motions,
});

final class _Wizard {
  _Wizard(this.store);

  final FakeLive2DFileStore store;

  /// The commands sent to the preview, in order: a value for setParameter,
  /// null for clearParameter.
  final List<(String, double?)> sent = [];

  /// When set, each command waits for it, like a preview that has not
  /// answered yet.
  Future<void>? reply;
  int closed = 0;
  int changed = 0;

  Future<void> send(String id, double? value) async {
    sent.add((id, value));
    await reply;
  }
}

Future<_Wizard> _pump(
  WidgetTester tester,
  Live2DModelInfo? info, {
  FakeLive2DFileStore? store,
  String? infoError,
}) async {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final wizard = _Wizard(store ?? (FakeLive2DFileStore()..addModel('m1')));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            Live2DMappingWizard(
              store: wizard.store,
              modelId: 'm1',
              info: info,
              infoError: infoError,
              setParameter: wizard.send,
              clearParameter: (id) => wizard.send(id, null),
              onClose: () => wizard.closed++,
              onChanged: () => wizard.changed++,
            ),
          ],
        ),
      ),
    ),
  );
  return wizard;
}

Finder _key(String key) => find.byKey(Key(key));

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<FilledButton>(_key(key)).onPressed != null;

/// The selected index of a dropdown: an index into the reported list, -1
/// for 不映射, or null when nothing is chosen.
int? _value(WidgetTester tester, String key) =>
    tester.widget<DropdownButton<int>>(_key(key)).value;

Future<void> _choose(WidgetTester tester, String key, String option) async {
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
  // The open menu is built after the page, so its item comes last.
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

Future<void> _next(WidgetTester tester) async {
  await tester.tap(_key('live2d-wizard-next'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('preselects the suggestions; a slider drives the preview, then '
      'releases the parameter', (tester) async {
    final wizard = await _pump(tester, _info());
    expect(find.text('第 1/3 步：口型与眨眼（必填）'), findsOneWidget);
    expect(_value(tester, 'live2d-wizard-param-mouthOpen'), 0);
    expect(_value(tester, 'live2d-wizard-param-blinkLeft'), 1);
    expect(_value(tester, 'live2d-wizard-param-blinkRight'), 2);
    expect(_enabled(tester, 'live2d-wizard-next'), isTrue);

    await tester.drag(
      _key('live2d-wizard-slider-mouthOpen'),
      const Offset(300, 0),
    );
    await tester.pumpAndSettle();
    expect({for (final (id, _) in wizard.sent) id}, {'ParamMouthOpenY'});
    // Letting go clears the parameter instead of setting its default (0),
    // which the preview would go on holding.
    final values = [for (final (_, value) in wizard.sent) ?value];
    expect(values, isNotEmpty);
    expect(values.every((value) => value > 0 && value <= 1), isTrue);
    expect(wizard.sent, hasLength(values.length + 1));
    expect(wizard.sent.last, ('ParamMouthOpenY', null));
    expect(wizard.store.calls, isEmpty);
  });

  testWidgets('the release follows the last value; a drag before it went '
      'out drops it', (tester) async {
    final wizard = await _pump(tester, _info());
    final slider = _key('live2d-wizard-slider-mouthOpen');
    const id = 'ParamMouthOpenY';

    // Until the preview answers, the later value and the release wait; then
    // the latest value goes out, and the release after it.
    var reply = Completer<void>();
    wizard.reply = reply.future;
    await tester.drag(slider, const Offset(300, 0));
    expect(wizard.sent, hasLength(1));
    reply.complete();
    await tester.pumpAndSettle();
    expect(wizard.sent, hasLength(3));
    expect(wizard.sent[1].$2, greaterThan(wizard.sent[0].$2!));
    expect(wizard.sent.last, (id, null));

    // A new drag drives the preview again. One that starts before its
    // release went out drops it, and ends with a release of its own.
    reply = Completer<void>();
    wizard.reply = reply.future;
    await tester.drag(slider, const Offset(-100, 0));
    expect(wizard.sent, hasLength(4));
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(50, 0));
    reply.complete();
    await tester.pump();
    expect(wizard.sent, hasLength(5));
    expect(wizard.sent[4].$2, isNotNull);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(wizard.sent, hasLength(6));
    expect(wizard.sent.last, (id, null));
  });

  testWidgets('恢复建议值 resets page 1; 取消 leaves without writing', (tester) async {
    final wizard = await _pump(tester, _info());
    await _choose(tester, 'live2d-wizard-param-mouthOpen', 'ParamAngleX');
    expect(_value(tester, 'live2d-wizard-param-mouthOpen'), 3);
    await tester.tap(_key('live2d-wizard-reset'));
    await tester.pump();
    expect(_value(tester, 'live2d-wizard-param-mouthOpen'), 0);

    await tester.tap(_key('live2d-wizard-cancel'));
    await tester.pump();
    expect(wizard.closed, 1);
    expect(wizard.store.calls, isEmpty);
  });

  testWidgets('a slot without a suggestion must be chosen before 下一步', (
    tester,
  ) async {
    await _pump(
      tester,
      _info(
        parameters: const [
          {'id': 'MouthA', 'min': 0, 'max': 1, 'default': 0},
          {'id': 'EyeA', 'min': 0, 'max': 1, 'default': 1},
          {'id': 'EyeB', 'min': 0, 'max': 1, 'default': 1},
        ],
      ),
    );
    expect(_value(tester, 'live2d-wizard-param-mouthOpen'), isNull);
    expect(_enabled(tester, 'live2d-wizard-next'), isFalse);
    await _choose(tester, 'live2d-wizard-param-mouthOpen', 'MouthA');
    await _choose(tester, 'live2d-wizard-param-blinkLeft', 'EyeA');
    expect(_enabled(tester, 'live2d-wizard-next'), isFalse);
    await _choose(tester, 'live2d-wizard-param-blinkRight', 'EyeB');
    expect(_enabled(tester, 'live2d-wizard-next'), isTrue);
  });

  testWidgets('writes only on 确认并保存, then 启用此形象 checks the preview '
      'info', (tester) async {
    final info = _info();
    final wizard = await _pump(tester, info);
    await _next(tester);
    expect(find.text('第 2/3 步：表情'), findsOneWidget);
    expect(find.text('此模型没有表情'), findsNothing);
    expect(_enabled(tester, 'live2d-wizard-next'), isFalse);
    await _choose(tester, 'live2d-wizard-expression-happy', 'Smile');
    await _next(tester);
    expect(find.text('第 3/3 步：动作'), findsOneWidget);
    expect(find.text('此模型没有动作'), findsNothing);
    expect(_enabled(tester, 'live2d-wizard-save'), isFalse);
    await _choose(tester, 'live2d-wizard-motion-neutral', 'Idle 第 2 个');
    expect(wizard.store.calls, isEmpty);

    await tester.tap(_key('live2d-wizard-save'));
    await tester.pumpAndSettle();
    expect(wizard.store.calls, ['saveProfile(m1, rev 1)']);
    expect(wizard.store.profile('m1')!.toJson(), {
      'schemaVersion': 1,
      'modelId': 'm1',
      'profileRev': 1,
      'modelFile': 'model.model3.json',
      'paramMap': {
        'mouthOpen': 'ParamMouthOpenY',
        'blinkLeft': 'ParamEyeLOpen',
        'blinkRight': 'ParamEyeROpen',
        'noExpressions': false,
        'noMotions': false,
        'expressions': {'happy': 'Smile'},
        'motions': {
          'neutral': {'group': 'Idle', 'index': 1},
        },
      },
    });
    expect(wizard.changed, 1);
    expect(find.text('映射已保存，尚未启用。'), findsOneWidget);
    expect(wizard.store.activeModelId, isNull);

    await tester.tap(_key('live2d-wizard-enable'));
    await tester.pumpAndSettle();
    expect(wizard.store.calls.last, 'setActive(m1)');
    expect(wizard.store.lastActivationInfo, same(info));
    expect(wizard.store.activeModelId, 'm1');
    expect(find.text('已启用。暂不会显示在聊天或世界场景中。'), findsOneWidget);
    expect(_key('live2d-wizard-enable'), findsNothing);
  });

  testWidgets('此模型没有表情 and 此模型没有动作 are offered for an empty list '
      'and saved as flags', (tester) async {
    final wizard = await _pump(
      tester,
      _info(expressions: const [], motions: const []),
    );
    await _next(tester);
    expect(_key('live2d-wizard-expression-happy'), findsNothing);
    expect(_enabled(tester, 'live2d-wizard-next'), isFalse);
    await tester.tap(find.text('此模型没有表情'));
    await tester.pumpAndSettle();
    await _next(tester);
    expect(_enabled(tester, 'live2d-wizard-save'), isFalse);
    await tester.tap(find.text('此模型没有动作'));
    await tester.pumpAndSettle();
    await tester.tap(_key('live2d-wizard-save'));
    await tester.pumpAndSettle();
    final map = wizard.store.profile('m1')!.paramMap;
    expect(map.noExpressions, isTrue);
    expect(map.noMotions, isTrue);
    expect(map.expressions, isEmpty);
    expect(map.motions, isEmpty);
  });

  testWidgets('a kind the model did not report blocks saving', (tester) async {
    final wizard = await _pump(tester, _info(motions: null));
    await _next(tester);
    await _choose(tester, 'live2d-wizard-expression-happy', 'Smile');
    await _next(tester);
    expect(_key('live2d-wizard-blocked'), findsOneWidget);
    expect(find.text('此模型没有动作'), findsNothing);
    expect(_enabled(tester, 'live2d-wizard-save'), isFalse);
    expect(wizard.store.calls, isEmpty);
  });

  testWidgets('without a model report it explains why and blocks', (
    tester,
  ) async {
    await _pump(tester, null, infoError: 'parameters[0] is not an object');
    expect(_key('live2d-wizard-blocked'), findsOneWidget);
    expect(find.text('parameters[0] is not an object'), findsOneWidget);
    expect(_enabled(tester, 'live2d-wizard-next'), isFalse);
  });

  testWidgets('a saved choice is preselected only while the preview still '
      'reports it', (tester) async {
    final store = FakeLive2DFileStore()
      ..addModel(
        'm1',
        paramMap: const {
          'mouthOpen': 'ParamAngleX',
          'blinkLeft': 'GoneEye',
          'blinkRight': 'ParamEyeROpen',
          'noExpressions': false,
          'noMotions': false,
          'expressions': {'happy': 'Gone', 'sad': 'Angry'},
          'motions': {
            'neutral': {'group': 'Idle', 'index': 1},
            'happy': {'group': 'Idle', 'index': 5},
          },
        },
      );
    final wizard = await _pump(tester, _info(), store: store);
    expect(_value(tester, 'live2d-wizard-param-mouthOpen'), 3);
    // The saved left-eye target is gone, so the suggestion stays.
    expect(_value(tester, 'live2d-wizard-param-blinkLeft'), 1);
    await _next(tester);
    expect(_value(tester, 'live2d-wizard-expression-happy'), -1);
    expect(_value(tester, 'live2d-wizard-expression-sad'), 1);
    await _next(tester);
    expect(_value(tester, 'live2d-wizard-motion-neutral'), 1);
    expect(_value(tester, 'live2d-wizard-motion-happy'), -1);
    await tester.tap(_key('live2d-wizard-save'));
    await tester.pumpAndSettle();
    expect(wizard.store.calls, ['saveProfile(m1, rev 2)']);
  });

  test('enabling needs a model report from the preview', () async {
    final store = FakeLive2DFileStore()..addModel('m1');
    expect(await enableLive2DModel(store, 'm1', null, infoError: 'bad'), [
      '无法启用：预览未提供有效的模型报告。',
      'bad',
    ]);
    expect(store.calls, isEmpty);
  });
}
