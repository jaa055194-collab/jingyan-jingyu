import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'runtime_auth_test.dart' show Fixture;

const _read = 'read-group';
const _unread = 'unread-group';

/// The host already owns ack persistence and clamping; this test host only
/// records what the client actually sent so the client contract stays explicit.
class _Host {
  _Host(this.fixture, this.pages);
  final Fixture fixture;
  final Map<String, List<Map<String, Object?>>> pages;
  final acks = <(String, Object?)>[];
  final syncs = <(String, int)>[];
  final posts = <(String, Object?)>[];

  static Future<_Host> start(
    Map<String, List<Map<String, Object?>>> pages,
  ) async {
    final fixture = await Fixture.create();
    addTearDown(fixture.cleanup);
    fixture.secure = jsonEncode(fixture.session());
    final host = _Host(fixture, pages);
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
    final path = request.uri.path;
    if (request.method == 'POST') {
      final body = jsonDecode(await utf8.decoder.bind(request).join());
      posts.add((path, body));
      if (path.endsWith('/ack')) {
        acks.add((path, body));
        final requested = (body as Map)['seq'];
        return fixture.reply(request, {
          'acknowledgedSeq': requested is int ? requested : 0,
        });
      }
      return fixture.reply(request, {'error': 'not_found'}, status: 404);
    }
    await request.drain<void>();
    switch (path) {
      case Routes.hostInfo:
        return fixture.reply(request, {'error': 'forbidden'}, status: 403);
      case Routes.conversations:
        return fixture.reply(request, {
          'conversations': [
            {'id': _read, 'name': 'A Read'},
            {'id': _unread, 'name': 'B Unread'},
          ],
        });
      case Routes.directConversations:
        return fixture.reply(request, {'conversations': []});
      case '/api/v1/conversations/$_read/sync':
        return _sync(request, _read);
      case '/api/v1/conversations/$_unread/sync':
        return _sync(request, _unread);
      default:
        return fixture.reply(request, {'error': 'not_found'}, status: 404);
    }
  }

  Future<void> _sync(HttpRequest request, String conversation) async {
    final cursor = int.parse(request.uri.queryParameters['afterSeq']!);
    syncs.add((conversation, cursor));
    final rows = pages[conversation] ?? const <Map<String, Object?>>[];
    return fixture.reply(request, {
      'messages': [
        for (final row in rows)
          if ((row['seq']! as int) > cursor) row,
      ],
      'hasMore': false,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  /// The host receipt is deliberately fire-and-forget so it cannot delay
  /// opening a conversation; tests wait for the loopback request to land.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 150));

  test('unread counts cached messages above the read position', () async {
    final host = await _Host.start({
      _read: [_message(_read, 1), _message(_read, 2)],
      _unread: [
        _message(_unread, 1),
        _message(_unread, 2),
        _message(_unread, 3),
      ],
    });
    final runtime = await host.open();
    expect(runtime.conversations.map((c) => c.id), [_read, _unread]);
    expect(runtime.conversations.first.unread, 2);
    expect(runtime.conversations.last.unread, 3);
    expect(host.acks, isEmpty);

    await runtime.selectConversation(_read);
    await settle();
    expect(runtime.shell.readSeqFor(_read), 2);
    expect(runtime.conversations.first.unread, 0);
    expect(runtime.conversations.last.unread, 3);
    expect(host.acks, hasLength(1));
    expect(host.acks.single.$1, '/api/v1/conversations/$_read/ack');
    expect(host.acks.single.$2, {'seq': 2});
    expect(host.posts, hasLength(1));
  });

  test('opening a conversation sends exactly one visible-head ack', () async {
    final host = await _Host.start({
      _read: [_message(_read, 1), _message(_read, 2)],
      _unread: const [],
    });
    final runtime = await host.open();
    expect(runtime.conversations.first.unread, 2);

    await runtime.selectConversation(_read);
    await settle();
    expect(host.acks, hasLength(1));
    expect(host.acks.single.$1, '/api/v1/conversations/$_read/ack');
    expect(host.acks.single.$2, {'seq': 2});

    // Selecting the same conversation again is not another explicit open.
    await runtime.selectConversation(_read);
    await settle();
    expect(host.acks, hasLength(1));
    expect(runtime.conversations.first.unread, 0);
  });

  test('a message arriving after startup counts as unread', () async {
    final host = await _Host.start({
      _read: [_message(_read, 1)],
      _unread: const [],
    });
    final runtime = await host.open();
    await runtime.selectConversation(_read);
    await settle();
    expect(runtime.conversations.first.unread, 0);

    // A live row is new information; it stays unread until an explicit reopen.
    await runtime.shell.acceptMessage(
      MessageEventFrame(
        id: 'live-2',
        at: DateTime.utc(2026, 11, 20),
        conversationId: _read,
        seq: 2,
        messageId: '$_read-2',
        senderId: 'friend',
        kind: MessageKind.text,
        body: const {'text': 'live'},
        sentAt: DateTime.utc(2026, 11, 20),
      ),
    );
    expect(runtime.conversations.first.unread, 1);
    expect(runtime.shell.readSeqFor(_read), 1);
  });

  test('re-opening the same conversation sends no second ack', () async {
    final host = await _Host.start({
      _read: [_message(_read, 1)],
      _unread: const [],
    });
    final runtime = await host.open();
    await runtime.selectConversation(_read);
    await settle();
    expect(host.acks, hasLength(1));

    await runtime.selectConversation(_read);
    await runtime.selectConversation(_read);
    await settle();
    expect(host.acks, hasLength(1));
    expect(runtime.shell.readSeqFor(_read), 1);
  });

  test('empty conversation opens without inventing unread or an ack', () async {
    final host = await _Host.start({_read: const [], _unread: const []});
    final runtime = await host.open();
    expect(runtime.conversations.every((c) => c.unread == 0), isTrue);

    await runtime.selectConversation(_read);
    expect(runtime.shell.readSeqFor(_read), 0);
    expect(host.acks, isEmpty);
  });

  test(
    'ack failure is silent, not retried, and keeps reading usable',
    () async {
      final host = await _Host.start({
        _read: [_message(_read, 1)],
        _unread: const [],
      });
      final runtime = await host.open();
      var ackAttempts = 0;
      host.fixture.serve = (request) async {
        if (request.method == 'POST') {
          ackAttempts++;
          await request.drain<void>();
          return host.fixture.reply(request, {
            'error': 'unavailable',
          }, status: 503);
        }
        return host.serve(request);
      };
      await runtime.selectConversation(_read);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(ackAttempts, 1);
      expect(runtime.error, isNull);
      expect(runtime.locked, isFalse);
      expect(runtime.conversations.first.unread, 0);
      expect(runtime.shell.readSeqFor(_read), 1);

      // Reading still works after a rejected ack; nothing is retried in the
      // background, so the count stays at one attempt.
      await runtime.selectConversation(_unread);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(ackAttempts, 1);
      expect(runtime.messages, isEmpty);
    },
  );

  test(
    'lock during the in-flight ack writes nothing further and stays silent',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final host = await _Host.start({
        _read: [_message(_read, 1)],
        _unread: const [],
      });
      final runtime = await host.open();
      await runtime.setAppLock(true, '1234');
      expect(runtime.appLockEnabled, isTrue);
      expect(runtime.locked, isFalse);
      final shellFile = runtime.storage.file;
      host.fixture.serve = (request) async {
        if (request.method == 'POST') {
          if (!started.isCompleted) started.complete();
          await release.future;
          await request.drain<void>();
          return host.fixture.reply(request, {'acknowledgedSeq': 1});
        }
        return host.serve(request);
      };
      final selecting = runtime.selectConversation(_read);
      await started.future.timeout(const Duration(seconds: 5));
      final beforeLock = await shellFile.readAsString();
      // The local read position is already committed; the receipt is in flight.
      expect(runtime.shell.readSeqFor(_read), 1);
      runtime.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(runtime.locked, isTrue);
      release.complete();
      await selecting;
      expect(runtime.error, isNull);
      // No further local write after the lock.
      expect(await shellFile.readAsString(), beforeLock);
      expect(host.acks, isEmpty);
      await runtime.unlock('1234');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      // A discarded receipt is never retried after unlock.
      expect(host.acks, isEmpty);
    },
  );
}
