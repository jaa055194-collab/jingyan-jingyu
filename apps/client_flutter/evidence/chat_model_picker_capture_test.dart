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

// Synthetic session and transport; both renders exercise the production routes,
// editor, resolver and (for the optional follow-on) catalog adapter.
class _Connection extends HostConnection {
  _Connection() : super(Uri.parse('http://fixture.invalid'), 'fixture');
  final requests = <(String, String)>[];

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    requests.add((method, path));
    return switch ((method, path)) {
      ('POST', '/api/v1/ai-profiles/register') => {
        'accountId': 'fixture-ai',
        'ownerAccountId': 'fixture-owner',
        'profileId': 'fixture-profile',
      },
      ('GET', '/api/v1/model-providers/provider-fixture/models') => {
        'models': [
          {'id': 'fixture-model-base'},
          {'id': 'fixture-model-fast'},
          {'id': 'fixture-model-plus'},
        ],
      },
      _ => throw StateError('Unexpected fixture request'),
    };
  }
}

class _Runtime extends ClientRuntime {
  _Runtime(_Connection fixture) {
    connection = fixture;
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
  String? get connectedAccountId => 'fixture-owner';
  @override
  Object get ownAiSessionContext => 1;
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
  testWidgets('capture the production chat binding at the same anchor', (
    tester,
  ) async {
    const output = String.fromEnvironment('CAPTURE_PATH');
    const followOn = String.fromEnvironment('CAPTURE_PICK_PATH');
    const after = bool.fromEnvironment('CAPTURE_EXPECT_PICKER');
    const font = String.fromEnvironment('CAPTURE_CJK_FONT');
    const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
    expect(output, isNotEmpty);
    for (final (family, path) in [('Ahem', font), ('MaterialIcons', icons)]) {
      final bytes = File(path).readAsBytesSync();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final connection = _Connection();
    final runtime = _Runtime(connection);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: WhaleChatApp(model: runtime),
      ),
    );
    await tester.pumpAndSettle();

    Finder key(String name) => find.byKey(Key(name));
    Finder outer() => find.byType(Scrollable).first;
    Future<void> show(Finder finder) async {
      await tester.scrollUntilVisible(finder, 240, scrollable: outer());
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await show(key('open-ai-config-write'));
    await tester.tap(key('open-ai-config-write'));
    await tester.pumpAndSettle();
    await show(key('binding-provider'));
    await tester.enterText(key('binding-provider'), 'provider-fixture');
    await tester.enterText(key('binding-model'), 'fixture-manual-model');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(outer()).position;
    final delta =
        tester.getTopLeft(key('help-binding')).dy -
        tester.getTopLeft(outer()).dy -
        64;
    position.jumpTo(
      (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
    await tester.pumpAndSettle();

    Future<void> capture(String path) async {
      expect(tester.takeException(), isNull);
      final painter =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final png = await tester.runAsync(() async {
        final pixels = await painter.toImage();
        try {
          expect((pixels.width, pixels.height), (1280, 960));
          return await pixels.toByteData(format: ui.ImageByteFormat.png);
        } finally {
          pixels.dispose();
        }
      });
      File(path).writeAsBytesSync(
        png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    }

    final read = key('binding-catalog-read');
    expect(key('binding-save').hitTestable(), findsOneWidget);
    expect(read.hitTestable(), after ? findsOneWidget : findsNothing);
    expect(connection.requests, [('POST', '/api/v1/ai-profiles/register')]);
    await capture(output);

    if (followOn.isNotEmpty) {
      expect(after, isTrue);
      await tester.tap(read);
      await tester.pumpAndSettle();
      await tester.tap(find.text('fixture-model-fast').hitTestable());
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(key('binding-model')).controller!.text,
        'fixture-model-fast',
      );
      expect(connection.requests, [
        ('POST', '/api/v1/ai-profiles/register'),
        ('GET', '/api/v1/model-providers/provider-fixture/models'),
      ]);
      await capture(followOn);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });
}
