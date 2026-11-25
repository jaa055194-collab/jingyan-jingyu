import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';

import 'chat_pins_fixture.dart';
export 'chat_pins_fixture.dart'
    show
        pinsChat,
        otherChat,
        peerMessage,
        ownMessage,
        recalledMessage,
        hiddenMessage,
        peerText,
        ownText;

const reactionActor = 'synthetic-reaction-member';
const legacyReaction = 'synthetic legacy text';
const peerReactionPath =
    '/api/v1/conversations/$pinsChat/messages/$peerMessage/reactions';

/// Real runtime/client HTTP; synthetic server only. Reuses the matched group
/// fixture, including the joined-history floor, unread cursor and existing pin.
class ChatReactionsFixture {
  ChatReactionsFixture._(this.chat);

  final ChatPinsFixture chat;
  final entries = <(String account, String emoji)>{
    (reactionActor, '👍'),
    ('alice', '❤️'),
    (reactionActor, '❤️'),
    (reactionActor, legacyReaction),
  };
  final requests = <(String method, String path, String rawBody)>[];
  int readStatus = 200;
  int writeStatus = 200;
  bool appliesWithoutReceipt = false;
  bool staleReadback = false;
  Future<void> Function()? beforeRead;
  Future<void> Function()? beforeReceipt;
  int get reads => requests.where((r) => r.$1 == 'GET').length;
  int get writes => requests.where((r) => r.$1 == 'POST').length;

  static Future<ChatReactionsFixture> create() async {
    final chat = await ChatPinsFixture.create();
    final fixture = ChatReactionsFixture._(chat);
    final rest = chat.host.serve!;
    chat.host.serve = (request) => request.uri.path.endsWith('/reactions')
        ? fixture._react(request)
        : rest(request);
    return fixture;
  }

  Future<ClientRuntime> open() => chat.openRuntime();
  Future<void> cleanup() => chat.cleanup();

  Future<void> _react(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    final body = raw.isEmpty ? null : jsonDecode(raw);
    final path = request.uri.path;
    final method = request.method;
    requests.add((method, path, raw));
    if (path != peerReactionPath) {
      await chat.host.reply(request, {'error': 'not_found'}, status: 404);
      return;
    }
    if (method == 'GET') {
      await beforeRead?.call();
      if (readStatus != 200) {
        await chat.host.reply(request, {
          'error': 'not_found',
        }, status: readStatus);
      } else {
        await chat.host.reply(request, {
          'reactions': [
            for (final (account, emoji) in entries)
              if (!staleReadback || (account, emoji) != ('alice', '👍'))
                {'accountId': account, 'emoji': emoji},
          ],
        });
      }
      return;
    }
    if (method != 'POST' ||
        body is! Map ||
        body.length != 1 ||
        body['emoji'] is! String) {
      await chat.host.reply(request, {
        'error': 'invalid_argument',
      }, status: 400);
      return;
    }
    final emoji = body['emoji'] as String;
    final row = ('alice', emoji);
    final active = !entries.contains(row);
    if (writeStatus == 200 || appliesWithoutReceipt) {
      if (active) {
        entries.add(row);
      } else {
        entries.remove(row);
      }
    }
    await beforeReceipt?.call();
    if (writeStatus == 200) {
      await chat.host.reply(request, {'emoji': emoji, 'active': active});
    } else {
      await chat.host.reply(request, {
        'error': 'not_found',
      }, status: writeStatus);
    }
  }
}
