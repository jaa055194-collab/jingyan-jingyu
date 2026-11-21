import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../runtime_auth_test.dart' show Fixture, channel;

/// Real app runtime, HTTP parser and snapshots against a synthetic loopback
/// server. Only the OS storage boundary is replaced by the existing test seam.
class ForegroundNoticeFixture {
  ForegroundNoticeFixture._(this.host);

  static const conversation = 'fixture-message-cue';
  static const peerText = 'Synthetic private content for notice regression';
  static const notice = '收到新消息，可在聊天中查看。';
  static const contactsEmpty = '暂无联系人或待处理的好友邀请。';
  final Fixture host;
  final runtime = ClientRuntime();
  final rows = <Map<String, Object?>>[];
  final writes = <String>[];
  int? firstVisibleSeq;
  bool offline = false;
  Future<void> Function()? beforeSyncReply;

  static Future<ForegroundNoticeFixture> open({bool history = false}) async {
    final f = ForegroundNoticeFixture._(await Fixture.create());
    try {
      if (history) f.add();
      f.host.secure = jsonEncode(f.host.session());
      f.host.serve = f._serve;
      await File('${f.host.root.path}/settings.json')
          .writeAsString('{"preferences":{"theme":"light","fontScale":1}}');
      await f.runtime.initialize();
      f.runtime.reconnect?.cancel();
      await f.runtime.refreshConversations();
      expect(f.runtime.authenticated, isTrue);
      expect(f.runtime.online, isTrue);
      expect(f.runtime.conversations.single.id, conversation);
      return f;
    } catch (_) {
      await f.close();
      rethrow;
    }
  }

  void add({String sender = 'fixture-peer', Map<String, Object?>? body}) {
    final seq = rows.length + 1;
    rows.add({
      'conversationId': conversation,
      'seq': seq,
      'messageId': 'cue-fixture-$seq',
      'senderId': sender,
      'kind': 'text',
      'body': body ?? const {'text': peerText},
      'sentAt': '2026-11-21T00:00:00Z',
    });
  }

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    await request.drain<void>();
    if (request.method != 'GET') {
      writes.add(path);
      return host.reply(request, const {}, status: 400);
    }
    if (request.headers.value('authorization') != 'Bearer old-access') {
      return host.reply(request, const {}, status: 403);
    }
    if (offline) return host.reply(request, const {}, status: 503);
    switch (path) {
      case Routes.hostInfo:
        return host.reply(request, {'isHostMachine': false});
      case Routes.conversations:
        return host.reply(request, {
          'conversations': [
            {'id': conversation, 'name': '合成会话'},
          ],
        });
      case Routes.directConversations:
        return host.reply(request, {'conversations': []});
      case Routes.friends || Routes.notifications:
        request.response.headers.contentType = ContentType.json;
        request.response.write('[]');
        return request.response.close();
    }
    final syncPath = Routes.sync.replaceAll('{conversationId}', conversation);
    if (path == syncPath) {
      await beforeSyncReply?.call();
      final afterSeq = int.parse(request.uri.queryParameters['afterSeq']!);
      final floor = firstVisibleSeq ?? 1;
      return host.reply(request, {
        if (firstVisibleSeq != null) 'firstVisibleSeq': floor,
        'messages': [
          for (final row in rows)
            if ((row['seq'] as int) > afterSeq && (row['seq'] as int) >= floor)
              row,
        ],
        'hasMore': false,
      });
    }
    return host.reply(request, const {}, status: 404);
  }

  Future<void> refresh(WidgetTester tester) async {
    await tester.runAsync(runtime.refreshConversations);
    await tester.pump();
  }

  Future<void> close() async {
    runtime.dispose();
    await host.cleanup();
  }
}

Future<void> openNoticeFixturePage(WidgetTester tester, String label) async {
  // Dispatch in the real zone so the production inbox/contacts HTTP can finish.
  await tester.runAsync(() async {
    await tester.tap(find.text(label).last);
    await tester.pump();
    if (label != '联系人' && label != '收件箱') return;
    final expected = label == '联系人'
        ? find.text(ForegroundNoticeFixture.contactsEmpty)
        : find.byKey(const Key('inbox-empty'));
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (expected.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
    expect(expected, findsOneWidget);
  });
  await tester.pump();
}

Future<void> sendNoticeFixtureEvent(WidgetTester tester, String event) async {
  await tester.runAsync(() async {
    final done = Completer<void>();
    tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('event', {'type': event}),
      ),
      (_) => done.complete(),
    );
    await done.future;
  });
  await tester.pump();
}
