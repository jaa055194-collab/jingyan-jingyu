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
const _history = '/api/v1/ai-profiles/fixture-profile/persona/history';

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

  // Deliberately no @override: the same driver compiles on the Before tree.
  // ignore: annotate_overrides
  Future<Map<String, Object?>> getBoundedJsonWithQuery(
    String path, {
    required Map<String, String> query,
    required int maxResponseBytes,
    HostReadCancellation? cancellation,
  }) async {
    calls.add(('GET', path));
    expect(path, _history);
    expect(query, {'afterVersion': '0', 'limit': '20'});
    expect(cancellation, isNotNull);
    return _fixtureHistory();
  }
}

Map<String, Object?> _fixtureHistory() {
  final layers = {
    for (final layer in ['p0', 'p1', 'p2'])
      layer: {'fixture-field': 'fixture-value'},
  };
  return {
    'changes': [
      for (final (version, kind) in [
        (1, 'initialize'),
        (2, 'edit'),
        (3, 'lock'),
      ])
        {
          'id': 'fictional-change-$version',
          'version': version,
          'kind': kind,
          'actorAccountId': 'fixture-owner',
          'before': version == 1 ? null : layers,
          'after': layers,
          'diff': version == 1
              ? layers
              : {
                  'p0': <String, String>{},
                  'p1': version == 2
                      ? {'fixture-field': 'fixture-update'}
                      : <String, String>{},
                  'p2': <String, String>{},
                },
          'reason': 'fixture-reason',
          'evidenceIds': <String>[],
          'at': '2026-02-0${version}T10:30:00.000Z',
          'lockedBefore': version == 1 ? null : false,
          'lockedAfter': version == 3,
          'revertsChangeId': null,
        },
    ],
    'nextAfterVersion': null,
  };
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
  testWidgets('render the production persona card at the same anchor', (
    tester,
  ) async {
    const output = String.fromEnvironment('CAPTURE_PATH');
    const opened = String.fromEnvironment('CAPTURE_HISTORY_PATH');
    const after = bool.fromEnvironment('CAPTURE_EXPECT_HISTORY');
    const cjk = String.fromEnvironment('CAPTURE_CJK_FONT');
    const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
    expect(output, isNotEmpty);
    for (final (family, path) in [('Ahem', cjk), ('MaterialIcons', icons)]) {
      final bytes = File(path).readAsBytesSync();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    final outer = find.byType(Scrollable).first;
    Future<void> show(Finder finder) async {
      await tester.scrollUntilVisible(finder, 240, scrollable: outer);
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await show(key('open-ai-config-write'));
    await tester.tap(key('open-ai-config-write'));
    await tester.pumpAndSettle();
    final anchor = key('help-persona');
    await show(anchor);
    final position = tester.state<ScrollableState>(outer).position;
    final target =
        position.pixels +
        tester.getTopLeft(anchor).dy -
        tester.getTopLeft(outer).dy -
        40;
    position.jumpTo(
      target.clamp(position.minScrollExtent, position.maxScrollExtent),
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
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(
        png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    }

    final read = key('persona-history-read');
    expect(key('persona-initialize').hitTestable(), findsOneWidget);
    expect(read.hitTestable(), after ? findsOneWidget : findsNothing);
    expect(host.calls, [('POST', _register)]);
    await capture(output);
    if (opened.isNotEmpty) {
      expect(after, isTrue);
      await tester.tap(read.hitTestable());
      await tester.pumpAndSettle();
      expect(host.calls, [('POST', _register), ('GET', _history)]);
      expect(key('persona-history-notice'), findsNothing);
      expect(find.textContaining('初始化'), findsWidgets);
      final firstVersion = key('persona-history-version-1');
      expect(firstVersion, findsOneWidget);
      await tester.ensureVisible(firstVersion);
      await tester.pumpAndSettle();
      expect(find.textContaining('fixture-value'), findsNothing);
      expect(find.textContaining('fixture-reason'), findsNothing);
      await capture(opened);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
