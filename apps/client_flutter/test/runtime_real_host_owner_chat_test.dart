import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/net/ai_config_write_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/platform/native_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

const _prompt = '为什么这样？请解释原因。';
const _reply = 'synthetic worker reply';
const _enabled = bool.fromEnvironment('JINGYU_RUN_OWNER_CHAT_INTEGRATION');
const _rejectReply = bool.fromEnvironment('JINGYU_OWNER_CHAT_REJECT_REPLY');

void main() {
  if (_enabled) TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'owner signs in, sends once and reads the same S2 reply after reconnect',
    () => HttpOverrides.runWithHttpOverrides(_verifyOwnerChat, _LoopbackHttp()),
    skip: _enabled ? false : 'opt in with JINGYU_RUN_OWNER_CHAT_INTEGRATION',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

// Plain async test with the production HttpClient. Flutter's test binding
// otherwise installs a client that returns synthetic HTTP 400 responses.
class _LoopbackHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..findProxy = (uri) {
          if (uri.scheme != 'http' || uri.host != '127.0.0.1') {
            throw StateError(
              'Owner-chat integration only talks to IPv4 loopback',
            );
          }
          return 'DIRECT';
        };
}

Future<void> _verifyOwnerChat() async {
  final scratch = await Directory.systemTemp.createTemp('jingyu-owner-chat-');
  addTearDown(() => scratch.delete(recursive: true));
  final hostDir = Directory('${scratch.path}/host');
  final random = Random.secure();
  final password = base64UrlEncode(
    List.generate(24, (_) => random.nextInt(256)),
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  String? session;
  messenger.setMockMethodCallHandler(NativePlatform.channel, (call) async {
    switch (call.method) {
      case 'initialize':
        return {'platform': 'windows'};
      case 'getDataDirectory':
        return '${scratch.path}/client';
      case 'readSession':
        return session;
      case 'hasPin':
        return false;
      case 'storeSession':
        session = (call.arguments as Map)['json'] as String;
        return null;
      case 'clearSession':
        session = null;
        return null;
      default:
        throw StateError('Unexpected platform call: ${call.method}');
    }
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(NativePlatform.channel, null),
  );

  final firstHost = await _HostProcess.start(hostDir, password: password);
  addTearDown(firstHost.stop);
  final owner = firstHost.owner!;
  final first = ClientRuntime();
  addTearDown(first.dispose);
  await _initialize(first);
  expect(first.authenticated, isFalse);
  expect(session, isNull);
  await first.connectHost(
    firstHost.origin,
    '',
    accountId: owner,
    password: password,
    deviceName: 'Synthetic desktop client',
  );
  expect(first.error, isNull, reason: 'password login against the listener');
  expect(first.connectedAccountId, owner);
  expect(first.online, isTrue);
  expect(
    session != null,
    isTrue,
    reason: 'login stored a session via the channel',
  );
  await first.enterChat();
  expect(first.chatEntered, isTrue);

  final (ai, conversation) = await _configureOwnerChat(first);
  final syncPath = Routes.sync.replaceFirst('{conversationId}', conversation);
  final sendPath = Routes.messages.replaceFirst(
    '{conversationId}',
    conversation,
  );
  await first.refreshConversations();
  expect(await first.checkOwnAiChatEntry(ai), OwnAiChatEntry.ready);
  expect(first.conversations.single.id, conversation);
  await first.selectConversation(conversation);
  expect(first.messages, isEmpty);
  first.updateDraft(_prompt);
  expect(first.draft, _prompt);
  expect(first.queuedCount, 0, reason: 'drafting does not queue a send');
  await first.sendMessage();
  expect(first.error, isNull);
  expect(first.queuedCount, 0, reason: 'the host accepted the explicit send');
  await first.refreshConversations();

  final rows = first.shell.messagesFor(conversation);
  expect(
    rows.map((row) => (row.seq, row.senderId, row.body['text'])),
    [(1, owner, _prompt), (2, ai, _reply)],
    reason:
        'sync must deliver the one owner message and one canonical S2 reply',
  );
  expect(rows.last.body['source'], 's2');
  final ids = rows.map((row) => row.messageId).toList();
  expect(ids.toSet(), hasLength(2));
  expect(first.messages.map((row) => (row.id, row.text)), [
    (ids.first, _prompt),
    (ids.last, _reply),
  ]);
  expect(first.shell.lastSeqFor(conversation), 2);
  final statusPath = Routes.ownerAiReplyStatus
      .replaceFirst('{conversationId}', conversation)
      .replaceFirst('{messageId}', ids.first);
  await _verifyReplyStatus(first.connection!, statusPath, ids);

  await firstHost.stop();
  expect(firstHost.requests('POST', Routes.authLogin), [200]);
  expect(firstHost.requests('POST', sendPath), [200]);
  expect(firstHost.syncPages(syncPath), [(0, 0), (0, 2)]);
  await first.refreshConversations();
  expect(first.online, isFalse, reason: 'the listener is no longer serving');
  expect(first.messages.map((row) => row.id), ids);
  first.dispose();

  final restarted = await _HostProcess.start(hostDir, port: firstHost.port);
  addTearDown(restarted.stop);
  final restored = ClientRuntime();
  addTearDown(restored.dispose);
  await _initialize(restored);
  expect(restored.error, isNull);
  expect(restored.connectedAccountId, owner);
  expect(restored.chatEntered, isTrue);
  expect(restored.online, isTrue);
  expect(restored.shell.lastSeqFor(conversation), 2);
  expect(restored.queuedCount, 0);
  await restored.selectConversation(conversation);
  expect(restored.messages.map((row) => (row.id, row.text)), [
    (ids.first, _prompt),
    (ids.last, _reply),
  ]);

  // An independent read from the reopened SQLite host proves that the cache
  // did not manufacture the reply or hide another stored message.
  final transport = restored.connection!;
  final history = await transport.request(
    'GET',
    syncPath,
    query: {'afterSeq': '0'},
  );
  final persisted = (history['messages'] as List).cast<Map<String, Object?>>();
  expect(persisted.map((row) => row['messageId']), ids);
  expect(persisted.map((row) => row['seq']), [1, 2]);
  expect(persisted.map((row) => row['senderId']), [owner, ai]);
  expect(persisted.last['body'], containsPair('source', 's2'));
  expect(persisted.last['body'], containsPair('text', _reply));
  await _verifyReplyStatus(transport, statusPath, ids);
  await restored.refreshConversations();
  expect(restored.messages.map((row) => row.id), ids);
  restored.dispose();
  await restarted.stop();
  expect(restarted.syncPages(syncPath), [(2, 0), (0, 2), (2, 0)]);
  expect(restarted.requests('POST', sendPath), isEmpty);
  expect(restarted.requests('POST', Routes.authLogin), isEmpty);
  expect(restarted.requests('POST', Routes.authRefresh), isEmpty);
}

Future<void> _initialize(ClientRuntime runtime) async {
  await runtime.initialize();
  runtime.reconnect?.cancel(); // Drive exact refresh points, not the transport.
  await runtime
      .refreshConversations(); // Join a restored session's startup sync.
}

Future<(String, String)> _configureOwnerChat(ClientRuntime runtime) async {
  await runtime.createOwnAi('Synthetic AI');
  expect(runtime.error, isNull);
  final ai = runtime.ownAiAccounts.single.accountId;
  await runtime.loadOwnAiDirectConsent(ai);
  expect(runtime.error, isNull);
  final consent = runtime.ownAiDirectState(ai);
  expect(consent.phase, ShellOwnAiDirectPhase.ready);
  expect(consent.enabled, isFalse);
  final profile = consent.profileId!;
  final writer = AiConfigWriteApi(runtime.connection!);
  final provider = await writer.createProvider(
    name: 'Offline owner-chat fixture',
    baseUrl: 'https://192.0.2.1/v1',
    apiKey: 'offline-fixture-not-a-provider-key',
    capabilities: {'chat'},
  );
  await writer.setChatBinding(profile, providerId: provider.id, model: 'auto');
  await writer.initializePersona(
    profile,
    p0: {'name': 'Fixture'},
    p1: {'style': 'concise'},
    p2: {'mood': 'calm'},
  );
  await writer.configureBudget(
    profile,
    dailyTokens: 10000,
    offsetMinutes: 0,
    layerLimits: {
      for (final layer in BudgetLayer.values)
        layer.name: layer == BudgetLayer.b2DeepChat ? 10000 : 0,
    },
    capabilityLimits: {
      for (final capability in ProviderConfigView.knownCapabilities)
        capability: capability == 'chat' ? 10000 : 0,
    },
  );
  await runtime.setOwnAiDirectConsent(
    ai,
    profileId: profile,
    expectedRevision: consent.revision!,
    enabled: true,
    interactionContext: runtime.ownAiDirectContext!,
  );
  expect(runtime.error, isNull);
  final granted = runtime.ownAiDirectState(ai);
  expect(granted.enabled, isTrue);
  return (ai, granted.conversationId!);
}

Future<void> _verifyReplyStatus(
  HostConnection connection,
  String path,
  List<String> ids,
) async {
  final status = await connection.request('GET', path);
  expect(status['status'], 'completed');
  expect(status['sourceMessageId'], ids.first);
  expect(status['replyMessageId'], ids.last);
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
  Future<void>? _stopping;
  String get origin => 'http://127.0.0.1:$port';

  List<int> requests(String method, String path) => [
    for (final event in _trace)
      if (event['method'] == method && event['path'] == path)
        event['status'] as int,
  ];

  List<(int, int)> syncPages(String path) => [
    for (final event in _trace)
      if (event['method'] == 'GET' && event['path'] == path)
        (int.parse(event['afterSeq'] as String), event['rows'] as int),
  ];

  static Future<_HostProcess> start(
    Directory data, {
    int port = 0,
    String? password,
  }) async {
    if ((port == 0) != (password != null)) {
      throw ArgumentError('Pass a synthetic password only on first start');
    }
    final dart = Platform.environment['JINGYU_TEST_DART'];
    if (dart == null || !File(dart).isAbsolute || !File(dart).existsSync()) {
      throw StateError(
        'Set JINGYU_TEST_DART to the absolute Dart SDK executable path',
      );
    }
    final host = Directory('../host').absolute;
    if (!File('${host.path}/.dart_tool/package_config.json').existsSync()) {
      throw StateError('Run dart pub get in apps/host before opting in');
    }
    final process = await Process.start(
      dart,
      [
        'test/support/owner_chat_integration_fixture.dart',
        data.absolute.path,
        '$port',
        if (_rejectReply) 'reject-reply',
      ],
      workingDirectory: host.path,
      // Match the host's isolated worker environment on Windows.
      environment: {
        if (Platform.isWindows)
          'SystemRoot': ?Platform.environment['SystemRoot'],
      },
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
    // Install handlers immediately, and keep diagnostics free of raw output.
    stdoutDone.ignore();
    process.stderr.drain<void>().ignore();
    try {
      process.stdin.writeln(jsonEncode({'password': ?password}));
      await process.stdin.flush().timeout(const Duration(seconds: 10));
      final event = await Future.any([
        ready.future,
        stdoutDone.then<Map<String, Object?>>((_) async {
          throw StateError(
            'Host fixture exited before ready (${await process.exitCode})',
          );
        }),
      ]).timeout(const Duration(seconds: 60));
      return _HostProcess(
        process,
        event['port'] as int,
        event['owner'] as String?,
        trace,
        stdoutDone,
      );
    } catch (_) {
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 5));
      rethrow;
    }
  }

  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    try {
      _process.stdin.writeln('stop');
      await _process.stdin.close().timeout(const Duration(seconds: 10));
      final code = await _process.exitCode.timeout(const Duration(seconds: 15));
      expect(code, 0, reason: 'the listener and SQLite closed cleanly');
      await _stdoutDone.timeout(const Duration(seconds: 5));
    } catch (_) {
      _process.kill();
      await _process.exitCode.timeout(const Duration(seconds: 5));
      rethrow;
    }
  }
}
