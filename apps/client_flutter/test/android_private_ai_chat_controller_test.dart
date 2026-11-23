import 'dart:async';

import 'package:client_flutter/app/android_private_ai_chat_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _Fixture {
  final events = ChangeNotifier();
  bool current = true;
  bool online = true;
  bool loseReceipt = false;
  Map<String, Object?>? stored;
  final sent = <(String, String, String)>[];
  final server = <PrivateAiSyncExchange>[];
  final pushes = <(String, String, String)>[];
  Completer<String>? reply;
  int cancels = 0;

  AndroidPrivateAiChatController open() => AndroidPrivateAiChatController(
    aiName: 'Nora',
    session: events,
    isSessionCurrent: () => current,
    isHostOnline: () => online,
    read: () async => stored,
    write: (value) async => stored = value,
    loadProfile: () async => (
      profileId: 'nora-profile',
      personaName: 'Nora (P0)',
      personaText: 'P1: be warm',
      personaVersion: 7,
      model: 'demo-chat',
      endpoint: 'https://provider.example/v1/chat/completions',
    ),
    loadBehavior: (profile) async => '社交等级：L3\n规则问候：关闭',
    parseEndpoint: Uri.parse,
    generate: (endpoint, model, key, persona, text, history) async {
      expect(key, 'fixture-provider-secret');
      sent.add((endpoint, model, persona));
      return await reply?.future ?? 'hello back';
    },
    closeModel: () => cancels++,
    list: (_, after) async => (
      items: server.where((exchange) => exchange.seq > after).toList(),
      hasMore: false,
    ),
    push: (_, id, user, assistant) async {
      pushes.add((id, user, assistant));
      final prior = server.where((row) => row.exchangeId == id).firstOrNull;
      final seq = prior?.seq ?? server.length + 1;
      if (prior == null) {
        server.add((
          seq: seq,
          exchangeId: id,
          user: user,
          assistant: assistant,
        ));
      }
      if (loseReceipt) throw TimeoutException('fixture');
      return seq;
    },
  );

  Future<AndroidPrivateAiChatController> setup() async {
    final chat = open();
    await chat.initialize();
    expect(await chat.loadHostProfile(), isTrue);
    expect(
      await chat.configure(
        endpoint: chat.endpoint!,
        model: chat.model!,
        apiKey: 'fixture-provider-secret',
      ),
      isTrue,
    );
    return chat;
  }
}

void main() {
  test(
    'after restart with host down, uses saved specific model and persona',
    () async {
      final fixture = _Fixture();
      final setup = await fixture.setup();
      setup.dispose();
      fixture.online = false;
      final reopened = fixture.open();
      addTearDown(reopened.dispose);
      await reopened.initialize();
      expect(reopened.personaName, 'Nora (P0)');
      expect(reopened.personaVersion, 7);
      expect(reopened.behaviorSnapshot, '社交等级：L3\n规则问候：关闭');
      expect(await reopened.send('hello'), isTrue);
      expect(fixture.sent, [
        (
          'https://provider.example/v1/chat/completions',
          'demo-chat',
          'P1: be warm',
        ),
      ]);
      expect(reopened.exchanges.single.assistant, 'hello back');
      expect(reopened.exchanges.single.seq, isNull);
      expect(fixture.pushes, isEmpty);
    },
  );

  test('ambiguous sync retains the same exchange ID and never shares key or profile contents', () async {
    final fixture = _Fixture();
    final chat = await fixture.setup();
    addTearDown(chat.dispose);
    await chat.send('hello');
    expect(fixture.pushes, isEmpty);
    fixture.loseReceipt = true;
    await chat.setSyncEnabled(true);
    await chat.sync();
    expect(chat.exchanges.single.seq, isNull);
    expect(fixture.pushes, isNotEmpty);
    final first = fixture.pushes.first;
    expect(first.$2, 'hello');
    expect(first.$3, 'hello back');
    fixture.loseReceipt = false;
    await chat.sync();
    expect(fixture.pushes.last, first);
    expect(fixture.server.length, 1);
    expect(chat.exchanges.single.seq, 1);
    expect(chat.exchanges.length, 1);
  });

  test(
    'changing provider URL cannot reuse the previous provider key',
    () async {
      final fixture = _Fixture();
      final chat = await fixture.setup();
      addTearDown(chat.dispose);
      expect(
        await chat.configure(
          endpoint: 'https://other.example/v1/chat/completions',
          model: 'other',
        ),
        isFalse,
      );
      expect(chat.model, 'demo-chat');
      expect(chat.endpoint, 'https://provider.example/v1/chat/completions');
    },
  );

  test('lock or account change discards a late provider result', () async {
    final fixture = _Fixture()..reply = Completer();
    final chat = await fixture.setup();
    addTearDown(chat.dispose);
    final response = chat.send('secret text');
    fixture.current = false;
    fixture.events.notifyListeners();
    fixture.reply!.complete('late reply');
    expect(await response, isFalse);
    expect(chat.exchanges, isEmpty);
    expect(fixture.cancels, greaterThan(0));
    expect(fixture.stored.toString(), isNot(contains('late reply')));
  });

  test(
    'an opted-in second device can retrieve history without obtaining a key',
    () async {
      final fixture = _Fixture();
      fixture.server.add((
        seq: 1,
        exchangeId: 'existing',
        user: 'hello',
        assistant: 'reply',
      ));
      final chat = fixture.open();
      addTearDown(chat.dispose);
      await chat.initialize();
      await chat.loadHostProfile();
      expect(chat.keyConfigured, isFalse);
      await chat.setSyncEnabled(true);
      await chat.sync();
      expect(chat.exchanges.single.assistant, 'reply');
      expect(chat.keyConfigured, isFalse);
      expect(fixture.pushes, isEmpty);
    },
  );
}
