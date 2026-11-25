import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/net/friends_api.dart';
import 'package:client_flutter/platform/native_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

const _enabled = bool.fromEnvironment('JINGYU_RUN_DUAL_CHAT_INTEGRATION');
const _changeRetryId = bool.fromEnvironment('JINGYU_DUAL_CHAT_CHANGE_RETRY_ID');
const _text = 'Synthetic message queued while offline';

void main() {
  if (_enabled) TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'an offline send survives reopen and a lost HTTP acknowledgement without a duplicate row',
    () => HttpOverrides.runWithHttpOverrides(_verifyDualChat, _LoopbackHttp()),
    skip: _enabled ? false : 'opt in with JINGYU_RUN_DUAL_CHAT_INTEGRATION',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

// Plain async, with production HttpClient instead of the Flutter binding's
// synthetic 400s. Scope the override to this test and fail closed off loopback.
class _LoopbackHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..findProxy = (uri) {
          if (uri.scheme != 'http' || uri.host != '127.0.0.1') {
            throw StateError('Dual-chat integration requires IPv4 loopback');
          }
          return 'DIRECT';
        };
}

Future<void> _verifyDualChat() async {
  final scratch = await Directory.systemTemp.createTemp('jingyu-dual-chat-');
  addTearDown(() => scratch.delete(recursive: true));
  final hostDir = Directory('${scratch.path}/host');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  addTearDown(
    () => messenger.setMockMethodCallHandler(NativePlatform.channel, null),
  );
  final senderState = _LocalClient('${scratch.path}/sender');
  final recipientState = _LocalClient('${scratch.path}/recipient');
  final random = Random.secure();
  String password() =>
      base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
  final senderPassword = password();
  final recipientPassword = password();
  final firstHost = await _HostProcess.start(hostDir, password: senderPassword);
  final senderId = firstHost.owner!;
  final sender = await senderState.open();
  await _login(sender, firstHost.origin, senderId, senderPassword, 'Sender');
  final created = await sender.connection!.request(
    'POST',
    Routes.adminAccounts,
    body: {'displayName': 'Synthetic recipient', 'password': recipientPassword},
  );
  final recipientId = created['accountId'] as String;
  expect(recipientId, isNot(senderId));
  final recipient = await recipientState.open();
  await _login(
    recipient,
    firstHost.origin,
    recipientId,
    recipientPassword,
    'Recipient',
  );
  final senderSnapshot = sender.storage.file.path;
  expect(recipient.storage.file.path, isNot(senderSnapshot));
  await sender.connection!.request(
    'POST',
    Routes.friendRequest.replaceFirst('{accountId}', recipientId),
    allowEmptySuccess: true,
  );
  await FriendsApi(recipient.connection!).acceptFriend(senderId);
  final direct = await sender.connection!.request(
    'POST',
    Routes.directConversations,
    body: {'accountId': recipientId},
  );
  final conversation = direct['id'] as String;
  final syncPath = Routes.sync.replaceFirst('{conversationId}', conversation);
  for (final client in [sender, recipient]) {
    await client.refreshConversations();
    expect(client.conversations.single.id, conversation);
    expect(client.conversations.single.kind, 'direct');
    await client.selectConversation(conversation);
    expect(client.messages, isEmpty);
  }

  // A real listener shutdown, not a flag on either runtime.
  expect(
    await firstHost.stop(),
    isEmpty,
    reason: 'setup did not submit any message',
  );
  await sender.refreshConversations();
  expect(sender.online, isFalse);
  sender.updateDraft(_text);
  expect(sender.queuedCount, 0, reason: 'drafting does not send');
  await sender.sendMessage();
  expect(sender.error, isNull);
  expect(sender.draft, isEmpty);
  final queued = sender.shell.outbox.items.single;
  final clientMsgId = queued.clientMsgId;
  expect(queued.attempts, 0);
  expect(queued.body, {'text': _text});
  sender.dispose();

  final reopened = await senderState
      .open(); // Same saved session and disk root.
  expect(reopened.connectedAccountId, senderId);
  expect(reopened.storage.file.path, senderSnapshot);
  expect(reopened.online, isFalse);
  await reopened.selectConversation(conversation);
  expect(
    reopened.draft,
    isEmpty,
    reason: 'the consumed draft did not come back',
  );
  final restored = reopened.shell.outbox.items.single;
  expect(
    (restored.clientMsgId, restored.conversationId, restored.attempts),
    (clientMsgId, conversation, 0),
  );
  expect(restored.body, {'text': _text});

  // The actual message handler commits. The fixture drops just its first
  // response, so the sender must keep the still-uncertain outbox entry.
  final firstDelivery = await _HostProcess.start(
    hostDir,
    port: firstHost.port,
    mode: 'drop-ack',
  );
  await reopened.refreshConversations();
  expect(reopened.error, isNull);
  expect(
    reopened.queuedCount,
    1,
    reason: 'no HTTP acknowledgement was received',
  );
  expect(reopened.shell.outbox.items.single.clientMsgId, clientMsgId);
  expect(reopened.shell.outbox.items.single.attempts, 1);
  expect(reopened.shell.dropped, isEmpty);

  await recipient.refreshConversations();
  expect(recipient.online, isTrue);
  final received = recipient.shell.messagesFor(conversation).single;
  expect(received.seq, 1);
  expect(received.senderId, senderId);
  expect(received.body, {'text': _text});
  final canonicalId = received.messageId;
  expect(recipient.messages.map((m) => (m.id, m.text)), [(canonicalId, _text)]);
  expect(await firstDelivery.stop(), [
    _submission(
      conversation,
      clientMsgId,
      canonicalId,
      duplicate: false,
      lost: true,
    ),
  ]);

  // Reopen the same SQLite files again before retry: no in-memory host fixture
  // can make the second request appear idempotent, or hide an extra row.
  final reconnected = await _HostProcess.start(
    hostDir,
    port: firstHost.port,
    mode: _changeRetryId ? 'change-retry-id' : 'normal',
  );
  await reopened.refreshConversations();
  expect(reopened.online, isTrue);
  expect(reopened.queuedCount, 0);
  expect(reopened.shell.dropped, isEmpty);
  final history = await recipient.connection!.request(
    'GET',
    syncPath,
    query: {'afterSeq': '0'},
  );
  expect(history['hasMore'], isFalse);
  final persisted = (history['messages'] as List).cast<Map<String, Object?>>();
  expect(
    persisted.map((row) => row['seq']),
    [1],
    reason:
        'the reopened SQLite host must contain one canonical row after retry',
  );
  final row = persisted.single;
  expect(row['messageId'], canonicalId);
  expect(row['senderId'], senderId);
  expect(row['body'], {'text': _text});
  for (final client in [reopened, recipient]) {
    await client.refreshConversations();
    expect(client.online, isTrue);
    expect(client.queuedCount, 0);
    expect(client.shell.lastSeqFor(conversation), 1);
    expect(client.messages.map((m) => (m.id, m.text)), [(canonicalId, _text)]);
  }
  expect(await reconnected.stop(), [
    _submission(
      conversation,
      clientMsgId,
      canonicalId,
      duplicate: true,
      lost: false,
    ),
  ]);
}

Map<String, Object?> _submission(
  String conversation,
  String clientMsgId,
  String canonicalId, {
  required bool duplicate,
  required bool lost,
}) => {
  'event': 'message',
  'path': Routes.messages.replaceFirst('{conversationId}', conversation),
  'clientMsgId': clientMsgId,
  'messageId': canonicalId,
  'seq': 1,
  'duplicate': duplicate,
  'status': 200,
  'lost': lost,
};

Future<void> _login(
  ClientRuntime runtime,
  String origin,
  String account,
  String password,
  String device,
) async {
  expect(runtime.authenticated, isFalse);
  await runtime.connectHost(
    origin,
    '',
    accountId: account,
    password: password,
    deviceName: device,
  );
  expect(runtime.error, isNull);
  expect(runtime.connectedAccountId, account);
  expect(runtime.online, isTrue);
}

class _LocalClient {
  _LocalClient(this.root);
  final String root;
  String? _session;

  Future<ClientRuntime> open() async {
    // Startup/login/restore run serially. Each logical client owns its stubbed
    // session and real on-disk snapshot; no platform credential store is used.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativePlatform.channel, (call) async {
          switch (call.method) {
            case 'initialize':
              return {'platform': 'windows'};
            case 'getDataDirectory':
              return root;
            case 'readSession':
              return _session;
            case 'storeSession':
              _session = (call.arguments as Map)['json'] as String;
              return null;
            case 'hasPin':
              return false;
            default:
              throw StateError('Unexpected platform call: ${call.method}');
          }
        });
    final runtime = ClientRuntime();
    addTearDown(runtime.dispose);
    await runtime.initialize();
    runtime.reconnect?.cancel();
    await runtime.refreshConversations(); // Join the restored startup flight.
    expect(runtime.error, isNull);
    return runtime;
  }
}

class _HostProcess {
  _HostProcess(
    this._process,
    this.port,
    this.owner,
    this._trace,
    this._stdoutDone,
  );
  final Process _process;
  final int port;
  final String? owner;
  final List<Map<String, Object?>> _trace;
  final Future<void> _stdoutDone;
  Future<List<Map<String, Object?>>>? _stopping;
  String get origin => 'http://127.0.0.1:$port';

  static Future<_HostProcess> start(
    Directory data, {
    int port = 0,
    String? password,
    String mode = 'normal',
  }) async {
    final sdk = Platform.environment['JINGYU_TEST_DART'];
    if (sdk == null || !File(sdk).isAbsolute || !File(sdk).existsSync()) {
      throw StateError(
        'Set JINGYU_TEST_DART to the absolute Dart SDK executable',
      );
    }
    final host = Directory('../host').absolute;
    if (!File('${host.path}/.dart_tool/package_config.json').existsSync()) {
      throw StateError(
        'Run dart pub get --offline in apps/host before opting in',
      );
    }
    final process = await Process.start(
      sdk,
      [
        'test/support/dual_chat_integration_fixture.dart',
        data.path,
        '$port',
        mode,
      ],
      workingDirectory: host.path,
      environment: {'SystemRoot': ?Platform.environment['SystemRoot']},
      includeParentEnvironment: false,
    );
    final ready = Completer<Map<String, Object?>>();
    final trace = <Map<String, Object?>>[];
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
          final event = (jsonDecode(line) as Map).cast<String, Object?>();
          if (event['event'] == 'ready') {
            ready.complete(event);
          } else {
            trace.add(event);
          }
        });
    stdoutDone.ignore();
    process.stderr
        .drain<void>()
        .ignore(); // No raw subprocess diagnostics in test output.
    try {
      process.stdin.writeln(jsonEncode({'password': ?password}));
      await process.stdin.flush().timeout(const Duration(seconds: 10));
      final event = await Future.any([
        ready.future,
        stdoutDone.then<Map<String, Object?>>((_) async {
          throw StateError(
            'Dual-chat fixture exited before ready (${await process.exitCode})',
          );
        }),
      ]).timeout(const Duration(seconds: 60));
      final child = _HostProcess(
        process,
        event['port'] as int,
        event['owner'] as String?,
        trace,
        stdoutDone,
      );
      addTearDown(child.stop);
      return child;
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 5));
      rethrow;
    }
  }

  Future<List<Map<String, Object?>>> stop() => _stopping ??= _stop();

  Future<List<Map<String, Object?>>> _stop() async {
    try {
      _process.stdin.writeln('stop');
      await _process.stdin.close().timeout(const Duration(seconds: 10));
      expect(
        await _process.exitCode.timeout(const Duration(seconds: 15)),
        0,
        reason: 'listener and SQLite shut down cleanly',
      );
      await _stdoutDone.timeout(const Duration(seconds: 5));
      return List.unmodifiable(_trace);
    } catch (_) {
      _process.kill(ProcessSignal.sigkill);
      await _process.exitCode.timeout(const Duration(seconds: 5));
      rethrow;
    }
  }
}
