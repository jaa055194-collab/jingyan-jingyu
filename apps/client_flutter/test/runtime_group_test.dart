import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'runtime_auth_test.dart'
    show Fixture, initializeAndSettleRefresh, nativeLogout;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('create selects confirmed group, preserves draft, adds member and reloads sent text', () async {
    final f = await Fixture.create();
    final groups = <Map<String, Object?>>[];
    final messages = <Map<String, Object?>>[];
    final members = <String>[];
    f.secure = jsonEncode(f.session());
    f.serve = (r) async {
      final text = await utf8.decoder.bind(r).join();
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      if (r.uri.path == Routes.conversations && r.method == 'POST') {
        final body = jsonDecode(text) as Map;
        final group = <String, Object?>{
          'id': 'group-new',
          'name': body['name'],
          'kind': 'group',
          'ownerAccountId': 'alice',
          'historyVisibility': 'all',
        };
        groups.add(group);
        return f.reply(r, group);
      }
      if (r.uri.path.endsWith('/members')) {
        members.add((jsonDecode(text) as Map)['accountId'] as String);
        await r.response.close();
        return;
      }
      if (r.uri.path.endsWith('/messages') && r.method == 'POST') {
        final body = jsonDecode(text) as Map;
        messages.add({
          'conversationId': 'group-new',
          'messageId': 'm1',
          'seq': 1,
          'senderId': 'alice',
          'kind': 'text',
          'body': body['body'],
          'sentAt': '2026-11-16T00:00:00Z',
        });
        return f.reply(r, {});
      }
      if (r.uri.path.endsWith('/sync')) {
        return f.reply(r, {'messages': messages, 'hasMore': false});
      }
      return f.reply(r, {
        'conversations': r.uri.path == Routes.conversations ? groups : [],
      });
    };
    final runtime = ClientRuntime();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      await runtime.selectConversation('old-group');
      runtime.updateDraft('keep old draft');
      await (runtime as dynamic).createGroup('Friends');
      expect(runtime.error, isNull);
      expect(runtime.selectedConversationId, 'group-new');
      expect(runtime.conversations.single.title, 'Friends');
      expect(runtime.shell.draftFor('old-group'), 'keep old draft');
      expect((runtime as dynamic).canAddMembersToSelectedGroup, isTrue);
      await (runtime as dynamic).addGroupMember('group-new', 'bob');
      expect(members, ['bob']);
      runtime.updateDraft('hello group');
      await runtime.sendMessage();
      expect(messages.single['body'], {'text': 'hello group'});
      expect(runtime.queuedCount, 0);
      runtime.dispose();
      final restored = ClientRuntime();
      try {
        await initializeAndSettleRefresh(restored);
        restored.reconnect?.cancel();
        await restored.selectConversation('group-new');
        expect(restored.messages.single.text, 'hello group');
      } finally {
        restored.dispose();
      }
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });

  test(
    'failed member addition retains confirmed group and never recreates it',
    () async {
      final f = await Fixture.create();
      f.secure = jsonEncode(f.session());
      var creates = 0;
      f.serve = (r) async {
        await r.drain<void>();
        if (r.method == 'POST' && r.uri.path == Routes.conversations) {
          creates++;
          return f.reply(r, {
            'id': 'g',
            'name': 'Group',
            'kind': 'group',
            'ownerAccountId': 'alice',
            'historyVisibility': 'all',
          });
        }
        if (r.uri.path.endsWith('/members')) {
          return f.reply(r, {'error': 'not_found'}, status: 404);
        }
        if (r.uri.path == Routes.hostInfo) {
          return f.reply(r, {'error': 'forbidden'}, status: 403);
        }
        return f.reply(r, {'conversations': []});
      };
      final runtime = ClientRuntime();
      try {
        await initializeAndSettleRefresh(runtime);
        runtime.reconnect?.cancel();
        await (runtime as dynamic).createGroup('Group');
        await (runtime as dynamic).addGroupMember('g', 'missing');
        expect(runtime.error, isNotNull);
        expect(runtime.selectedConversationId, 'g');
        expect(runtime.conversations.single.id, 'g');
        expect(creates, 1);
      } finally {
        runtime.dispose();
        await f.cleanup();
      }
    },
  );

  test('refresh racing create cannot overwrite confirmed new group', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    final refreshing = Completer<void>();
    final release = Completer<void>();
    var hold = false, creates = 0;
    f.serve = (r) async {
      await r.drain<void>();
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      if (r.method == 'POST') {
        creates++;
        return f.reply(r, {
          'id': 'g',
          'name': 'Group',
          'kind': 'group',
          'ownerAccountId': 'alice',
          'historyVisibility': 'all',
        });
      }
      if (hold && r.uri.path == Routes.conversations) {
        refreshing.complete();
        await release.future;
      }
      return f.reply(r, {'conversations': []});
    };
    final runtime = ClientRuntime();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      hold = true;
      final refresh =
          (runtime as dynamic).refreshConversations() as Future<void>;
      await refreshing.future;
      final create = runtime.createGroup('Group');
      expect(creates, 0);
      release.complete();
      await refresh;
      await create;
      expect(runtime.selectedConversationId, 'g');
      expect(runtime.conversations.single.id, 'g');
      expect(creates, 1);
    } finally {
      if (!release.isCompleted) release.complete();
      runtime.dispose();
      await f.cleanup();
    }
  });

  test(
    'only owned group permits member action and refresh never creates again',
    () async {
      final f = await Fixture.create();
      f.secure = jsonEncode(f.session());
      var posts = 0;
      f.serve = (r) async {
        await r.drain<void>();
        if (r.method == 'POST') posts++;
        if (r.uri.path == Routes.hostInfo) {
          return f.reply(r, {'error': 'forbidden'}, status: 403);
        }
        if (r.uri.path.endsWith('/sync')) {
          return f.reply(r, {'messages': [], 'hasMore': false});
        }
        return f.reply(r, {
          'conversations': r.uri.path == Routes.conversations
              ? [
                  {
                    'id': 'mine',
                    'name': 'Mine',
                    'kind': 'group',
                    'ownerAccountId': 'alice',
                  },
                  {
                    'id': 'other',
                    'name': 'Other',
                    'kind': 'group',
                    'ownerAccountId': 'bob',
                  },
                ]
              : [
                  {'id': 'dm', 'accountLow': 'alice', 'accountHigh': 'bob'},
                ],
        });
      };
      final runtime = ClientRuntime();
      try {
        await initializeAndSettleRefresh(runtime);
        runtime.reconnect?.cancel();
        await runtime.selectConversation('mine');
        expect(runtime.canAddMembersToSelectedGroup, isTrue);
        for (final id in ['other', 'dm']) {
          await runtime.selectConversation(id);
          expect(runtime.canAddMembersToSelectedGroup, isFalse);
          await runtime.addGroupMember(id, 'member');
        }
        await runtime.refreshConversations();
        expect(posts, 0);
      } finally {
        runtime.dispose();
        await f.cleanup();
      }
    },
  );

  test('busy duplicate create sends one POST and malformed response creates no phantom', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    final started = Completer<void>();
    final release = Completer<void>();
    var posts = 0;
    f.serve = (r) async {
      await r.drain<void>();
      if (r.method == 'POST') {
        posts++;
        started.complete();
        await release.future;
        return f.reply(r, {
          'id': 'bad/id',
          'name': 'Invalid',
          'kind': 'group',
          'ownerAccountId': 'alice',
          'historyVisibility': 'all',
        });
      }
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      return f.reply(r, {'conversations': []});
    };
    final runtime = ClientRuntime();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      final first = runtime.createGroup('First');
      await started.future;
      await runtime.createGroup('Second');
      expect(posts, 1);
      release.complete();
      await first;
      expect(runtime.conversations, isEmpty);
      expect(runtime.selectedConversationId, isNull);
      expect(runtime.error, contains('刷新会话'));
    } finally {
      if (!release.isCompleted) release.complete();
      runtime.dispose();
      await f.cleanup();
    }
  });

  for (final terminal in [false, true]) {
    test(
      'offline or terminal rejected session cannot POST create terminal=$terminal',
      () async {
        final f = await Fixture.create();
        f.secure = jsonEncode(f.session());
        var mutationPosts = 0;
        final settled = Completer<void>();
        f.serve = (r) async {
          await r.drain<void>();
          if (r.method == 'POST' && r.uri.path == Routes.conversations) {
            mutationPosts++;
          }
          return f.reply(r, {
            'error': terminal ? 'unauthenticated' : 'unavailable',
          }, status: terminal ? 401 : 503);
        };
        final runtime = ClientRuntime();
        runtime.addListener(() {
          if (runtime.ready &&
              !runtime.busy &&
              !settled.isCompleted &&
              (!terminal || runtime.error != null)) {
            settled.complete();
          }
        });
        try {
          await runtime.initialize();
          await settled.future.timeout(const Duration(seconds: 5));
          runtime.reconnect?.cancel();
          if (!terminal) {
            await runtime.refreshConversations();
            expect(runtime.online, isFalse);
          }
          await runtime.createGroup('Forbidden');
          expect(mutationPosts, 0);
          expect(runtime.conversations, isEmpty);
          if (terminal) expect(runtime.authenticated, isFalse);
        } finally {
          runtime.dispose();
          await f.cleanup();
        }
      },
    );
  }

  test('locked create attempt issues no mutation', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    var posts = 0;
    f.serve = (r) async {
      await r.drain<void>();
      if (r.method == 'POST') posts++;
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      return f.reply(r, {'conversations': []});
    };
    final runtime = ClientRuntime();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      await runtime.setAppLock(true, '1234');
      runtime.appLock.lock();
      await runtime.createGroup('Locked');
      expect(posts, 0);
      expect(runtime.conversations, isEmpty);
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });

  test(
    'uncertain create failure tells user to refresh without retrying',
    () async {
      final f = await Fixture.create();
      f.secure = jsonEncode(f.session());
      var creates = 0;
      f.serve = (r) async {
        await r.drain<void>();
        if (r.method == 'POST') {
          creates++;
          return f.reply(r, {'error': 'unavailable'}, status: 503);
        }
        if (r.uri.path == Routes.hostInfo) {
          return f.reply(r, {'error': 'forbidden'}, status: 403);
        }
        return f.reply(r, {'conversations': []});
      };
      final runtime = ClientRuntime();
      try {
        await initializeAndSettleRefresh(runtime);
        runtime.reconnect?.cancel();
        await runtime.createGroup('Uncertain');
        expect(runtime.error, contains('刷新会话'));
        expect(runtime.conversations, isEmpty);
        expect(creates, 1);
      } finally {
        runtime.dispose();
        await f.cleanup();
      }
    },
  );

  test(
    'authoritative refresh clears uncertain create guidance without replay',
    () async {
      final f = await Fixture.create();
      f.secure = jsonEncode(f.session());
      var created = false, posts = 0;
      f.serve = (r) async {
        await r.drain<void>();
        if (r.uri.path == Routes.hostInfo) {
          return f.reply(r, {'error': 'forbidden'}, status: 403);
        }
        if (r.uri.path.endsWith('/sync')) {
          return f.reply(r, {'messages': [], 'hasMore': false});
        }
        if (r.method == 'POST') {
          posts++;
          created = true;
          return f.reply(r, {'error': 'unavailable'}, status: 503);
        }
        return f.reply(r, {
          'conversations': created && r.uri.path == Routes.conversations
              ? [
                  {
                    'id': 'recovered',
                    'name': 'Recovered',
                    'kind': 'group',
                    'ownerAccountId': 'alice',
                  },
                ]
              : [],
        });
      };
      final runtime = ClientRuntime();
      try {
        await initializeAndSettleRefresh(runtime);
        runtime.reconnect?.cancel();
        await runtime.createGroup('Recovered');
        expect(runtime.error, contains('刷新会话'));
        await runtime.refreshConversations();
        expect(runtime.conversations.single.id, 'recovered');
        expect(runtime.error, isNull);
        expect(posts, 1);
      } finally {
        runtime.dispose();
        await f.cleanup();
      }
    },
  );

  test('late create response after logout never publishes a group', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    final started = Completer<void>();
    final release = Completer<void>();
    f.serve = (r) async {
      await r.drain<void>();
      if (r.method == 'POST') {
        started.complete();
        await release.future;
        try {
          await f.reply(r, {
            'id': 'late',
            'name': 'Late',
            'kind': 'group',
            'ownerAccountId': 'alice',
            'historyVisibility': 'all',
          });
        } catch (_) {}
        return;
      }
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      return f.reply(r, {'conversations': []});
    };
    final runtime = ClientRuntime();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      final work = (runtime as dynamic).createGroup('Late') as Future<void>;
      await started.future;
      await nativeLogout();
      release.complete();
      await work;
      expect(runtime.conversations, isEmpty);
      expect(runtime.selectedConversationId, isNull);
      expect(runtime.authenticated, isFalse);
    } finally {
      if (!release.isCompleted) release.complete();
      runtime.dispose();
      await f.cleanup();
    }
  });
}
