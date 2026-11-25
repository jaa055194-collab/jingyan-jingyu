import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../runtime_auth_test.dart' show Fixture;

const chatId = 'message-actions-fixture';
const ownId = 'fixture-own';
const oldId = 'fixture-old';
const peerId = 'fixture-peer';
const recalledId = 'fixture-recalled';
const ownText = '我会带上折叠椅。';
const revisedText = '我会带上两把折叠椅。';
const oldText = '上周也在公园见面。';
const peerText = '周末的野餐改到下午三点。';
const draftText = '未发送的草稿';

/// Synthetic loopback fixture sharing real HTTP, codec and cache code with the
/// production client. Exact host response shapes; no user data or OS session.
class MessageActionsFixture {
  MessageActionsFixture(this.host, this.rows);

  final Fixture host;
  final List<Map<String, Object?>> rows;
  final writes = <(String, Object?)>[];
  Future<void> Function()? beforeMutationReply;
  int mutationStatus = 200;

  static Future<MessageActionsFixture> create() async {
    final host = await Fixture.create();
    final now = DateTime.now().toUtc();
    Map<String, Object?> row(
      String id,
      int seq,
      String sender,
      Map<String, Object?> body,
      DateTime sentAt,
    ) => {
      'conversationId': chatId,
      'seq': seq,
      'messageId': id,
      'senderId': sender,
      'kind': 'text',
      'body': body,
      'sentAt': sentAt.toIso8601String(),
    };
    final fixture = MessageActionsFixture(host, [
      row(oldId, 1, 'alice', {
        'text': oldText,
      }, now.subtract(const Duration(days: 7))),
      row(peerId, 2, 'bob', {'text': peerText}, now),
      row(ownId, 3, 'alice', {
        'text': ownText,
        'mentionAccountIds': ['sample-ai'],
      }, now),
      row(recalledId, 4, 'bob', {'recalled': true}, now),
    ]);
    host.secure = jsonEncode(host.session());
    await File('${host.root.path}/settings.json').writeAsString(
      jsonEncode({
        'preferences': {'theme': 'light', 'fontScale': 1},
      }),
    );
    host.serve = fixture._serve;
    return fixture;
  }

  Future<ClientRuntime> open({bool select = true}) async {
    final runtime = ClientRuntime();
    await runtime.initialize();
    runtime.reconnect?.cancel();
    await runtime.refreshConversations();
    await runtime.shell.markRead(chatId, rows.length);
    if (select) await runtime.selectConversation(chatId);
    return runtime;
  }

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    final raw = await utf8.decoder.bind(request).join();
    if (request.method == 'GET' && path.endsWith('/sync')) {
      final conversation = request.uri.pathSegments[3];
      final after = int.parse(request.uri.queryParameters['afterSeq']!);
      await host.reply(request, {
        'messages': [
          if (conversation == chatId)
            for (final row in rows)
              if ((row['seq'] as int) > after) row,
        ],
        'hasMore': false,
      });
    } else if (path == Routes.conversations) {
      await host.reply(request, {
        'conversations': [
          {'id': chatId, 'name': '周末野餐'},
          {'id': 'elsewhere', 'name': '其他会话'},
        ],
      });
    } else if (path == Routes.directConversations) {
      await host.reply(request, {'conversations': []});
    } else if (path == Routes.hostInfo) {
      await host.reply(request, {'isHostMachine': false});
    } else if (path.endsWith('/ack')) {
      await host.reply(request, {'acknowledgedSeq': rows.length});
    } else if (request.method == 'POST' &&
        (path.endsWith('/edit') || path.endsWith('/recall'))) {
      final row = rows.singleWhere(
        (row) => row['messageId'] == request.uri.pathSegments[5],
      );
      final body = raw.isEmpty ? null : jsonDecode(raw);
      writes.add((path, body));
      if (mutationStatus == 200) {
        row['body'] = path.endsWith('/edit')
            ? (body as Map)['body']
            : {'recalled': true};
      }
      await beforeMutationReply?.call();
      if (mutationStatus != 200) {
        await host.reply(request, {'error': 'refused'}, status: mutationStatus);
      } else {
        await host.reply(
          request,
          path.endsWith('/edit') ? row : {'recalled': true},
        );
      }
    } else {
      await host.reply(request, {'error': 'not_found'}, status: 404);
    }
  }
}
