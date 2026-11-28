// Widget tests for the Live2D models kept on this device: keeping a
// previewed model, the kept-model rows and enabling one, against the fake
// native view (live2d_native_fake.dart) and an in-memory store
// (live2d_fake_store.dart).
import 'dart:math';

import 'package:client_flutter/features/world/live2d_import_panel.dart';
import 'package:client_flutter/features/world/live2d_kept_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'live2d_fake_store.dart';
import 'live2d_native_fake.dart';

const _stage = '/data/user/0/jingyu/cache/live2d-preview/live2d-preview-1';
const _select = Key('live2d-select-zip');
const _keep = Key('live2d-keep');
const _keptPreview = Key('live2d-kept-preview');

const _report = <String, Object?>{
  'parameters': [
    {'id': 'ParamMouthOpenY', 'min': 0, 'max': 1, 'default': 0},
    {'id': 'ParamEyeLOpen', 'min': 0, 'max': 1, 'default': 1},
    {'id': 'ParamEyeROpen', 'min': 0, 'max': 1, 'default': 1},
  ],
  'parts': <String>[],
  'expressions': ['Smile'],
  'motions': [
    {'group': 'Idle', 'count': 1},
  ],
};

const _paramMap = <String, Object?>{
  'mouthOpen': 'ParamMouthOpenY',
  'blinkLeft': 'ParamEyeLOpen',
  'blinkRight': 'ParamEyeROpen',
  'noExpressions': false,
  'noMotions': false,
  'expressions': {'happy': 'Smile'},
  'motions': {
    'neutral': {'group': 'Idle', 'index': 0},
  },
};

/// The preview's loading spinner never settles, so pumpAndSettle would time
/// out. A few frames let channel calls and state changes land.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump();
  }
}

/// Lets a dialog route finish its transition.
Future<void> _transition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<FakeLive2DPlatformViews> _pumpPanel(
  WidgetTester tester,
  FakeLive2DFileStore store, {
  Future<Live2DImportSession?> Function()? open,
  Future<Live2DFileStore> Function()? openStore,
}) async {
  final platformViews = FakeLive2DPlatformViews();
  addTearDown(platformViews.dispose);
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            Live2DImportPanel(
              open: open ?? () async => null,
              openStore: openStore ?? () async => store,
            ),
          ],
        ),
      ),
    ),
  );
  await _settle(tester);
  return platformViews;
}

Live2DImportSession _session({
  Future<void> Function()? close,
  Map<String, List<int>> files = const {
    'model.model3.json': [1],
    'model.moc3': [2],
    'texture-0.png': [3],
  },
}) => Live2DImportSession(
  close ?? () async {},
  previewDirectory: _stage,
  displayName: 'Hiyori',
  readFiles: () async => files,
);

TextButton _button(WidgetTester tester, String key) =>
    tester.widget<TextButton>(find.byKey(Key(key)));

/// Answers [Random.nextInt] from [values], in order.
final class _Sequence implements Random {
  _Sequence(this.values);

  final List<int> values;
  var _next = 0;

  @override
  int nextInt(int max) => values[_next++];

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}

void main() {
  testWidgets('keeps a ready preview, removes the temporary files and opens '
      'the kept copy', (tester) async {
    final store = FakeLive2DFileStore();
    var closed = 0;
    final files = {
      'model.model3.json': [1],
      'model.moc3': [2],
      'texture-0.png': [3],
    };
    final platformViews = await _pumpPanel(
      tester,
      store,
      open: () async => _session(
        close: () async {
          closed++;
        },
        files: files,
      ),
    );
    expect(find.byKey(const Key('live2d-kept-empty')), findsOneWidget);
    await tester.tap(find.byKey(_select));
    await _settle(tester);
    // Not before the preview drew its first frame.
    expect(find.byKey(_keep), findsNothing);
    final temporary = platformViews.last;
    await temporary.boot();
    await temporary.ready();
    await _settle(tester);
    expect(find.text('仅本机临时预览，未启用形象。'), findsOneWidget);
    expect(store.calls, isEmpty);

    await tester.tap(find.byKey(_keep));
    await _settle(tester);
    final id = store.models.single.id;
    expect(Live2DProfile.isValidModelId(id), isTrue);
    expect(store.calls, ['importModel($id)']);
    expect(store.importedFiles[id], files);
    expect(store.models.single.displayName, 'Hiyori');
    expect(closed, 1);
    expect(find.byKey(const Key('live2d-import-preview')), findsNothing);
    expect(platformViews.disposed, contains(temporary.viewId));
    expect(find.byKey(_keptPreview), findsOneWidget);
    final kept = platformViews.last;
    expect(kept.viewId, isNot(temporary.viewId));
    expect(kept.calls.first.arguments, {'directory': store.modelDirectory(id)});
    expect(find.text('未设置映射'), findsOneWidget);
    expect(store.activeModelId, isNull);
  });

  testWidgets('设置映射 starts the wizard once the kept preview is ready; '
      '启用 needs a saved mapping', (tester) async {
    final store = FakeLive2DFileStore()..addModel('m1', displayName: 'Hiyori');
    final platformViews = await _pumpPanel(tester, store);
    expect(find.text('未设置映射'), findsOneWidget);
    expect(_button(tester, 'live2d-enable-m1').onPressed, isNull);

    await tester.tap(find.byKey(const Key('live2d-map-m1')));
    await _settle(tester);
    expect(find.byKey(const Key('live2d-wizard-waiting')), findsOneWidget);
    final view = platformViews.last;
    expect(view.calls.first.arguments, {
      'directory': store.modelDirectory('m1'),
    });
    await view.boot();
    await _settle(tester);
    expect(
      view.posted.single,
      containsPair('model3', '${view.baseUrl}model.model3.json'),
    );
    await view.ready(modelId: 'm1', report: _report);
    await _settle(tester);
    expect(find.byKey(const Key('live2d-mapping-wizard')), findsOneWidget);

    await tester.tap(find.byKey(const Key('live2d-wizard-cancel')));
    await _settle(tester);
    expect(find.byKey(const Key('live2d-mapping-wizard')), findsNothing);
    expect(find.byKey(_keptPreview), findsOneWidget);
    expect(store.calls, isEmpty);
  });

  testWidgets('启用 checks the mapping against a ready preview of the kept '
      'files; 停用 clears it', (tester) async {
    final store = FakeLive2DFileStore()..addModel('m1', paramMap: _paramMap);
    final platformViews = await _pumpPanel(tester, store);
    expect(find.text('已保存映射'), findsOneWidget);

    await tester.tap(find.byKey(const Key('live2d-enable-m1')));
    await _settle(tester);
    expect(find.byKey(const Key('live2d-kept-enabling')), findsOneWidget);
    expect(store.calls, isEmpty);
    final view = platformViews.last;
    await view.boot();
    await view.ready(modelId: 'm1', report: _report);
    await _settle(tester);
    expect(store.calls, ['setActive(m1)']);
    expect(store.lastActivationInfo!.parameterIds, {
      'ParamMouthOpenY',
      'ParamEyeLOpen',
      'ParamEyeROpen',
    });
    expect(store.activeModelId, 'm1');
    expect(find.text('已启用'), findsOneWidget);

    await tester.tap(find.byKey(const Key('live2d-disable-m1')));
    await _settle(tester);
    expect(store.calls.last, 'clearActive()');
    expect(store.activeModelId, isNull);
    expect(find.text('已保存映射'), findsOneWidget);
  });

  testWidgets('a mapping the preview does not report lists every miss and '
      'enables nothing', (tester) async {
    final store = FakeLive2DFileStore()..addModel('m1', paramMap: _paramMap);
    final platformViews = await _pumpPanel(tester, store);
    await tester.tap(find.byKey(const Key('live2d-enable-m1')));
    await _settle(tester);
    final view = platformViews.last;
    await view.boot();
    await view.ready(
      modelId: 'm1',
      report: const {
        'parameters': [
          {'id': 'ParamMouthOpenY', 'min': 0, 'max': 1, 'default': 0},
        ],
        'parts': <String>[],
        'expressions': ['Angry'],
        'motions': <Object?>[],
      },
    );
    await _settle(tester);
    expect(store.calls, ['setActive(m1)']);
    expect(store.activeModelId, isNull);
    final errors = find.byKey(const Key('live2d-kept-errors'));
    expect(
      find.descendant(of: errors, matching: find.byType(Text)),
      findsNWidgets(5),
    );
    expect(find.textContaining('左眼眨眼'), findsOneWidget);
    expect(find.textContaining('右眼眨眼'), findsOneWidget);
    expect(find.textContaining('表情「开心」'), findsOneWidget);
    expect(find.textContaining('动作「平静」'), findsOneWidget);
    expect(find.text('已保存映射'), findsOneWidget);
  });

  testWidgets('删除 asks first, then removes the model and closes its preview', (
    tester,
  ) async {
    final store = FakeLive2DFileStore()
      ..addModel('m1', paramMap: _paramMap, active: true);
    await _pumpPanel(tester, store);
    expect(find.text('已启用'), findsOneWidget);
    await tester.tap(find.byKey(const Key('live2d-map-m1')));
    await _settle(tester);
    expect(find.byKey(_keptPreview), findsOneWidget);

    await tester.tap(find.byKey(const Key('live2d-delete-m1')));
    await _transition(tester);
    await tester.tap(find.byKey(const Key('live2d-delete-cancel')));
    await _transition(tester);
    expect(store.calls, isEmpty);
    expect(find.byKey(_keptPreview), findsOneWidget);

    await tester.tap(find.byKey(const Key('live2d-delete-m1')));
    await _transition(tester);
    await tester.tap(find.byKey(const Key('live2d-delete-confirm')));
    await _transition(tester);
    expect(store.calls, ['delete(m1)']);
    expect(store.models, isEmpty);
    expect(store.activeModelId, isNull);
    expect(find.byKey(_keptPreview), findsNothing);
    expect(find.byKey(const Key('live2d-kept-empty')), findsOneWidget);
  });

  testWidgets('a new ZIP closes the kept preview, so one preview shows', (
    tester,
  ) async {
    final store = FakeLive2DFileStore()..addModel('m1');
    await _pumpPanel(tester, store, open: () async => _session());
    await tester.tap(find.byKey(const Key('live2d-map-m1')));
    await _settle(tester);
    expect(find.byKey(_keptPreview), findsOneWidget);
    await tester.tap(find.byKey(_select));
    await _settle(tester);
    expect(find.byKey(_keptPreview), findsNothing);
    expect(find.byKey(const Key('live2d-import-preview')), findsOneWidget);
    expect(_button(tester, 'live2d-map-m1').onPressed, isNull);
  });

  testWidgets('a model kept before its temporary files could be removed is '
      'not kept twice, and opens once they are', (tester) async {
    final store = FakeLive2DFileStore();
    var closes = 0;
    final platformViews = await _pumpPanel(
      tester,
      store,
      open: () async => _session(
        close: () async {
          closes++;
          if (closes == 1) throw Exception('busy');
        },
      ),
    );
    await tester.tap(find.byKey(_select));
    await _settle(tester);
    final temporary = platformViews.last;
    await temporary.boot();
    await temporary.ready();
    await _settle(tester);
    await tester.tap(find.byKey(_keep));
    await _settle(tester);
    final id = store.models.single.id;
    expect(find.textContaining('模型已保留'), findsOneWidget);
    expect(find.byKey(_keep), findsNothing);
    expect(find.byKey(_keptPreview), findsNothing);

    await tester.tap(find.byKey(const Key('live2d-release-zip')));
    await _settle(tester);
    expect(closes, 2);
    expect(store.calls, ['importModel($id)']);
    expect(find.byKey(_keptPreview), findsOneWidget);
    expect(find.textContaining('模型已保留'), findsNothing);
  });

  testWidgets('a store that cannot open says so; the temporary preview still '
      'works', (tester) async {
    var opened = 0;
    await _pumpPanel(
      tester,
      FakeLive2DFileStore(),
      openStore: () async {
        opened++;
        throw const FormatException('models.json at /data/user/0/x');
      },
    );
    expect(find.byKey(const Key('live2d-store-error')), findsOneWidget);
    expect(find.textContaining('/data/user/0/x'), findsNothing);
    expect(
      tester.widget<OutlinedButton>(find.byKey(_select)).onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('live2d-store-retry')));
    await _settle(tester);
    expect(opened, 2);
  });

  testWidgets('only Android keeps models', (tester) async {
    var opened = 0;
    await _pumpPanel(
      tester,
      FakeLive2DFileStore(),
      openStore: () async {
        opened++;
        return FakeLive2DFileStore();
      },
    );
    expect(opened, 0);
    expect(find.text('本机保存的模型'), findsNothing);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));

  group('helpers', () {
    test('a new model ID is valid and differs from the kept ones, ignoring '
        'case', () {
      final now = DateTime.utc(2026, 11, 28);
      final time = now.millisecondsSinceEpoch.toRadixString(36);
      final store = FakeLive2DFileStore()
        ..addModel('live2d-$time-z'.toUpperCase());
      final id = newLive2DModelId(store, now: now, random: _Sequence([35, 36]));
      expect(id, 'live2d-$time-10');
      expect(Live2DProfile.isValidModelId(id), isTrue);
    });

    test('the display name is the file name without its extension', () {
      expect(live2dDisplayName('Hiyori.zip'), 'Hiyori');
      expect(live2dDisplayName(' a.b.zip '), 'a.b');
      expect(live2dDisplayName(null), '未命名模型');
      expect(live2dDisplayName('   '), '未命名模型');
      expect(live2dDisplayName('${'a' * 300}.zip'), 'a' * 256);
      // A surrogate pair is never cut in half.
      expect(live2dDisplayName('${'a' * 255}😀b.zip'), 'a' * 255);
    });
  });
}
