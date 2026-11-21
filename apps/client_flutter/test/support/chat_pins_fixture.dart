import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../runtime_auth_test.dart' show Fixture;

const pinsChat = 'fixture-pins-chat';
const otherChat = 'fixture-other-chat';
const peerMessage = 'fixture-peer-message';
const ownMessage = 'fixture-own-message';
const recalledMessage = 'fixture-recalled-message';
const hiddenMessage = 'fixture-hidden-message';
const peerText = '周六下午三点，公园东门见。';
const ownText = '我会带上野餐垫。';
const hiddenActor = 'fixture-hidden-actor';
const _timestamp = '2026-11-20T10:04:03.000Z';

/// Real loopback HTTP and client runtime; no real user session. Includes an
/// old host response listing metadata for rows outside visible history.
class ChatPinsFixture {
  ChatPinsFixture._(this.host);

  final Fixture host;
  final pinned = <String>{peerMessage, hiddenMessage, recalledMessage};
  final requests = <(String method, String path, String rawBody)>[];
  int hostInfoStatus = 200;
  int listStatus = 200;
  int writeStatus = 200;
  bool commitWithoutReceipt = false;
  Map<String, Object?>? listOverride;
  Future<void> Function()? beforeList;
  Future<void> Function()? beforeWriteReceipt;
  int? readStatusAfterWrite;

  List<(String, String, String)> get writes => [
    for (final request in requests)
      if (request.$1 != 'GET' && request.$2.endsWith('/pin')) request,
  ];
  int get reads =>
      requests.where((request) => request.$2.endsWith('/pins')).length;

  static Future<ChatPinsFixture> create() async {
    final host = await Fixture.create();
    host.secure = jsonEncode(host.session());
    final fixture = ChatPinsFixture._(host);
    host.serve = fixture._serve;
    await File('${host.root.path}/settings.json').writeAsString(
      jsonEncode({
        'preferences': {'theme': 'light', 'fontScale': 1},
      }),
    );
    return fixture;
  }

  Future<ClientRuntime> openRuntime({bool select = false}) async {
    final runtime = ClientRuntime();
    await runtime.initialize();
    runtime.reconnect?.cancel();
    await runtime.refreshConversations();
    await runtime.shell.markRead(pinsChat, 4);
    if (select) await runtime.selectConversation(pinsChat);
    return runtime;
  }

  Future<void> cleanup() => host.cleanup();

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    final raw = await utf8.decoder.bind(request).join();
    requests.add((method, path, raw));
    switch ((method, path)) {
      case ('GET', Routes.hostInfo):
        await host.reply(request, {
          if (hostInfoStatus == 200)
            'isHostMachine': false
          else
            'error': 'unavailable',
        }, status: hostInfoStatus);
      case ('GET', Routes.conversations):
        await host.reply(request, {
          'conversations': [
            {'id': pinsChat, 'name': '周末野餐', 'ownerAccountId': 'alice'},
            {'id': otherChat, 'name': '其他会话'},
          ],
        });
      case ('GET', Routes.directConversations):
        await host.reply(request, {'conversations': []});
      case ('GET', '/api/v1/conversations/$pinsChat/sync'):
        final after = int.parse(request.uri.queryParameters['afterSeq']!);
        await host.reply(request, {
          'firstVisibleSeq': 2,
          'messages': [
            for (final (seq, id, sender, body) in [
              (2, peerMessage, 'bob', {'text': peerText}),
              (3, ownMessage, 'alice', {'text': ownText}),
              (4, recalledMessage, 'bob', {'recalled': true}),
            ])
              if (seq > after)
                {
                  'conversationId': pinsChat,
                  'seq': seq,
                  'messageId': id,
                  'senderId': sender,
                  'kind': 'text',
                  'body': body,
                  'sentAt': _timestamp,
                },
          ],
          'hasMore': false,
        });
      case ('GET', '/api/v1/conversations/$otherChat/sync'):
        await host.reply(request, {'messages': [], 'hasMore': false});
      case ('GET', '/api/v1/conversations/$pinsChat/pins'):
        await beforeList?.call();
        if (listStatus != 200) {
          await host.reply(request, {
            'error': 'pins_unavailable',
          }, status: listStatus);
        } else {
          await host.reply(
            request,
            listOverride ??
                {
                  'pins': [
                    for (final id in pinned)
                      {
                        'messageId': id,
                        'pinnedBy': id == hiddenMessage ? hiddenActor : 'bob',
                        'pinnedAt': _timestamp,
                      },
                  ],
                },
          );
        }
      case ('POST' || 'DELETE', _)
          when path.startsWith('/api/v1/conversations/$pinsChat/messages/') &&
              path.endsWith('/pin'):
        final id = request.uri.pathSegments[5];
        final adding = method == 'POST';
        var duplicate = false;
        if (writeStatus == 200 || commitWithoutReceipt) {
          if (adding) {
            duplicate = !pinned.add(id);
          } else {
            pinned.remove(id);
          }
        }
        await beforeWriteReceipt?.call();
        if (readStatusAfterWrite case final status?) listStatus = status;
        if (writeStatus != 200) {
          await host.reply(request, {
            'error': 'not_confirmed',
          }, status: writeStatus);
        } else {
          await host.reply(request, {
            'pinned': adding,
            if (adding) 'duplicate': duplicate,
          });
        }
      case ('POST', '/api/v1/conversations/$pinsChat/ack'):
        await host.reply(request, {'acknowledgedSeq': 4});
      default:
        await host.reply(request, {'error': 'not_found'}, status: 404);
    }
  }
}
