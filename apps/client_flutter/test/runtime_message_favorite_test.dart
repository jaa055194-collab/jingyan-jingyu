import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/net/favorites_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'runtime_auth_test.dart' show Fixture, channel, nativeLogout;

class _Fixture {
  _Fixture(this.host);
  final Fixture host;
  final runtime = ClientRuntime();
  final arrived = Completer<void>();
  final writes = <Object?>[];
  Completer<void>? release;
  int status = 200;
  int renewals = 0;
  int floor = 1;

  static Future<_Fixture> open() async {
    final host = await Fixture.create();
    final fixture = _Fixture(host);
    addTearDown(() async {
      if (fixture.release case final gate? when !gate.isCompleted) {
        gate.complete();
      }
      fixture.runtime.dispose();
      await host.cleanup();
    });
    host.secure = jsonEncode(host.session());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (call) async => switch (call.method) {
            'getDataDirectory' => host.root.path,
            'readSession' => host.secure,
            'hasPin' => false,
            'configurePin' || 'unlockPin' => true,
            _ => null,
          },
        );
    host.serve = fixture.respond;
    await fixture.runtime.initialize();
    fixture.runtime.reconnect?.cancel();
    await fixture.runtime.refreshConversations();
    await fixture.runtime.shell.markRead('group', 2);
    await fixture.runtime.selectConversation('group');
    expect(fixture.runtime.online, isTrue);
    return fixture;
  }

  Future<void> respond(HttpRequest request) async {
    final path = request.uri.path;
    if (path == Routes.favorites && request.method == 'POST') {
      writes.add(jsonDecode(await utf8.decoder.bind(request).join()));
      if (!arrived.isCompleted) arrived.complete();
      await release?.future;
      try {
        await host.reply(
          request,
          status == 200
              ? {'id': 'fixture-favorite', 'kind': 'message', 'title': null}
              : {'error': status == 401 ? 'unauthenticated' : 'unavailable'},
          status: status,
        );
      } on IOException {
        // A logout can close the originating transport during the write.
      }
      return;
    }
    await request.drain<void>();
    if (request.method == 'POST' && path.endsWith('/group/messages')) {
      await host.reply(request, {'error': 'forbidden'}, status: 403);
    } else if (path == Routes.authRefresh) {
      renewals++;
      await host.reply(request, {'error': 'unauthenticated'}, status: 401);
    } else if (path == Routes.conversations) {
      await host.reply(request, {
        'conversations': [
          {'id': 'group', 'name': 'Favorite fixture'},
          {'id': 'other', 'name': 'Other conversation'},
        ],
      });
    } else if (path.endsWith('/group/sync')) {
      final after = int.parse(request.uri.queryParameters['afterSeq']!);
      await host.reply(request, {
        'firstVisibleSeq': floor,
        'messages': [
          for (final (seq, id, body) in [
            (
              1,
              'canonical',
              {'attachmentId': 'asset-1', 'name': 'private.pdf'},
            ),
            (2, 'recalled', {'recalled': true}),
          ])
            if (seq > after && seq >= floor)
              {
                'seq': seq,
                'conversationId': 'group',
                'messageId': id,
                'senderId': 'peer',
                'kind': 'file',
                'body': body,
                'sentAt': '2026-11-20T00:00:00.000Z',
              },
        ],
        'hasMore': false,
      });
    } else if (path.endsWith('/sync')) {
      await host.reply(request, {'messages': [], 'hasMore': false});
    } else {
      await host.reply(request, {'conversations': []});
    }
  }

  Future<FavoriteSaveOutcome> save({
    String conversation = 'group',
    String message = 'canonical',
    Object? context,
    bool Function()? current,
  }) => runtime.saveMessageFavorite(
    conversationId: conversation,
    messageId: message,
    expectedContext: context ?? runtime.messageFavoriteContext!,
    viewIsCurrent: current ?? () => true,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('only the visible canonical nonrecalled message is eligible', () async {
    final f = await _Fixture.open();
    final dropped = await f.runtime.shell.enqueue('group', MessageKind.text, {
      'text': 'dropped text',
    });
    await f.runtime.shell.flush();
    expect(f.runtime.shell.dropped.single.item.clientMsgId, dropped);
    final queued = await f.runtime.shell.enqueue('group', MessageKind.text, {
      'text': 'pending text',
    });
    expect(
      f.runtime.messages
          .where((row) => row.favoriteEligible)
          .map((row) => row.id),
      ['canonical'],
    );
    for (final id in [queued, dropped, 'recalled', 'unknown']) {
      expect(await f.save(message: id), FavoriteSaveOutcome.cancelled);
    }
    expect(await f.save(conversation: 'other'), FavoriteSaveOutcome.cancelled);
    f.floor = 2;
    await f.runtime.refreshConversations();
    expect(await f.save(), FavoriteSaveOutcome.cancelled);
    expect(f.writes, isEmpty);
  });

  test(
    'one explicit save sends only IDs, with no duplicate while or after saving',
    () async {
      final f = await _Fixture.open();
      f.release = Completer<void>();
      final pending = f.save();
      await f.arrived.future.timeout(const Duration(seconds: 5));
      expect(await f.save(), FavoriteSaveOutcome.cancelled);
      f.release!.complete();
      expect(await pending, FavoriteSaveOutcome.saved);
      await f.runtime.selectConversation('other');
      await f.runtime.selectConversation('group');
      expect(await f.save(), FavoriteSaveOutcome.cancelled);
      expect(f.writes, [
        {
          'kind': 'message',
          'conversationId': 'group',
          'messageId': 'canonical',
        },
      ]);
    },
  );

  test(
    'old callbacks cannot dispatch after a selection round trip or app lock',
    () async {
      final f = await _Fixture.open();
      final original = f.runtime.messageFavoriteContext!;
      await f.runtime.selectConversation('other');
      await f.runtime.selectConversation('group');
      expect(await f.save(context: original), FavoriteSaveOutcome.cancelled);
      expect(await f.save(current: () => false), FavoriteSaveOutcome.cancelled);
      final priorLock = f.runtime.messageFavoriteContext!;
      await f.runtime.setAppLock(true, '1234');
      f.runtime.appLock.lock();
      await f.runtime.unlock('1234');
      expect(await f.save(context: priorLock), FavoriteSaveOutcome.cancelled);
      expect(f.writes, isEmpty);
    },
  );

  for (final interruption in [
    'selection round trip',
    'lock',
    'logout',
    'covered view',
  ]) {
    test('late write status is discarded after $interruption', () async {
      final f = await _Fixture.open();
      f.release = Completer<void>();
      if (interruption == 'lock') await f.runtime.setAppLock(true, '1234');
      var current = true;
      final pending = f.save(current: () => current);
      await f.arrived.future.timeout(const Duration(seconds: 5));
      if (interruption == 'selection round trip') {
        await f.runtime.selectConversation('other');
        await f.runtime.selectConversation('group');
      } else if (interruption == 'lock') {
        f.runtime.appLock.lock();
      } else if (interruption == 'logout') {
        await nativeLogout();
      } else {
        current = false;
      }
      f.release!.complete();
      expect(await pending, FavoriteSaveOutcome.cancelled);
      expect(f.writes, hasLength(1));
    });
  }

  test('uncertain saves stay spent and never retry or claim success', () async {
    final f = await _Fixture.open();
    f.status = 503;
    expect(await f.save(), FavoriteSaveOutcome.unknown);
    expect(f.runtime.hasSubmittedMessageFavorite('canonical'), isTrue);
    expect(await f.save(), FavoriteSaveOutcome.cancelled);
    expect(f.writes, hasLength(1));
    expect(f.renewals, 0);
  });
}
