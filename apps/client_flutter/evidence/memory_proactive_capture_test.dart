import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/net/host_connection.dart'
    show HostReadCancellation;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../test/support/owner_memory_notes_fixture.dart';
import '../test/support/owner_reply_preferences_fixture.dart';

/// Before/After capture for the two hard-gate settings sections. The harness
/// uses the real Settings route and the real editor with a synthetic host
/// boundary; no user account, real provider or device is involved.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  testWidgets(
    'render matched Android auto-memory and proactive settings',
    (t) async {
      const before = bool.fromEnvironment('CAPTURE_BEFORE');
      const output = String.fromEnvironment('CAPTURE_OUTPUT');
      const cjk = String.fromEnvironment('CAPTURE_CJK_FONT');
      const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
      expect(output, isNotEmpty);
      for (final (family, font) in [
        ('Ahem', cjk),
        ('Roboto', cjk),
        ('MaterialIcons', icons),
      ]) {
        final data = File(font).readAsBytesSync();
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.sublistView(data)))).load();
      }
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.textScaleFactorTestValue = 1;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);

      final connection = _SectionsConnection();
      final runtime = PreferencesRuntime(connection);
      final boundary = GlobalKey();

      Future<void> capture(String name) async {
        expect(t.takeException(), isNull);
        final paint =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final bytes = (await t.runAsync(() async {
          final image = await paint.toImage();
          try {
            expect((image.width, image.height), (390, 844));
            return await image.toByteData(format: ui.ImageByteFormat.png);
          } finally {
            image.dispose();
          }
        }))!;
        File('$output/memory-proactive-$name.png').writeAsBytesSync(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      }

      Future<void> reveal(String key) async {
        // The editor uses a lazy ListView. Scroll incrementally until the
        // section is built, then centre it in the viewport.
        final found = find.byKey(Key(key));
        final position = t
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position;
        for (var i = 0; i < 30 && found.evaluate().isEmpty; i++) {
          position.jumpTo((i + 1) * 300.0);
          await t.pumpAndSettle();
        }
        expect(found, findsOneWidget);
        await t.scrollUntilVisible(
          found,
          80,
          scrollable: find.byType(Scrollable).first,
        );
        await t.pumpAndSettle();
      }

      try {
        await openPreferencesEditor(t, runtime, boundary: boundary);
        if (before) {
          expect(
            find.byKey(const Key('owner-auto-memory-section')),
            findsNothing,
          );
          expect(
            find.byKey(const Key('owner-model-proactive-card')),
            findsNothing,
          );
          await capture('before');
          return;
        }
        await reveal('owner-auto-memory-section');
        await capture('after-auto-memory');
        expect(find.text('自动记忆'), findsOneWidget);
        await reveal('owner-model-proactive-card');
        expect(find.text('本人模型主动联系'), findsOneWidget);
        await capture('after-proactive');
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        runtime.dispose();
        await t.runAsync(connection.close);
      }
    },
  );
}

/// Extends the existing preference fixture so the real Settings route, profile
/// resolution and editor stay in use. New hard-gate routes are served from
/// bounded synthetic state. The file only uses APIs that exist in the baseline,
/// so the same test compiles before and after the change.
class _SectionsConnection extends MemoryNotesConnection {
  final auto = <String, Object?>{
    'revision': 1,
    'enabled': false,
    'target': syntheticTarget,
  };
  final entries = <String, Object?>{
    'revision': 1,
    'maxEntries': 50,
    'entries': [
      {
        'id': 'entry-a',
        'text': '记住我喜欢桂花',
        'tier': 't0',
        'status': 'active',
        'createdAt': '2026-01-01T09:00:00.000Z',
      },
      {
        'id': 'entry-b',
        'text': '今天有点累',
        'tier': 't1',
        'status': 'pending',
        'createdAt': '2026-01-01T09:01:00.000Z',
      },
    ],
  };
  final proactive = <String, Object?>{
    'revision': 0,
    'enabled': false,
    'localMinute': 540,
    'offsetMinutes': 480,
    'quietStartMinute': 1380,
    'quietEndMinute': 480,
    'intervalMinutes': 1440,
    'globalBlocked': false,
    'globalRevision': 0,
    'socialLevel': 'L3',
    'chatRevision': 3,
    'budgetReady': true,
    'lastSentAt': null,
  };

  bool _autoPath(String path) => path.contains('/owner-auto-memory');
  bool _proactivePath(String path) => path.contains('/owner-model-proactive');

  @override
  Future<Map<String, Object?>> getBoundedJson(
    String path, {
    required int maxResponseBytes,
    HostReadCancellation? cancellation,
  }) async {
    if (_autoPath(path)) {
      return Map<String, Object?>.from(
        path.endsWith('/settings') ? auto : entries,
      );
    }
    if (_proactivePath(path)) {
      return Map<String, Object?>.from(proactive);
    }
    return super.getBoundedJson(
      path,
      maxResponseBytes: maxResponseBytes,
      cancellation: cancellation,
    );
  }

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    if (_autoPath(path) || _proactivePath(path)) {
      // Read-only evidence capture: no enable confirmation is performed.
      throw StateError('unexpected hard-gate write $method $path');
    }
    return super.request(
      method,
      path,
      body: body,
      query: query,
      retryAuthentication: retryAuthentication,
      allowEmptySuccess: allowEmptySuccess,
    );
  }
}
