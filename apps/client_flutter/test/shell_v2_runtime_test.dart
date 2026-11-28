import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'runtime_auth_test.dart' show Fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('reduce motion persists with the other preferences', () async {
    await _Host.start(signedIn: false);
    final first = await _open();
    expect(first.reduceMotion, isFalse);
    await first.setFontScale(1.2);
    final seen = <bool>[];
    first.addListener(() => seen.add(first.reduceMotion));

    await first.setReduceMotion(true);
    expect(first.error, isNull);
    expect(first.reduceMotion, isTrue);
    expect(first.preferences['reduceMotion'], isTrue);
    expect(seen, isNotEmpty);
    expect(seen.last, isTrue, reason: 'listeners hear the written value');
    first.dispose();

    final second = await _open();
    expect(second.reduceMotion, isTrue);
    expect(second.fontScale, 1.2);
    await second.setReduceMotion(false);
    second.dispose();

    final third = await _open();
    expect(third.reduceMotion, isFalse);
    expect(third.fontScale, 1.2);
  });

  test('conversations count as loaded without a session', () async {
    await _Host.start(signedIn: false);
    final runtime = await _open();
    expect(runtime.authenticated, isFalse);
    expect(runtime.conversationsLoaded, isTrue);
    expect(runtime.partnerConversationId, isNull);
  });

  test('conversations stay unloaded until the first list read', () async {
    final host = await _Host.start();
    host.gate = Completer<void>();
    final runtime = await _open();
    expect(runtime.authenticated, isTrue);
    expect(runtime.conversationsLoaded, isFalse);
    expect(runtime.conversations, isEmpty);

    host.gate!.complete();
    await runtime.refreshConversations();
    expect(runtime.online, isTrue);
    expect(runtime.conversationsLoaded, isTrue);
    expect(runtime.conversations, isEmpty, reason: 'loaded and empty');
  });

  test('a failed first read ends loading so offline can show', () async {
    final host = await _Host.start();
    host.online = false;
    final runtime = await _open();
    await runtime.refreshConversations();
    expect(runtime.online, isFalse);
    expect(runtime.conversationsLoaded, isTrue);
    expect(runtime.conversations, isEmpty);
  });

  test('conversation rows carry the newest cached message time', () async {
    final host = await _Host.start();
    host.conversations = [
      {'id': 'g1', 'name': 'One', 'ownerAccountId': 'alice'},
      {'id': 'g2', 'name': 'Two', 'ownerAccountId': 'alice'},
    ];
    host.messages['g1'] = [
      _row('g1', 1, '2026-11-19T00:00:00Z'),
      _row('g1', 2, '2026-11-20T08:30:00Z'),
    ];
    final runtime = await _open();
    await runtime.refreshConversations();
    expect(runtime.online, isTrue);

    final rows = {for (final row in runtime.conversations) row.id: row};
    expect(rows.keys, unorderedEquals(['g1', 'g2']));
    expect(
      rows['g1']!.lastActivityAt?.toUtc(),
      DateTime.utc(2026, 11, 20, 8, 30),
    );
    expect(rows['g2']!.lastActivityAt, isNull);
  });
}

Future<ClientRuntime> _open() async {
  final runtime = ClientRuntime();
  addTearDown(runtime.dispose);
  await runtime.initialize();
  runtime.reconnect?.cancel();
  return runtime;
}

Map<String, Object?> _row(String conversationId, int seq, String sentAt) => {
  'conversationId': conversationId,
  'messageId': '$conversationId-$seq',
  'seq': seq,
  'senderId': 'alice',
  'kind': 'text',
  'body': {'text': 'Message $seq'},
  'sentAt': sentAt,
};

class _Host {
  _Host(this.fixture);

  final Fixture fixture;
  bool online = true;
  Completer<void>? gate;
  List<Map<String, Object?>> conversations = [];
  final messages = <String, List<Map<String, Object?>>>{};

  static Future<_Host> start({bool signedIn = true}) async {
    final fixture = await Fixture.create();
    addTearDown(fixture.cleanup);
    final host = _Host(fixture);
    if (signedIn) fixture.secure = jsonEncode(fixture.session());
    fixture.serve = host.serve;
    return host;
  }

  Future<void> serve(HttpRequest request) async {
    await request.drain<void>();
    if (!online) {
      return fixture.reply(request, {'error': 'unavailable'}, status: 503);
    }
    final path = request.uri.path;
    final sync = RegExp(r'^/api/v1/conversations/([^/]+)/sync$')
        .firstMatch(path);
    if (request.method == 'GET' && sync != null) {
      final after = int.parse(request.uri.queryParameters['afterSeq'] ?? '0');
      final rows = messages[sync.group(1)] ?? const <Map<String, Object?>>[];
      return fixture.reply(request, {
        'messages': [
          for (final row in rows)
            if ((row['seq'] as int) > after) row,
        ],
        'hasMore': false,
      });
    }
    switch ((request.method, path)) {
      case ('GET', Routes.hostInfo):
        return fixture.reply(request, {'error': 'forbidden'}, status: 403);
      case ('GET', Routes.conversations):
        await gate?.future;
        return fixture.reply(request, {'conversations': conversations});
      case ('GET', Routes.directConversations):
        return fixture.reply(request, {'conversations': []});
      default:
        return fixture.reply(request, {'error': 'not_found'}, status: 404);
    }
  }
}
