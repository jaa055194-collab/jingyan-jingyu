import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'runtime_auth_test.dart' show Fixture, channel;

const _read = 'read-conversation';
const _other = 'other-conversation';

/// A conversation with cached canonical messages 1..head, an explicit outbox row
/// and a dropped row, so unread counting can be shown to ignore both.
class _UnreadHost {
  _UnreadHost(this.fixture);
  final Fixture fixture;

  /// Canonical messages per conversation.
  final history = <String, List<Map<String, Object?>>>{};

  /// Host-confirmed history floor per conversation, for joined-late members.
  final floor = <String, int>{};
  final acks = <(String, int)>[];
  final ackPaths = <String>[];
  Completer<void>? ackGate;
  int ackStatus = 200;
  int ackCalls = 0;

  static Future<_UnreadHost> start() async {
    final fixture = await Fixture.create();
    addTearDown(() async {
      // The local mark runs behind the selection, so let any in-flight snapshot
      // write finish before the temporary data directory is removed.
      await _settle();
      try {
        await fixture.cleanup();
      } catch (_) {
        // A still-locked temp file is a harness artifact, not a product signal.
      }
    });
    fixture.secure = jsonEncode(fixture.session());
    final host = _UnreadHost(fixture);
    fixture.serve = host.serve;
    return host;
  }

  void seed(String conversationId, int count) {
    history[conversationId] = [
      for (var seq = 1; seq <= count; seq++)
        {
          'conversationId': conversationId,
          'seq': seq,
          'messageId': '$conversationId-$seq',
          'senderId': 'friend',
          'kind': 'text',
          'body': {'text': 'Synthetic $conversationId $seq'},
          'sentAt': '2026-11-20T00:00:00Z',
        },
    ];
  }

  Future<ClientRuntime> open() async {
    final runtime = ClientRuntime();
    addTearDown(runtime.dispose);
    await runtime.initialize();
    runtime.reconnect?.cancel();
    await runtime.refreshConversations();
    expect(runtime.authenticated, isTrue);
    expect(runtime.online, isTrue);
    return runtime;
  }

  Future<void> serve(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final path = request.uri.path;
    if (request.method == 'POST' && path.endsWith('/ack')) {
      ackCalls++;
      ackPaths.add(path);
      final gate = ackGate;
      if (gate != null) await gate.future;
      if (ackStatus != 200) {
        return fixture.reply(request, {
          'error': 'unavailable',
        }, status: ackStatus);
      }
      final seq = (jsonDecode(body) as Map)['seq'] as int;
      acks.add((path.split('/')[4], seq));
      return fixture.reply(request, {'acknowledgedSeq': seq});
    }
    if (request.method == 'GET' && path == Routes.hostInfo) {
      return fixture.reply(request, {'error': 'forbidden'}, status: 403);
    }
    if (request.method == 'GET' && path == Routes.conversations) {
      return fixture.reply(request, {
        'conversations': [
          for (final id in [
            ...{_read, _other, ...history.keys},
          ])
            {
              'id': id,
              'name': id,
              'kind': 'group',
              'ownerAccountId': 'alice',
              if (floor[id] != null) 'historyVisibility': 'joined',
            },
        ],
      });
    }
    if (request.method == 'GET' && path == Routes.directConversations) {
      return fixture.reply(request, {'conversations': []});
    }
    if (request.method == 'GET' && path.endsWith('/sync')) {
      final id = path.split('/')[4];
      final after = int.parse(request.uri.queryParameters['afterSeq']!);
      final visible = floor[id] ?? 1;
      final start = after + 1 > visible ? after + 1 : visible;
      return fixture.reply(request, {
        'messages': (history[id] ?? const [])
            .where((row) => (row['seq'] as int) >= start)
            .toList(),
        'hasMore': false,
        if (floor[id] != null) 'firstVisibleSeq': floor[id],
      });
    }
    if (request.method == 'POST' && path.endsWith('/messages')) {
      return fixture.reply(request, {'error': 'not_found'}, status: 404);
    }
    return fixture.reply(request, {'error': 'not_found'}, status: 404);
  }
}

int unreadOf(ClientRuntime runtime, String id) =>
    runtime.conversations.firstWhere((entry) => entry.id == id).unread;

/// A snapshot store that succeeds while [fail] is false and then rejects every
/// write, used to prove no ack is sent when the local read position cannot be
/// made durable.
class _TogglePersistence implements ClientPersistence {
  bool fail = false;
  Map<String, Object?>? _data;
  @override
  Future<Map<String, Object?>> read() async => {...?_data};
  @override
  Future<void> write(Map<String, Object?> snapshot) async {
    if (fail) throw const FileSystemException('synthetic checkpoint failure');
    _data = Map<String, Object?>.from(snapshot);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'unread counts cached canonical messages above the read position',
    () async {
      final host = await _UnreadHost.start();
      host.seed(_read, 4);
      host.seed(_other, 2);
      final runtime = await host.open();

      // Nothing has been opened yet: every cached message is unread, because an
      // absent read position is 0 rather than "everything read".
      expect(unreadOf(runtime, _read), 4);
      expect(unreadOf(runtime, _other), 2);

      await runtime.selectConversation(_read);
      await _settle();
      expect(unreadOf(runtime, _read), 0);
      expect(unreadOf(runtime, _other), 2);

      // A new canonical message arrives for the already-read conversation.
      host.history[_read]!.add({
        'conversationId': _read,
        'seq': 5,
        'messageId': '$_read-5',
        'senderId': 'friend',
        'kind': 'text',
        'body': {'text': 'Synthetic late message'},
        'sentAt': '2026-11-20T00:00:00Z',
      });
      await runtime.refreshConversations();
      await _settle();
      expect(unreadOf(runtime, _read), 1);
      expect(unreadOf(runtime, _other), 2);
    },
  );

  test('outbox and dropped rows never count as unread', () async {
    final host = await _UnreadHost.start();
    host.seed(_read, 2);
    final runtime = await host.open();
    await runtime.selectConversation(_read);
    await _settle();
    expect(unreadOf(runtime, _read), 0);

    await runtime.shell.enqueue(_read, MessageKind.text, {'text': 'queued'});
    await runtime.shell.enqueue(_other, MessageKind.text, {'text': 'queued'});
    expect(runtime.queuedCount, 2);
    expect(unreadOf(runtime, _read), 0);
    expect(unreadOf(runtime, _other), 0);
  });

  test(
    'a conversation with no cached messages reports 0 without a guess',
    () async {
      final host = await _UnreadHost.start();
      host.seed(_read, 3);
      final runtime = await host.open();
      expect(unreadOf(runtime, _other), 0);
      expect(unreadOf(runtime, _read), 3);
      expect(
        runtime.conversations.map((entry) => entry.unread).toList()..sort(),
        [0, 3],
      );
    },
  );

  test(
    'opening a conversation sends exactly one ack for its visible head',
    () async {
      final host = await _UnreadHost.start();
      host.seed(_read, 3);
      final runtime = await host.open();
      expect(host.ackCalls, 0);

      await runtime.selectConversation(_read);
      await _settle();
      expect(host.ackCalls, 1);
      expect(host.acks, [(_read, 3)]);
      expect(host.ackPaths.single, '/api/v1/conversations/$_read/ack');
      expect(runtime.shell.readSeqFor(_read), 3);
      expect(runtime.error, isNull);

      // Re-opening the same conversation has nothing new to report.
      await runtime.selectConversation(_read);
      await _settle();
      expect(host.ackCalls, 1);
    },
  );

  test('the ack never reports past the head this device has synced', () async {
    final host = await _UnreadHost.start();
    host.seed(_read, 2);
    final runtime = await host.open();
    await runtime.selectConversation(_read);
    await _settle();
    expect(host.acks.single, (_read, 2));
  });

  test('a failed ack is silent and never retried or blocking', () async {
    final host = await _UnreadHost.start();
    host.seed(_read, 3);
    host.ackStatus = 503;
    final runtime = await host.open();

    await runtime.selectConversation(_read);
    await _settle();
    expect(host.ackCalls, 1);
    expect(runtime.error, isNull);
    // The local read position still advanced: reading is never blocked by a
    // failed report, and the badge clears.
    expect(runtime.shell.readSeqFor(_read), 3);
    expect(unreadOf(runtime, _read), 0);
    expect(runtime.messages, hasLength(3));

    await runtime.selectConversation(_other);
    await runtime.selectConversation(_read);
    await _settle();
    expect(host.ackCalls, 1, reason: 'no retry loop for the same position');
  });

  test('a lock before the ack completes discards the report', () async {
    final host = await _UnreadHost.start();
    host.seed(_read, 3);
    final runtime = await host.open();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'unlockPin':
            case 'configurePin':
              return true;
            case 'initialize':
              return <String, Object?>{};
            case 'getDataDirectory':
              return host.fixture.root.path;
            case 'readSession':
              return host.fixture.secure;
            case 'hasPin':
              return false;
            case 'storeSession':
              host.fixture.secure =
                  (call.arguments as Map<Object?, Object?>)['json'] as String;
              return null;
            default:
              return null;
          }
        });
    await runtime.setAppLock(true, '1234');
    expect(runtime.appLockEnabled, isTrue);
    host.ackGate = Completer<void>();

    await runtime.selectConversation(_read);
    await _waitFor(() => host.ackCalls == 1);
    runtime.appLock.lock();
    await _nativeLock();
    expect(runtime.locked, isTrue);
    host.ackGate!.complete();
    await _settle();

    // The report completed after the lock: it must stay silent and must not be
    // replayed once the user unlocks again.
    expect(runtime.error, isNull);
    expect(runtime.shell.readSeqFor(_read), 3);
    await runtime.unlock('1234');
    await _settle();
    await runtime.selectConversation(_read);
    await _settle();
    expect(host.ackCalls, 1, reason: 'a locked report is not retried');
  });

  test(
    'a conversation switch before the ack completes discards the report',
    () async {
      final host = await _UnreadHost.start();
      host.seed(_read, 3);
      host.seed(_other, 1);
      final runtime = await host.open();
      host.ackGate = Completer<void>();

      await runtime.selectConversation(_read);
      await _waitFor(() => host.ackCalls == 1);
      await runtime.selectConversation(_other);
      host.ackGate!.complete();
      await _settle();
      expect(runtime.error, isNull);
      // The switch reported its own head; the first report is neither replayed nor
      // rewritten to the newer conversation.
      expect(host.acks, [(_read, 3), (_other, 1)]);
      expect(runtime.shell.readSeqFor(_read), 3);
      expect(runtime.shell.readSeqFor(_other), 1);
    },
  );

  test('offline selection marks locally but sends no ack', () async {
    final host = await _UnreadHost.start();
    host.seed(_read, 3);
    final runtime = await host.open();
    host.fixture.serve = (request) async {
      await request.drain<void>();
      await host.fixture.reply(request, {'error': 'unavailable'}, status: 503);
    };
    await runtime.refreshConversations();
    expect(runtime.online, isFalse);

    await runtime.selectConversation(_read);
    await _settle();
    expect(host.ackCalls, 0);
    expect(runtime.shell.readSeqFor(_read), 3);
    expect(unreadOf(runtime, _read), 0);
  });

  test(
    'the read position survives a restart and suppresses a repeat ack',
    () async {
      final host = await _UnreadHost.start();
      host.seed(_read, 2);
      final first = await host.open();
      await first.selectConversation(_read);
      await _settle();
      expect(host.ackCalls, 1);
      first.dispose();

      final restored = await host.open();
      expect(restored.shell.readSeqFor(_read), 2);
      expect(unreadOf(restored, _read), 0);
      await restored.selectConversation(_read);
      await _settle();
      expect(host.ackCalls, 1, reason: 'nothing new to report after restart');
    },
  );

  test('a failed local mark sends no ack and keeps the badge', () async {
    final host = await _UnreadHost.start();
    host.seed(_read, 3);
    final runtime = await host.open();
    // Replace the shell with one whose snapshot writer starts failing after the
    // cache is seeded, so the read position can never be checkpointed.
    final store = _TogglePersistence();
    final guarded = ClientShellController(
      persistence: store,
      submit: (_) async =>
          const Err(Failure(FailureCode.unavailable, 'offline')),
      requestSync: (_) async {},
    );
    await guarded.initialize();
    await guarded.acceptMessage(
      MessageEventFrame(
        id: 'seeded-1',
        at: DateTime.utc(2026),
        conversationId: _read,
        seq: 1,
        messageId: '$_read-1',
        senderId: 'friend',
        kind: MessageKind.text,
        body: const {'text': 'Synthetic message'},
        sentAt: DateTime.utc(2026),
      ),
    );
    runtime.shell = guarded;
    store.fail = true;
    expect(runtime.shell.readSeqFor(_read), 0);
    final unreadBefore = unreadOf(runtime, _read);
    expect(unreadBefore, 1);

    await runtime.selectConversation(_read);
    await _settle();
    expect(runtime.error, isNull);
    expect(host.ackCalls, 0, reason: 'no report without a durable local mark');
    expect(runtime.shell.readSeqFor(_read), 0);
    expect(unreadOf(runtime, _read), unreadBefore, reason: 'badge is kept');
  });

  test('messages below the host history floor never count as unread', () async {
    // A joined-late member sees only the suffix from `firstVisibleSeq`. The
    // shell prunes its cache to that floor, so the badge counts only messages
    // the member may actually read rather than the raw seq gap.
    const joined = 'joined-conversation';
    final host = await _UnreadHost.start();
    host.seed(joined, 3);
    host.floor[joined] = 3;
    final runtime = await host.open();

    expect(unreadOf(runtime, joined), 1);
    expect(runtime.shell.lastSeqFor(joined), 3);
    expect(runtime.shell.messagesFor(joined).map((m) => m.seq), [3]);
  });

  test('no ack is sent for a conversation the user never selected', () async {
    final host = await _UnreadHost.start();
    host.seed(_read, 3);
    host.seed(_other, 1);
    final runtime = await host.open();
    await runtime.refreshConversations();
    await _settle();
    expect(host.ackCalls, 0);
    expect(runtime.shell.readSeqFor(_read), 0);
    expect(runtime.shell.readSeqFor(_other), 0);
  });
}

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 250; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('condition was not met');
}

Future<void> _nativeLock() async {
  const codec = StandardMethodCodec();
  final done = Completer<void>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(const MethodCall('event', {'type': 'lock'})),
        (_) => done.complete(),
      );
  await done.future;
}
