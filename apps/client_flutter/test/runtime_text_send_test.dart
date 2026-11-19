import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'runtime_auth_test.dart' show Fixture;

const _group = 'group';
const _text = 'Synthetic text';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('offline send restores one queued ID and no old draft', () async {
    final host = await _Host.start();
    final first = await host.open();
    await _saveDraft(first);
    host.online = false;
    await first.refreshConversations();
    expect(first.online, isFalse);
    await _useCheckpoint(first, (snapshot) async {
      if (_hasQueuedItem(snapshot) && _draftIn(snapshot, _group) == _text) {
        throw StateError('The split checkpoint would restore a stale draft');
      }
    });

    await first.sendMessage();
    expect(first.error, isNull);
    expect(first.draft, isEmpty);
    expect(host.submissions, isEmpty);
    final id = first.shell.outbox.items.single.clientMsgId;
    first.dispose();

    final restored = await host.open(online: false);
    await restored.selectConversation(_group);
    expect(restored.draft, isEmpty);
    expect(restored.shell.outbox.items.single.clientMsgId, id);
    expect(restored.shell.draftFor('other'), 'Keep this draft');
    await restored.sendMessage(); // No restored draft to send again.
    host.online = true;
    await restored.refreshConversations();
    expect(host.submissions, [id]);
    expect(restored.queuedCount, 0);
    expect(restored.messages.map((message) => message.id), ['canonical-1']);
  });

  test(
    'a failed send checkpoint retains the draft and does not enqueue',
    () async {
      final host = await _Host.start();
      final runtime = await host.open();
      await _saveDraft(runtime);
      var fail = true;
      await _useCheckpoint(runtime, (snapshot) async {
        if (fail && _hasQueuedItem(snapshot)) {
          fail = false;
          throw const FileSystemException('Injected snapshot write failure');
        }
      });

      await runtime.sendMessage();
      expect(runtime.error, isNotNull);
      expect(runtime.draft, _text);
      expect(runtime.queuedCount, 0);
      expect(_draftIn(await runtime.storage.read(), _group), _text);
      expect(host.submissions, isEmpty);
      await runtime.refreshConversations();
      expect(host.submissions, isEmpty);

      await runtime.sendMessage();
      expect(runtime.error, isNull);
      expect(runtime.draft, isEmpty);
      expect(runtime.queuedCount, 0);
      expect(host.submissions, hasLength(1));
      expect(runtime.shell.draftFor('other'), 'Keep this draft');
    },
  );

  test(
    'send requested by a draft listener does not restore sent text',
    () async {
      final host = await _Host.start();
      final runtime = await host.open();
      await runtime.selectConversation(_group);

      Future<void>? send;
      void listener() {
        if (runtime.draft != _text) return;
        runtime.removeListener(listener);
        send = runtime.sendMessage();
      }

      runtime.addListener(listener);
      runtime.updateDraft(_text);
      await send!;
      await runtime.selectConversation(_group);
      expect(runtime.draft, isEmpty);
      expect(_draftIn(await runtime.storage.read(), _group) ?? '', isEmpty);
      expect(host.submissions, hasLength(1));
    },
  );

  test(
    'identical text re-entered during checkpoint remains a new draft',
    () async {
      final host = await _Host.start();
      final runtime = await host.open();
      await _saveDraft(runtime);
      host.online = false;
      await runtime.refreshConversations();
      expect(runtime.online, isFalse);
      final started = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await _useCheckpoint(runtime, (snapshot) async {
        if (!_hasQueuedItem(snapshot) || started.isCompleted) return;
        started.complete();
        await release.future;
      });

      final send = runtime.sendMessage();
      await started.future.timeout(const Duration(seconds: 5));
      runtime.updateDraft(_text);
      release.complete();
      await send;
      await runtime.shell.saveDraft('other', 'Keep this draft');
      expect(runtime.draft, _text);
      expect(_draftIn(await runtime.storage.read(), _group), _text);
      expect(runtime.queuedCount, 1);

      await runtime.sendMessage();
      expect(runtime.draft, isEmpty);
      final ids = runtime.shell.outbox.items
          .map((item) => item.clientMsgId)
          .toList();
      expect(ids.toSet(), hasLength(2));
      expect(host.submissions, isEmpty);
      host.online = true;
      await runtime.refreshConversations();
      expect(host.submissions, ids);
    },
  );
}

Future<void> _saveDraft(ClientRuntime runtime) async {
  await runtime.selectConversation(_group);
  runtime.updateDraft(_text);
  await runtime.shell.saveDraft('other', 'Keep this draft');
}

Future<void> _useCheckpoint(
  ClientRuntime runtime,
  Future<void> Function(Map<String, Object?>) beforeWrite,
) async {
  final shell = ClientShellController(
    persistence: _Checkpoint(runtime.storage, beforeWrite),
    submit: (item) => runtime.connection!.submit(
      OutboxSubmission(item.conversationId, {
        'clientMsgId': item.clientMsgId,
        'kind': item.kind.wire,
        'body': item.body,
      }),
    ),
    requestSync: (_) async {},
  );
  await shell.initialize();
  runtime.shell = shell;
}

bool _hasQueuedItem(Map<String, Object?> snapshot) =>
    ((snapshot['shell'] as Map)['outbox'] as List).isNotEmpty;

String? _draftIn(Map<String, Object?> snapshot, String id) =>
    ((snapshot['shell'] as Map)['drafts'] as Map)[id] as String?;

class _Checkpoint implements ClientPersistence {
  _Checkpoint(this.delegate, this.beforeWrite);
  final ClientPersistence delegate;
  final Future<void> Function(Map<String, Object?>) beforeWrite;

  @override
  Future<Map<String, Object?>?> read() => delegate.read();

  @override
  Future<void> write(Map<String, Object?> snapshot) async {
    await beforeWrite(snapshot);
    await delegate.write(snapshot);
  }
}

class _Host {
  _Host(this.fixture);

  final Fixture fixture;
  bool online = true;
  final submissions = <String>[];
  final _messages = <String, Map<String, Object?>>{};

  static Future<_Host> start() async {
    final fixture = await Fixture.create();
    addTearDown(fixture.cleanup);
    final host = _Host(fixture);
    fixture.secure = jsonEncode(fixture.session());
    fixture.serve = host.serve;
    return host;
  }

  Future<ClientRuntime> open({bool online = true}) async {
    this.online = online;
    final runtime = ClientRuntime();
    addTearDown(runtime.dispose);
    await runtime.initialize();
    runtime.reconnect?.cancel();
    await runtime.refreshConversations();
    expect(runtime.authenticated, isTrue);
    expect(runtime.online, online);
    return runtime;
  }

  Future<void> serve(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    if (!online) {
      return fixture.reply(request, {'error': 'unavailable'}, status: 503);
    }
    switch ((request.method, request.uri.path)) {
      case ('GET', Routes.hostInfo):
        return fixture.reply(request, {'error': 'forbidden'}, status: 403);
      case ('GET', Routes.conversations):
        return fixture.reply(request, {
          'conversations': [
            {'id': _group, 'name': 'Group', 'ownerAccountId': 'alice'},
          ],
        });
      case ('GET', Routes.directConversations):
        return fixture.reply(request, {'conversations': []});
      case ('POST', '/api/v1/conversations/$_group/messages'):
        final message = jsonDecode(body) as Map;
        final id = message['clientMsgId'] as String;
        submissions.add(id);
        final duplicate = _messages.containsKey(id);
        final row = _messages.putIfAbsent(id, () {
          final seq = _messages.length + 1;
          return {
            'conversationId': _group,
            'messageId': 'canonical-$seq',
            'seq': seq,
            'senderId': 'alice',
            'kind': message['kind'],
            'body': message['body'],
            'sentAt': '2026-11-19T00:00:00Z',
          };
        });
        return fixture.reply(request, {'message': row, 'duplicate': duplicate});
      case ('GET', '/api/v1/conversations/$_group/sync'):
        final after = int.parse(request.uri.queryParameters['afterSeq']!);
        return fixture.reply(request, {
          'messages': _messages.values
              .where((row) => (row['seq'] as int) > after)
              .toList(),
          'hasMore': false,
        });
      default:
        return fixture.reply(request, {'error': 'not_found'}, status: 404);
    }
  }
}
