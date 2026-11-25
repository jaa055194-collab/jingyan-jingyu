import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'chat_pins_fixture.dart';
export 'chat_pins_fixture.dart' show pinsChat, otherChat, peerText;

const schedulePath = '/api/v1/conversations/$pinsChat/scheduled-messages';
const scheduleDirect = 'fixture-direct-chat';
const scheduleDraft = '保留这段聊天草稿';
const scheduleText = '带一件备用雨衣。';
const scheduleDate = '2090-06-15';
const scheduleTime = '09:32';
const scheduleId = 'scheduled-fixture-1';
final scheduledInstant = DateTime(2090, 6, 15, 9, 32).toUtc();

/// This replaces only the loopback host's scheduling routes. The application,
/// authenticated session, group selection, draft and HTTP adapter are real.
class ScheduledMessagesFixture {
  ScheduledMessagesFixture._(this.chat);
  final ChatPinsFixture chat;
  final rows = <String, Map<String, Object?>>{};
  final calls = <(String method, String uri, String body)>[];
  bool refuseList = false;
  bool loseCreateReceipt = false;
  bool loseCancelReceipt = false;
  bool cancelApplies = true;
  bool hideKnown = false;
  Future<void> Function()? beforeResponse;
  bool get hasMutations => calls.any((entry) => entry.$1 != 'GET');

  static Future<ScheduledMessagesFixture> create() async {
    final chat = await ChatPinsFixture.create();
    final fixture = ScheduledMessagesFixture._(chat);
    final original = chat.host.serve!;
    chat.host.serve = (request) async {
      final path = request.uri.path;
      if (path == schedulePath || path.startsWith('$schedulePath/')) {
        await fixture._serve(request);
      } else if (path == '/api/v1/direct-conversations') {
        await request.drain<void>();
        await chat.host.reply(request, {
          'conversations': [
            {
              'id': scheduleDirect,
              'peerAccountId': 'bob',
              'peerDisplayName': '示例联系人',
            },
          ],
        });
      } else if (path == '/api/v1/conversations/$scheduleDirect/sync') {
        await request.drain<void>();
        await chat.host.reply(request, {'messages': [], 'hasMore': false});
      } else {
        await original(request);
      }
    };
    return fixture;
  }

  Future<ClientRuntime> open() => chat.openRuntime();
  Future<void> cleanup() async {
    try {
      await chat.cleanup();
    } on PathAccessException {
      // The host server is already closed. A pending account-snapshot write can
      // briefly retain the OS temp directory; it is unrelated to the app checks.
    }
  }

  void seed(String id, String status) {
    rows[id] = {
      'id': id,
      'conversationId': pinsChat,
      'deliverAt': scheduledInstant.toIso8601String(),
      'status': status,
    };
  }

  Future<void> _serve(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    final uri = req.uri;
    calls.add((req.method, uri.toString(), raw));
    switch (req.method) {
      case 'GET':
        await beforeResponse?.call();
        final id = uri.queryParameters['scheduledId'];
        if (refuseList ||
            (id != null && (hideKnown || !rows.containsKey(id)))) {
          await chat.host.reply(req, {'error': 'not_found'}, status: 404);
        } else {
          final page = id == null
              ? rows.values.toList().reversed.toList()
              : [rows[id]!];
          await chat.host.reply(req, {
            'scheduledMessages': page.take(50).toList(),
            'hasMore': page.length > 50,
          });
        }
      case 'POST':
        final body = jsonDecode(raw) as Map<String, Object?>;
        expect(body.keys, unorderedEquals(['kind', 'body', 'deliverAt']));
        expect(body['kind'], 'text');
        final text = body['body'] as Map<String, Object?>;
        expect(text.keys, ['text']);
        expect(text['text'], isA<String>());
        final id = 'scheduled-fixture-${rows.length + 1}';
        rows[id] = {
          'id': id,
          'conversationId': pinsChat,
          'deliverAt': body['deliverAt'],
          'status': 'pending',
        };
        await beforeResponse?.call();
        if (loseCreateReceipt) {
          await chat.host.reply(req, {
            'error': 'synthetic ambiguous result',
          }, status: 500);
        } else {
          await chat.host.reply(req, rows[id]!);
        }
      case 'DELETE':
        final row = rows[uri.pathSegments.last];
        expect(raw, isEmpty);
        if (row?['status'] != 'pending') {
          await chat.host.reply(req, {
            'error': 'invalid_argument',
          }, status: 400);
          return;
        }
        if (cancelApplies) row!['status'] = 'cancelled';
        await beforeResponse?.call();
        if (loseCancelReceipt) {
          await chat.host.reply(req, {
            'error': 'synthetic ambiguous result',
          }, status: 500);
        } else {
          await chat.host.reply(req, {'cancelled': true});
        }
      default:
        await chat.host.reply(req, {'error': 'not_found'}, status: 404);
    }
  }
}

Finder scheduleKey(String key) => find.byKey(Key(key));

Future<void> showScheduleChat(
  WidgetTester t,
  ClientRuntime runtime, {
  Key? boundary,
}) async {
  await t.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: WhaleChatApp(model: runtime),
    ),
  );
  await t.pumpAndSettle();
  await t.tap(scheduleKey(pinsChat));
  await t.pumpAndSettle();
  expect(find.text(peerText), findsOneWidget);
  await t.enterText(scheduleKey('composer'), scheduleDraft);
  await t.pumpAndSettle();
  // Let the draft checkpoint finish its real file IO before teardown.
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
}

Future<void> tapSchedule(WidgetTester t, String key) async {
  final found = scheduleKey(key);
  expect(found, findsOneWidget);
  await t.ensureVisible(found);
  await t.pump();
  expect(found.hitTestable(), findsOneWidget);
  await t.tap(found);
  await t.pumpAndSettle();
}

Future<void> tapScheduleAndWait(
  WidgetTester t,
  String action,
  String result,
) async {
  final target = scheduleKey(action);
  await t.ensureVisible(target);
  await t.pump();
  expect(target.hitTestable(), findsOneWidget);
  await t.runAsync(() async {
    await t.tap(target);
    await t.pump();
    final clock = Stopwatch()..start();
    var sawBusy = false;
    while (clock.elapsed < const Duration(seconds: 8)) {
      final busy = scheduleKey('schedule-loading').evaluate().isNotEmpty;
      if (busy) sawBusy = true;
      if (sawBusy && !busy && scheduleKey(result).evaluate().isNotEmpty) break;
      await t.pump(const Duration(milliseconds: 16));
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }
    expect(scheduleKey(result), findsOneWidget);
    expect(scheduleKey('schedule-loading'), findsNothing);
  });
  await t.pump(const Duration(milliseconds: 100));
}

Future<void> enterScheduleFields(
  WidgetTester t, {
  String date = scheduleDate,
  String time = scheduleTime,
}) async {
  for (final (key, value) in [
    ('schedule-text', scheduleText),
    ('schedule-date', date),
    ('schedule-time', time),
  ]) {
    final field = scheduleKey(key);
    await t.ensureVisible(field);
    await t.enterText(field, value);
    await t.pump();
  }
}
