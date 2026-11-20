import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/platform/native_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'runtime_auth_test.dart' show Fixture;

const _joined = 'joined-group';
const _ordinary = 'ordinary-group';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'joined group paginates its visible suffix and resumes on restart',
    () async {
      final host = await _Host.start(
        (cursor) => switch (cursor) {
          0 => _page([_message(_joined, 3)], floor: 3, hasMore: true),
          3 => _page([_message(_joined, 4)], floor: 3),
          4 => _page([], floor: 3),
          _ => throw StateError('Unexpected joined group cursor $cursor'),
        },
      );
      final first = await host.open();
      expect(first.online, isTrue);
      await first.selectConversation(_joined);
      expect(first.messages.map((entry) => entry.id), [
        'joined-group-3',
        'joined-group-4',
      ]);
      expect(first.shell.lastSeqFor(_joined), 4);
      expect(first.shell.messagesFor(_ordinary).single.seq, 1);
      expect(host.requests, [(_joined, 0), (_joined, 3), (_ordinary, 0)]);
      first.dispose();

      final restored = await host.open();
      expect(restored.online, isTrue);
      expect(host.requests.skip(3), [(_joined, 4), (_ordinary, 1)]);
      expect(restored.shell.messagesFor(_joined).map((entry) => entry.seq), [
        3,
        4,
      ]);
      expect(host.posts, 0);
    },
  );

  test('empty first page saves the floor for a later reconnect', () async {
    var joinedMessageAvailable = false;
    final host = await _Host.start(
      (cursor) => _page(
        joinedMessageAvailable && cursor < 3 ? [_message(_joined, 3)] : [],
        floor: 3,
      ),
    );
    final first = await host.open();
    expect(first.online, isTrue);
    expect(first.shell.lastSeqFor(_joined), 2);
    expect(first.shell.messagesFor(_joined), isEmpty);
    first.dispose();

    joinedMessageAvailable = true;
    final restored = await host.open();
    expect(restored.online, isTrue);
    expect(host.requests, [
      (_joined, 0),
      (_ordinary, 0),
      (_joined, 2),
      (_ordinary, 1),
    ]);
    expect(restored.shell.messagesFor(_joined).single.seq, 3);
    expect(host.posts, 0);
  });

  test(
    'rejoining removes the old cached prefix and keeps other conversations',
    () async {
      var rejoined = false;
      final host = await _Host.start(
        (cursor) => rejoined
            ? _page(cursor < 4 ? [_message(_joined, 4)] : [], floor: 4)
            : _page([
                for (final seq in [1, 2])
                  if (seq > cursor) _message(_joined, seq),
              ]),
      );
      final client = await host.open();
      expect(client.online, isTrue);
      expect(client.shell.messagesFor(_joined).map((entry) => entry.seq), [
        1,
        2,
      ]);
      rejoined = true;
      await client.refreshConversations();
      expect(client.online, isTrue);
      expect(client.shell.messagesFor(_joined).single.seq, 4);
      expect(client.shell.messagesFor(_ordinary).single.seq, 1);
      client.dispose();

      final restored = await host.open();
      expect(restored.shell.messagesFor(_joined).single.seq, 4);
      expect(restored.shell.messagesFor(_ordinary).single.seq, 1);
      expect(host.posts, 0);
    },
  );

  test(
    'live gap recovery can ingest the confirmed joined history suffix',
    () async {
      var available = false;
      final host = await _Host.start(
        (cursor) => available
            ? _page([_message(_joined, 3), _message(_joined, 4)], floor: 3)
            : _page([]),
      );
      final client = await host.open();
      available = true;
      await client.shell.acceptMessage(
        MessageEventFrame(
          id: 'live-4',
          at: DateTime.utc(2026, 11, 19),
          conversationId: _joined,
          seq: 4,
          messageId: 'joined-group-4',
          senderId: 'friend',
          kind: MessageKind.text,
          body: const {'text': 'Synthetic joined-group message 4'},
          sentAt: DateTime.utc(2026, 11, 19),
        ),
      );
      expect(host.requests, [(_joined, 0), (_ordinary, 0), (_joined, 0)]);
      expect(client.shell.messagesFor(_joined).map((entry) => entry.seq), [
        3,
        4,
      ]);
      expect(client.shell.lastSeqFor(_joined), 4);
      expect(host.posts, 0);
    },
  );

  for (final unlockBeforeReply in [false, true]) {
    test(
      'lock cancels in-flight pages, unlock-before-reply=$unlockBeforeReply',
      () async {
        final started = Completer<void>();
        final release = Completer<void>();
        final restarted = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        var tracking = false;
        final relevantCursors = <int>[];
        final host = await _Host.start((cursor) async {
          if (!tracking) return _page([]);
          relevantCursors.add(cursor);
          if (relevantCursors.length == 1) {
            started.complete();
            await release.future;
            return _page([_message(_joined, 3)], floor: 3, hasMore: true);
          }
          if (!restarted.isCompleted) restarted.complete();
          return _page([
            for (final seq in [3, 4])
              if (seq > cursor) _message(_joined, seq),
          ], floor: 3);
        });
        final client = await host.open();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativePlatform.channel, (call) async {
              if (call.method == 'unlockPin') return true;
              return null;
            });
        await client.setAppLock(true, '1234');
        expect(client.appLockEnabled, isTrue);
        tracking = true;
        final refresh = client.refreshConversations();
        await started.future.timeout(const Duration(seconds: 10));
        client.appLock.lock();
        if (unlockBeforeReply) await client.unlock('1234');
        release.complete();
        await refresh;
        if (!unlockBeforeReply) {
          expect(relevantCursors, [0]);
          expect(client.shell.lastSeqFor(_joined), 0);
          expect(client.shell.messagesFor(_joined), isEmpty);
          await client.unlock('1234');
        }
        await restarted.future.timeout(const Duration(seconds: 10));
        expect(relevantCursors.take(2), [0, 0]);
        await client.refreshConversations();
        expect(
          client.shell.messagesFor(_joined).map((message) => message.seq),
          [3, 4],
        );
        expect(host.posts, 0);
      },
    );
  }

  test(
    'unlock replaces a refresh interrupted while listing conversations',
    () async {
      final listing = Completer<void>();
      final release = Completer<void>();
      final restarted = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final host = await _Host.start((_) => _page([]));
      final client = await host.open();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativePlatform.channel, (call) async {
            if (call.method == 'unlockPin') return true;
            return null;
          });
      await client.setAppLock(true, '1234');
      var lists = 0;
      const oldList = 'old-list';
      host.fixture.serve = (request) async {
        if (request.uri.path == Routes.conversations) {
          lists++;
          if (lists == 1) {
            listing.complete();
            await release.future;
            return host.fixture.reply(request, {
              'conversations': [
                {'id': oldList, 'name': 'Outdated list'},
              ],
            });
          }
          if (!restarted.isCompleted) restarted.complete();
        }
        if (request.uri.path == '/api/v1/conversations/$oldList/sync') {
          host.requests.add((oldList, 0));
          return host.fixture.reply(request, _page([]));
        }
        return host.serve(request);
      };
      final refresh = client.refreshConversations();
      await listing.future.timeout(const Duration(seconds: 10));
      client.appLock.lock();
      await client.unlock('1234');
      release.complete();
      await refresh;
      expect(host.requests.where((request) => request.$1 == oldList), isEmpty);
      await restarted.future.timeout(const Duration(seconds: 10));
      await client.refreshConversations();
      expect(client.conversations.map((group) => group.id), [
        _joined,
        _ordinary,
      ]);
    },
  );

  test('rejects unpersistable message body before changing the page', () async {
    final invalidRow = {
      ..._message(_joined, 4),
      'body': {'text': 'Synthetic message', 'extra': 'number-marker'},
    };
    final malformed = jsonEncode(
      _page([_message(_joined, 3), invalidRow], floor: 3),
    ).replaceFirst('"number-marker"', '1e999');
    final host = await _Host.start((_) => malformed);
    final client = await host.open();
    expect(client.online, isFalse);
    expect(client.shell.lastSeqFor(_joined), 0);
    expect(client.shell.messagesFor(_joined), isEmpty);
  });

  final invalid = <String, Map<String, Object?>>{
    'wrong conversation after a valid row': _page([
      _message(_joined, 1),
      _message(_ordinary, 2),
    ]),
    'gap after a valid row': _page([
      _message(_joined, 1),
      _message(_joined, 3),
    ]),
    'gap after a confirmed floor': _page([
      _message(_joined, 3),
      _message(_joined, 5),
    ], floor: 3),
    'string floor even for contiguous rows': _page([
      _message(_joined, 1),
    ], floor: '1'),
    'zero floor': _page([], floor: 0),
    'empty paginated page': _page([], floor: 3, hasMore: true),
  };
  for (final entry in invalid.entries) {
    test('rejects ${entry.key} before changing any cursor or cache', () async {
      final host = await _Host.start((_) => entry.value);
      final client = await host.open();
      expect(client.online, isFalse);
      expect(client.shell.lastSeqFor(_joined), 0);
      expect(client.shell.lastSeqFor(_ordinary), 0);
      expect(client.shell.messagesFor(_joined), isEmpty);
      expect(client.shell.messagesFor(_ordinary), isEmpty);
      expect(host.posts, 0);
    });
  }
}

Map<String, Object?> _message(String conversation, int seq) => {
  'conversationId': conversation,
  'seq': seq,
  'messageId': '$conversation-$seq',
  'senderId': 'friend',
  'kind': 'text',
  'body': {'text': 'Synthetic $conversation message $seq'},
  'sentAt': '2026-11-19T00:00:00Z',
};

Map<String, Object?> _page(
  List<Map<String, Object?>> messages, {
  Object? floor,
  bool hasMore = false,
}) => {'messages': messages, 'hasMore': hasMore, 'firstVisibleSeq': ?floor};

class _Host {
  _Host(this.fixture, this.joinedPage);
  final Fixture fixture;
  final FutureOr<Object> Function(int cursor) joinedPage;
  final requests = <(String, int)>[];
  var posts = 0;

  static Future<_Host> start(
    FutureOr<Object> Function(int cursor) joinedPage,
  ) async {
    final fixture = await Fixture.create();
    addTearDown(fixture.cleanup);
    fixture.secure = jsonEncode(fixture.session());
    final host = _Host(fixture, joinedPage);
    fixture.serve = host.serve;
    return host;
  }

  Future<ClientRuntime> open() async {
    final runtime = ClientRuntime();
    addTearDown(runtime.dispose);
    await runtime.initialize();
    runtime.reconnect?.cancel();
    await runtime.refreshConversations();
    expect(runtime.authenticated, isTrue);
    return runtime;
  }

  Future<void> serve(HttpRequest request) async {
    // Opening a conversation reports its read position. That receipt is not a
    // message post, so it must not inflate `posts` or fail these fixtures.
    final isAck = request.method == 'POST' && request.uri.path.endsWith('/ack');
    if (isAck) {
      try {
        await request.drain<void>();
      } catch (_) {
        // Fire-and-forget: a test may dispose while a receipt is in flight.
        return;
      }
      return fixture.reply(request, {'acknowledgedSeq': 0});
    }
    await request.drain<void>();
    if (request.method != 'GET') {
      posts++;
      return fixture.reply(request, {'error': 'not_found'}, status: 404);
    }
    switch (request.uri.path) {
      case Routes.hostInfo:
        return fixture.reply(request, {'error': 'forbidden'}, status: 403);
      case Routes.conversations:
        return fixture.reply(request, {
          'conversations': [
            {'id': _joined, 'name': 'A Joined', 'historyVisibility': 'joined'},
            {'id': _ordinary, 'name': 'B Ordinary', 'historyVisibility': 'all'},
          ],
        });
      case Routes.directConversations:
        return fixture.reply(request, {'conversations': []});
      case '/api/v1/conversations/$_joined/sync':
        final cursor = int.parse(request.uri.queryParameters['afterSeq']!);
        requests.add((_joined, cursor));
        final page = await joinedPage(cursor);
        if (page is String) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(page);
          return request.response.close();
        }
        return fixture.reply(request, page as Map<String, Object?>);
      case '/api/v1/conversations/$_ordinary/sync':
        final cursor = int.parse(request.uri.queryParameters['afterSeq']!);
        requests.add((_ordinary, cursor));
        return fixture.reply(
          request,
          _page(cursor == 0 ? [_message(_ordinary, 1)] : []),
        );
      default:
        return fixture.reply(request, {'error': 'not_found'}, status: 404);
    }
  }
}
