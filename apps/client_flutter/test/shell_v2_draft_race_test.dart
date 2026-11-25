import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/android_private_ai_chat_port.dart';
import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/features/chat/android_private_ai_screen.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:material_ui/material_ui.dart';

import 'runtime_auth_test.dart' show Fixture;

const _group = 'group';
const _text = 'Synthetic text';
const _typed = 'Typed while sending';
const _wait = Duration(seconds: 5);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('text send', () {
    test('typing during the flush starts a new draft', () async {
      final host = await _Host.start();
      final runtime = await host.open();
      await _saveDraft(runtime);
      final hold = host.holdSubmit = Completer<void>();
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });
      final heard = <String>[];
      runtime.addListener(() => heard.add(runtime.draft));

      final send = runtime.sendMessage();
      expect(runtime.draft, isEmpty, reason: 'the composer empties at once');
      expect(heard, contains(''), reason: 'listeners hear the empty draft');
      await host.submitted.future.timeout(_wait);
      expect(runtime.draft, isEmpty);
      runtime.updateDraft(_typed);
      hold.complete();
      await send;
      await _barrier(runtime);
      expect(runtime.error, isNull);
      expect(runtime.draft, _typed);
      expect(_draftIn(await runtime.storage.read(), _group), _typed);
      expect(host.texts, [_text]);

      await runtime.sendMessage();
      expect(runtime.error, isNull);
      expect(runtime.draft, isEmpty);
      expect(host.texts, [_text, _typed], reason: 'the old text is not resent');
    });

    test('the composer is empty while the send checkpoint runs', () async {
      final host = await _Host.start();
      final runtime = await host.open();
      await _saveDraft(runtime);
      host.online = false;
      await runtime.refreshConversations();
      expect(runtime.online, isFalse);
      final gate = _Gate();
      addTearDown(gate.open);
      await _useCheckpoint(runtime, (snapshot) async {
        if (_hasQueuedItem(snapshot)) await gate.pass();
      });

      final send = runtime.sendMessage();
      await gate.reached.future.timeout(_wait);
      expect(runtime.draft, isEmpty);
      runtime.updateDraft(_typed);
      gate.open();
      await send;
      await _barrier(runtime);
      expect(runtime.error, isNull);
      expect(runtime.draft, _typed);
      expect(_draftIn(await runtime.storage.read(), _group), _typed);
      expect(runtime.shell.outbox.items.map((item) => item.body['text']), [
        _text,
      ]);
    });

    test('a failed send checkpoint puts the sent text back', () async {
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
      final heard = <String>[];
      runtime.addListener(() => heard.add(runtime.draft));

      await runtime.sendMessage();
      expect(heard, contains(''), reason: 'the composer emptied meanwhile');
      expect(heard.last, _text);
      expect(runtime.error, isNotNull);
      expect(runtime.draft, _text);
      expect(runtime.queuedCount, 0);
      expect(_draftIn(await runtime.storage.read(), _group), _text);
      expect(host.texts, isEmpty);
    });

    test('a failed send keeps text typed while it ran', () async {
      final host = await _Host.start();
      final runtime = await host.open();
      await _saveDraft(runtime);
      final gate = _Gate();
      addTearDown(gate.open);
      await _useCheckpoint(runtime, _failOnceAt(gate));

      final send = runtime.sendMessage();
      await gate.reached.future.timeout(_wait);
      expect(runtime.draft, isEmpty);
      runtime.updateDraft(_typed);
      gate.open();
      await send;
      await _barrier(runtime);
      expect(runtime.error, isNotNull);
      expect(runtime.draft, _typed);
      expect(_draftIn(await runtime.storage.read(), _group), _typed);
      expect(runtime.queuedCount, 0);
      expect(host.texts, isEmpty);
    });

    test('a failed send restores text typed and erased meanwhile', () async {
      final host = await _Host.start();
      final runtime = await host.open();
      await _saveDraft(runtime);
      final gate = _Gate();
      addTearDown(gate.open);
      await _useCheckpoint(runtime, _failOnceAt(gate));

      final send = runtime.sendMessage();
      await gate.reached.future.timeout(_wait);
      runtime.updateDraft('x');
      runtime.updateDraft('');
      gate.open();
      await send;
      await _barrier(runtime);
      expect(runtime.error, isNotNull);
      expect(runtime.draft, _text);
      expect(_draftIn(await runtime.storage.read(), _group), _text);
      expect(runtime.queuedCount, 0);
    });
  });

  group('mention send', () {
    test('typing during the mention flush starts a new draft', () async {
      final host = await _Host.start();
      final runtime = await host.open();
      await _saveDraft(runtime);
      final hold = host.holdSubmit = Completer<void>();
      addTearDown(() {
        if (!hold.isCompleted) hold.complete();
      });

      final send = _mention(runtime);
      expect(runtime.draft, isEmpty, reason: 'the composer empties at once');
      await host.submitted.future.timeout(_wait);
      runtime.updateDraft(_typed);
      hold.complete();
      await send;
      await _barrier(runtime);
      expect(runtime.error, isNull);
      expect(runtime.draft, _typed);
      expect(_draftIn(await runtime.storage.read(), _group), _typed);
      expect(host.texts, [_text]);
    });

    test('a mention that cannot be saved puts its text back', () async {
      final host = await _Host.start();
      final runtime = await host.open();
      await _saveDraft(runtime);
      final gate = _Gate();
      addTearDown(gate.open);
      await _useCheckpoint(runtime, _failOnceAt(gate));

      final send = _mention(runtime);
      await gate.reached.future.timeout(_wait);
      expect(runtime.draft, isEmpty);
      gate.open();
      await send;
      expect(runtime.error, contains('仍保留待发送'));
      expect(runtime.draft, _text);
      expect(host.texts, isEmpty);
    });

    test('a mention that fails keeps text typed while it ran', () async {
      final host = await _Host.start();
      final runtime = await host.open();
      await _saveDraft(runtime);
      final gate = _Gate();
      addTearDown(gate.open);
      await _useCheckpoint(runtime, _failOnceAt(gate));

      final send = _mention(runtime);
      await gate.reached.future.timeout(_wait);
      expect(runtime.draft, isEmpty);
      runtime.updateDraft(_typed);
      gate.open();
      await send;
      await _barrier(runtime);
      expect(runtime.error, contains('仍保留待发送'));
      expect(runtime.draft, _typed);
      expect(_draftIn(await runtime.storage.read(), _group), _typed);
      expect(host.texts, isEmpty);
    });

    test(
      'a failed mention draft clear puts the text back for one retry',
      () async {
        final host = await _Host.start();
        final runtime = await host.open();
        await _saveDraft(runtime);
        final gate = _Gate();
        addTearDown(gate.open);
        await _useCheckpoint(runtime, (snapshot) async {
          if (!_hasQueuedItem(snapshot) ||
              _draftIn(snapshot, _group) != '' ||
              gate.reached.isCompleted) {
            return;
          }
          await gate.pass();
          throw const FileSystemException('Injected snapshot write failure');
        });

        final send = _mention(runtime);
        await gate.reached.future.timeout(_wait);
        expect(runtime.draft, isEmpty);
        gate.open();
        await send;
        expect(runtime.error, isNotNull);
        expect(
          runtime.draft,
          _text,
          reason: 'the retry needs the original text',
        );
        expect(runtime.queuedCount, 1);
        expect(host.texts, isEmpty);

        await _mention(runtime);
        expect(runtime.error, isNull);
        expect(runtime.draft, isEmpty);
        expect(_draftIn(await runtime.storage.read(), _group), isEmpty);
        expect(host.texts, [_text], reason: 'the retry sends the mention once');
      },
    );
  });

  group('private AI chat', () {
    testWidgets('a send empties the draft and a failure puts it back', (
      tester,
    ) async {
      final chat = _PrivateChat();
      await _openPrivate(tester, chat);
      await _enterPrivate(tester, '  你好  ');
      final result = chat.result = Completer<bool>();
      await _tapPrivateSend(tester);
      expect(chat.sends, ['你好']);
      expect(_privateDraft(tester), isEmpty);

      result.complete(false);
      await tester.pump();
      await tester.pump();
      expect(_privateDraft(tester), '  你好  ');
      expect(find.textContaining('草稿仍在'), findsWidgets);
    });

    testWidgets('a failure keeps text already in the draft', (tester) async {
      final chat = _PrivateChat();
      await _openPrivate(tester, chat);
      await _enterPrivate(tester, '旧文');
      final result = chat.result = Completer<bool>();
      await _tapPrivateSend(tester);
      expect(_privateDraft(tester), isEmpty);
      // The field is disabled while a send runs; setting the text directly
      // stands in for anything entered before the send settles.
      tester.widget<TextField>(_privateKey('draft')).controller!.text = '新字';

      result.complete(false);
      await tester.pump();
      await tester.pump();
      expect(_privateDraft(tester), '新字');
      expect(chat.sends, ['旧文']);
    });

    testWidgets('a completed send leaves the draft empty', (tester) async {
      final chat = _PrivateChat();
      await _openPrivate(tester, chat);
      await _enterPrivate(tester, '你好');
      await _tapPrivateSend(tester);
      await tester.pump();
      expect(chat.sends, ['你好']);
      expect(_privateDraft(tester), isEmpty);
    });
  });
}

Future<void> _mention(ClientRuntime runtime) => runtime.sendMentionedMessage(
  conversationId: _group,
  expectedDraft: _text,
  aiAccountId: 'ai',
);

Future<void> _saveDraft(ClientRuntime runtime) async {
  await runtime.selectConversation(_group);
  runtime.updateDraft(_text);
  await _barrier(runtime);
}

/// Completes after every draft save queued on the shell before it.
Future<void> _barrier(ClientRuntime runtime) =>
    runtime.shell.saveDraft('other', 'Keep this draft');

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

/// Holds the first checkpoint that queues an item at [gate], then fails it.
Future<void> Function(Map<String, Object?>) _failOnceAt(_Gate gate) =>
    (snapshot) async {
      if (!_hasQueuedItem(snapshot) || gate.reached.isCompleted) return;
      await gate.pass();
      throw const FileSystemException('Injected snapshot write failure');
    };

bool _hasQueuedItem(Map<String, Object?> snapshot) =>
    ((snapshot['shell'] as Map)['outbox'] as List).isNotEmpty;

String? _draftIn(Map<String, Object?> snapshot, String id) =>
    ((snapshot['shell'] as Map)['drafts'] as Map)[id] as String?;

/// Holds the first caller of [pass] until [open]; later callers go through.
class _Gate {
  final reached = Completer<void>();
  final _opened = Completer<void>();

  Future<void> pass() async {
    if (reached.isCompleted) return;
    reached.complete();
    await _opened.future;
  }

  void open() {
    if (!_opened.isCompleted) _opened.complete();
  }
}

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
  Completer<void>? holdSubmit;
  final submitted = Completer<void>();
  final texts = <String>[];
  final _messages = <String, Map<String, Object?>>{};

  static Future<_Host> start() async {
    final fixture = await Fixture.create();
    addTearDown(fixture.cleanup);
    final host = _Host(fixture);
    fixture.secure = jsonEncode(fixture.session());
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
    expect(runtime.online, isTrue);
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
        texts.add((message['body'] as Map)['text'] as String);
        if (!submitted.isCompleted) submitted.complete();
        await holdSubmit?.future;
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

class _PrivateChat extends AndroidPrivateAiChatPort {
  @override
  String get aiName => '琉璃鲸';
  @override
  bool isCurrent = true;
  @override
  bool busy = false;
  @override
  bool online = true;
  @override
  bool initialized = true;
  @override
  String? model = 'reef/chat-v3';
  @override
  String? endpoint = 'https://model.example.test/v1/chat/completions';
  @override
  String? personaName = '潮汐';
  @override
  String? personaText = '温和地倾听，回答保持简短。';
  @override
  int? personaVersion = 7;
  @override
  String? notice;
  @override
  bool keyConfigured = true;
  @override
  bool syncEnabled = false;
  @override
  List<PrivateAiExchange> exchanges = [];

  final sends = <String>[];
  Completer<bool>? result;

  @override
  Future<bool> loadHostProfile() async => true;

  @override
  Future<bool> configure({
    required String endpoint,
    required String model,
    String? apiKey,
  }) async => true;

  @override
  Future<bool> send(String text) async {
    sends.add(text);
    final sent = await (result?.future ?? Future.value(true));
    notifyListeners();
    return sent;
  }

  @override
  Future<void> setSyncEnabled(bool enabled) async {}

  @override
  Future<void> sync() async {}
}

Finder _privateKey(String name) => find.byKey(ValueKey('private-ai-$name'));

String _privateDraft(WidgetTester tester) =>
    tester.widget<TextField>(_privateKey('draft')).controller!.text;

Future<void> _openPrivate(WidgetTester tester, _PrivateChat chat) async {
  addTearDown(chat.dispose);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(375, 812);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(home: AndroidPrivateAiScreen(chat: chat)),
  );
  await tester.pump();
}

Future<void> _enterPrivate(WidgetTester tester, String text) async {
  await tester.ensureVisible(_privateKey('draft'));
  await tester.enterText(_privateKey('draft'), text);
  await tester.pump();
}

Future<void> _tapPrivateSend(WidgetTester tester) async {
  await tester.ensureVisible(_privateKey('send'));
  await tester.pump();
  await tester.tap(_privateKey('send'));
  await tester.pump();
}
