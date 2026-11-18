import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'runtime_auth_test.dart' show Fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('restored owner-AI conversation reads the reply after its saved cursor', () async {
    const id = 'owner-ai-direct';
    const sentAt = '2026-11-18T00:00:00.000Z';
    const prompt = 'Synthetic owner prompt';
    const reply = 'Synthetic AI reply';
    final fixture = await Fixture.create();
    fixture.secure = jsonEncode(fixture.session());
    final syncCursors = <String?>[];
    final posts = <Object?>[];
    final history = <Map<String, Object?>>[];

    Map<String, Object?> row(
      int seq,
      String messageId,
      String senderId,
      String text,
    ) => {
      'conversationId': id,
      'messageId': messageId,
      'seq': seq,
      'senderId': senderId,
      'kind': 'text',
      'body': {'text': text},
      'sentAt': sentAt,
    };

    fixture.serve = (request) async {
      final body = await utf8.decoder.bind(request).join();
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer old-access') {
        return fixture.reply(request, {
          'error': 'unauthenticated',
        }, status: 401);
      }
      final endpoint = (request.method, request.uri.path);
      switch (endpoint) {
        case ('GET', Routes.hostInfo):
          return fixture.reply(request, {'error': 'forbidden'}, status: 403);
        case ('GET', Routes.conversations):
          return fixture.reply(request, {'conversations': []});
        case ('GET', Routes.directConversations):
          // The owner-AI direct conversation already exists on the host.
          return fixture.reply(request, {
            'conversations': [
              {
                'id': id,
                'kind': 'direct',
                'accountLow': 'ai-account',
                'accountHigh': 'alice',
                'createdAt': sentAt,
              },
            ],
          });
        case ('POST', '/api/v1/conversations/$id/messages'):
          posts.add(jsonDecode(body));
          if (history.isEmpty) {
            history.add(row(1, 'owner-message', 'alice', prompt));
          }
          return fixture.reply(request, {
            'duplicate': posts.length > 1,
            'message': history.first,
          });
        case ('GET', '/api/v1/conversations/$id/sync'):
          final rawCursor = request.uri.queryParameters['afterSeq'];
          syncCursors.add(rawCursor);
          final cursor = int.tryParse(rawCursor ?? '');
          if (cursor == null) {
            return fixture.reply(request, {
              'error': 'invalid_argument',
            }, status: 400);
          }
          return fixture.reply(request, {
            'messages': history
                .where((message) => (message['seq'] as int) > cursor)
                .toList(),
            'hasMore': false,
          });
        default:
          return fixture.reply(request, {'error': 'not_found'}, status: 404);
      }
    };

    Future<void> restoreSession(ClientRuntime runtime) async {
      await runtime.initialize();
      runtime.reconnect?.cancel();
      await runtime.refreshConversations();
      expect(runtime.online, isTrue, reason: 'the startup sync succeeded');
    }

    final first = ClientRuntime();
    var firstDisposed = false;
    ClientRuntime? restored;
    try {
      await restoreSession(first);
      expect(first.conversations.single.id, id);
      expect(first.conversations.single.kind, 'direct');
      await first.selectConversation(id);
      first.updateDraft(prompt);
      await first.sendMessage();
      expect(first.error, isNull);
      expect(posts.single, {
        'clientMsgId': isA<String>().having(
          (value) => value.isNotEmpty,
          'nonempty',
          true,
        ),
        'kind': 'text',
        'body': {'text': prompt},
      });
      expect(first.queuedCount, 0);
      await first.refreshConversations();
      expect(first.messages.map((m) => (m.id, m.text)), [
        ('owner-message', prompt),
      ]);
      expect(syncCursors, ['0', '0']);
      first.dispose();
      firstDisposed = true;

      // The reply becomes visible on the fixture only after the client closes.
      history.add(row(2, 'ai-reply', 'ai-account', reply));
      restored = ClientRuntime();
      await restoreSession(restored);
      expect(restored.authenticated, isTrue);
      expect(restored.conversations.single.id, id);
      await restored.selectConversation(id);
      expect(restored.messages.map((m) => (m.id, m.text)), [
        ('owner-message', prompt),
        ('ai-reply', reply),
      ]);
      expect(syncCursors, ['0', '0', '1']);
      await restored.refreshConversations();
      expect(restored.online, isTrue, reason: 'the follow-up sync succeeded');
      expect(syncCursors, ['0', '0', '1', '2']);
      expect(restored.messages.map((m) => m.id), ['owner-message', 'ai-reply']);
      expect(restored.queuedCount, 0);
      expect(posts, hasLength(1));
    } finally {
      restored?.dispose();
      if (!firstDisposed) first.dispose();
      await fixture.cleanup();
    }
  });
}
