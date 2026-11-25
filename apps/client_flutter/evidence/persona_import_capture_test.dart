import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _register = '/api/v1/ai-profiles/register';

/// Fixture transport for the real Settings → AI-config editor route. It only
/// answers the existing profile-resolve POST; any persona write would throw.
class _Connection extends HostConnection {
  _Connection() : super(Uri.parse('http://fixture.invalid'), 'fixture');
  final calls = <(String, String)>[];

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    calls.add((method, path));
    if (method == 'POST' && path == _register) {
      expect(body, {'accountId': 'fixture-ai'});
      return {
        'accountId': 'fixture-ai',
        'ownerAccountId': 'fixture-owner',
        'profileId': 'fixture-profile',
      };
    }
    throw StateError('Unexpected fixture request');
  }
}

class _Runtime extends ClientRuntime {
  _Runtime(_Connection host) {
    connection = host;
  }
  @override
  bool get ready => true;
  @override
  bool get onboarded => true;
  @override
  bool get chatEntered => true;
  @override
  bool get online => true;
  @override
  bool get locked => false;
  @override
  String? get connectedAccountId => 'fixture-owner';
  @override
  ThemeMode get themeMode => ThemeMode.light;
  @override
  double get fontScale => 1;
  @override
  List<ShellOwnedAi> get ownAiAccounts => const [
    ShellOwnedAi(
      accountId: 'fixture-ai',
      displayName: '示例 AI',
      disabled: false,
    ),
  ];
}

void main() {
  testWidgets('capture the same AI persona panel before and after import', (
    tester,
  ) async {
    const output = String.fromEnvironment('CAPTURE_PATH');
    const stage = String.fromEnvironment(
      'CAPTURE_STAGE',
      defaultValue: 'entry',
    );
    const expectImport = bool.fromEnvironment('CAPTURE_EXPECT_IMPORT');
    const samplePath = String.fromEnvironment('CAPTURE_SAMPLE');
    const cjk = String.fromEnvironment('CAPTURE_CJK_FONT');
    const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
    expect(output, isNotEmpty);
    expect(stage, anyOf('entry', 'imported'));
    for (final (family, path) in [('Ahem', cjk), ('MaterialIcons', icons)]) {
      final bytes = File(path).readAsBytesSync();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final host = _Connection();
    final runtime = _Runtime(host);
    addTearDown(runtime.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: WhaleChatApp(model: runtime),
      ),
    );
    await tester.pumpAndSettle();

    Finder key(String value) => find.byKey(Key(value));
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    final settingsScroll = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      key('open-ai-config-write'),
      300,
      scrollable: settingsScroll,
    );
    await tester.pumpAndSettle();
    await tester.tap(key('open-ai-config-write'));
    await tester.pumpAndSettle();

    final outer = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      key('help-persona'),
      240,
      scrollable: outer,
    );
    await tester.pumpAndSettle();
    Future<void> anchor() async {
      final position = tester.state<ScrollableState>(outer).position;
      final target =
          position.pixels +
          tester.getTopLeft(key('help-persona')).dy -
          tester.getTopLeft(outer).dy -
          40;
      position.jumpTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
      await tester.pumpAndSettle();
    }

    await anchor();
    expect(
      key('persona-import-file').hitTestable(),
      expectImport ? findsOneWidget : findsNothing,
    );
    expect(
      key('persona-import-paste').hitTestable(),
      expectImport ? findsOneWidget : findsNothing,
    );
    expect(key('persona-import-status'), findsNothing);

    Future<void> capture(String path) async {
      expect(tester.takeException(), isNull);
      final painter =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final png = await tester.runAsync(() async {
        final pixels = await painter.toImage();
        try {
          expect((pixels.width, pixels.height), (390, 844));
          return await pixels.toByteData(format: ui.ImageByteFormat.png);
        } finally {
          pixels.dispose();
        }
      });
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(
        png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    }

    if (stage == 'imported') {
      expect(expectImport, isTrue);
      final sample = File(samplePath).readAsStringSync();
      await tester.scrollUntilVisible(
        key('persona-import-paste'),
        240,
        scrollable: outer,
      );
      await tester.pumpAndSettle();
      await tester.tap(key('persona-import-paste'));
      await tester.pumpAndSettle();
      await tester.enterText(key('persona-import-paste-input'), sample);
      await tester.tap(key('persona-import-paste-apply'));
      await tester.pumpAndSettle();
      expect(key('persona-import-status'), findsOneWidget);
      expect(find.textContaining('仅填充表单'), findsOneWidget);
      expect(find.textContaining('P0 2 项'), findsOneWidget);
      for (final (field, value) in [
        ('persona-p0', 'name=示例角色\nrole=示例用途'),
        ('persona-p1', 'style=示例表达风格'),
        ('persona-p2', 'mood=示例情绪'),
      ]) {
        expect(tester.widget<TextField>(key(field)).controller!.text, value);
      }
      // No persona write was sent; the only POST is the existing resolve call.
      expect(
        host.calls.where((call) => call.$1 == 'POST' && call.$2 != _register),
        isEmpty,
      );
      await anchor();
      await capture(output);
    } else {
      // Before has no import controls; After shows them but has written nothing.
      expect(host.calls.where((call) => call.$1 == 'POST'), hasLength(1));
      await capture(output);
    }
    expect(
      find.byKey(const Key('persona-import-status')),
      stage == 'imported' ? findsOneWidget : findsNothing,
    );
  });
}
