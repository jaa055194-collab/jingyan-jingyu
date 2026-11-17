import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_core/jingyu_core.dart';

import 'runtime_auth_test.dart' show Fixture, initializeAndSettleRefresh;

class _FailingPersistence implements ClientPersistence {
  @override
  Future<Map<String, Object?>> read() async => {};
  @override
  Future<void> write(Map<String, Object?> snapshot) async =>
      throw const FileSystemException('synthetic checkpoint failure');
}

class _CheckpointPersistence implements ClientPersistence {
  _CheckpointPersistence(this.failAt);
  final int failAt;
  int writes = 0;
  @override
  Future<Map<String, Object?>> read() async => {};
  @override
  Future<void> write(Map<String, Object?> snapshot) async {
    if (++writes == failAt) {
      throw const FileSystemException('synthetic checkpoint');
    }
  }
}

class _GatedPersistence implements ClientPersistence {
  _GatedPersistence({this.gateAt = 1});
  final int gateAt;
  int writes = 0;
  final started = Completer<void>();
  final release = Completer<void>();
  bool gate = true;
  @override
  Future<Map<String, Object?>> read() async => {};
  @override
  Future<void> write(Map<String, Object?> snapshot) async {
    if (++writes == gateAt && gate) {
      gate = false;
      started.complete();
      await release.future;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test('explicit mention survives failed delivery and restart, ordinary next send has no mention', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    var failing = true;
    final bodies = <Map>[];
    f.serve = (r) async {
      final text = await utf8.decoder.bind(r).join();
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      if (r.uri.path.endsWith('/messages')) {
        bodies.add(jsonDecode(text) as Map);
        return f.reply(
          r,
          failing ? {'error': 'unavailable'} : {},
          status: failing ? 503 : 200,
        );
      }
      if (r.uri.path.endsWith('/sync')) {
        return f.reply(r, {'messages': [], 'hasMore': false});
      }
      return f.reply(r, {
        'conversations': r.uri.path == Routes.conversations
            ? [
                {
                  'id': 'group',
                  'name': 'Group',
                  'kind': 'group',
                  'ownerAccountId': 'alice',
                },
              ]
            : [],
      });
    };
    var runtime = ClientRuntime();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      await runtime.selectConversation('group');
      runtime.updateDraft('你好');
      await (runtime as dynamic).sendMentionedMessage(
        conversationId: 'group',
        expectedDraft: '你好',
        aiAccountId: 'ai-account',
      );
      expect(runtime.draft, '');
      expect(runtime.queuedCount, 1);
      expect(bodies.single['body'], {
        'text': '你好',
        'mentionAccountIds': ['ai-account'],
      });
      final stableId = bodies.single['clientMsgId'];
      runtime.dispose();
      runtime = ClientRuntime();
      failing = false;
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      await runtime.selectConversation('group');
      expect(runtime.queuedCount, 0);
      expect(bodies.last['clientMsgId'], stableId);
      expect(bodies.last['body'], {
        'text': '你好',
        'mentionAccountIds': ['ai-account'],
      });
      runtime.updateDraft('ordinary');
      await runtime.sendMessage();
      expect(bodies.last['body'], {'text': 'ordinary'});
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });

  test(
    'durable enqueue failure preserves mention composer and never submits',
    () async {
      final f = await Fixture.create();
      f.secure = jsonEncode(f.session());
      f.serve = (r) async {
        await r.drain<void>();
        if (r.uri.path == Routes.hostInfo) {
          return f.reply(r, {'error': 'forbidden'}, status: 403);
        }
        if (r.uri.path.endsWith('/sync')) {
          return f.reply(r, {'messages': [], 'hasMore': false});
        }
        return f.reply(r, {
          'conversations': r.uri.path == Routes.conversations
              ? [
                  {'id': 'group', 'name': 'Group', 'ownerAccountId': 'alice'},
                ]
              : [],
        });
      };
      final runtime = ClientRuntime();
      try {
        await initializeAndSettleRefresh(runtime);
        runtime.reconnect?.cancel();
        await runtime.selectConversation('group');
        runtime.updateDraft('keep');
        await runtime.shell.saveDraft('group', 'keep');
        var submissions = 0;
        final failing = ClientShellController(
          persistence: _FailingPersistence(),
          submit: (_) async {
            submissions++;
            throw StateError('must not submit');
          },
          requestSync: (_) async {},
        );
        await failing.initialize();
        runtime.shell = failing;
        await runtime.sendMentionedMessage(
          conversationId: 'group',
          expectedDraft: 'keep',
          aiAccountId: 'ai',
        );
        expect(runtime.error, isNotNull);
        expect(runtime.draft, 'keep');
        expect(submissions, 0);
      } finally {
        runtime.dispose();
        await f.cleanup();
      }
    },
  );

  for (final stage in [1, 2]) {
    test(
      'checkpoint stage$stage retry after queued flush preserves one intent ID',
      () async {
        final f = await Fixture.create();
        f.secure = jsonEncode(f.session());
        f.serve = (r) async {
          await r.drain<void>();
          if (r.uri.path == Routes.hostInfo) {
            return f.reply(r, {'error': 'forbidden'}, status: 403);
          }
          if (r.uri.path.endsWith('/sync')) {
            return f.reply(r, {'messages': [], 'hasMore': false});
          }
          return f.reply(r, {
            'conversations': r.uri.path == Routes.conversations
                ? [
                    {'id': 'group', 'name': 'Group', 'ownerAccountId': 'alice'},
                  ]
                : [],
          });
        };
        final runtime = ClientRuntime();
        try {
          await initializeAndSettleRefresh(runtime);
          runtime.reconnect?.cancel();
          await runtime.selectConversation('group');
          runtime.updateDraft('intent');
          await runtime.shell.saveDraft('group', 'intent');
          final sent = <String>[];
          final controller = ClientShellController(
            persistence: _CheckpointPersistence(stage),
            submit: (item) async {
              sent.add(item.clientMsgId);
              return const Ok(null);
            },
            requestSync: (_) async {},
          );
          await controller.initialize();
          runtime.shell = controller;
          await runtime.sendMentionedMessage(
            conversationId: 'group',
            expectedDraft: 'intent',
            aiAccountId: 'ai',
          );
          expect(runtime.draft, 'intent');
          expect(controller.outbox.items, hasLength(1));
          final id = controller.outbox.items.single.clientMsgId;
          await runtime.sendMessage();
          expect(controller.outbox.items, hasLength(1));
          await controller.flush();
          await runtime.sendMentionedMessage(
            conversationId: 'group',
            expectedDraft: 'intent',
            aiAccountId: 'other-ai',
          );
          expect(controller.outbox.items, isEmpty);
          await runtime.sendMentionedMessage(
            conversationId: 'group',
            expectedDraft: 'intent',
            aiAccountId: 'ai',
          );
          expect(sent, [id]);
          expect(controller.outbox.items, isEmpty);
          expect(runtime.draft, '');
        } finally {
          runtime.dispose();
          await f.cleanup();
        }
      },
    );
  }

  test(
    'unresolved mention A blocks B without losing A identity after flush',
    () async {
      final f = await Fixture.create();
      f.secure = jsonEncode(f.session());
      f.serve = (r) async {
        await r.drain<void>();
        if (r.uri.path == Routes.hostInfo) {
          return f.reply(r, {'error': 'forbidden'}, status: 403);
        }
        if (r.uri.path.endsWith('/sync')) {
          return f.reply(r, {'messages': [], 'hasMore': false});
        }
        return f.reply(r, {
          'conversations': r.uri.path == Routes.conversations
              ? [
                  {'id': 'a', 'name': 'A', 'ownerAccountId': 'alice'},
                  {'id': 'b', 'name': 'B', 'ownerAccountId': 'alice'},
                ]
              : [],
        });
      };
      final runtime = ClientRuntime();
      try {
        await initializeAndSettleRefresh(runtime);
        runtime.reconnect?.cancel();
        await runtime.selectConversation('a');
        runtime.updateDraft('text-a');
        await runtime.shell.saveDraft('a', 'text-a');
        final sent = <(String, String)>[];
        final controller = ClientShellController(
          persistence: _CheckpointPersistence(1),
          submit: (item) async {
            sent.add((item.conversationId, item.clientMsgId));
            return const Ok(null);
          },
          requestSync: (_) async {},
        );
        await controller.initialize();
        runtime.shell = controller;
        await runtime.sendMentionedMessage(
          conversationId: 'a',
          expectedDraft: 'text-a',
          aiAccountId: 'ai-a',
        );
        final idA = controller.outbox.items.single.clientMsgId;
        await runtime.selectConversation('b');
        runtime.updateDraft('text-b');
        await controller.saveDraft('b', 'text-b');
        await runtime.sendMentionedMessage(
          conversationId: 'b',
          expectedDraft: 'text-b',
          aiAccountId: 'ai-b',
        );
        expect(runtime.error, contains('尚未确认'));
        expect(controller.outbox.items.single.clientMsgId, idA);
        await controller.flush();
        await runtime.selectConversation('a');
        runtime.updateDraft('text-a');
        await controller.saveDraft('a', 'text-a');
        await runtime.sendMentionedMessage(
          conversationId: 'a',
          expectedDraft: 'text-a',
          aiAccountId: 'ai-a',
        );
        expect(sent, [('a', idA)]);
        await runtime.selectConversation('b');
        await runtime.sendMentionedMessage(
          conversationId: 'b',
          expectedDraft: 'text-b',
          aiAccountId: 'ai-b',
        );
        expect(sent, hasLength(2));
        expect(sent.last.$1, 'b');
        expect(sent.last.$2, isNot(idA));
      } finally {
        runtime.dispose();
        await f.cleanup();
      }
    },
  );

  test('draft edit and selection drift while enqueue waits preserve original group newer draft', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    f.serve = (r) async {
      await r.drain<void>();
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      if (r.uri.path.endsWith('/sync')) {
        return f.reply(r, {'messages': [], 'hasMore': false});
      }
      return f.reply(r, {
        'conversations': r.uri.path == Routes.conversations
            ? [
                {'id': 'group', 'name': 'Group', 'ownerAccountId': 'alice'},
              ]
            : [],
      });
    };
    final runtime = ClientRuntime();
    final persistence = _GatedPersistence();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      await runtime.selectConversation('group');
      runtime.updateDraft('old');
      await runtime.shell.saveDraft('group', 'old');
      final controller = ClientShellController(
        persistence: persistence,
        submit: (_) async => const Ok(null),
        requestSync: (_) async {},
      );
      await controller.initialize();
      runtime.shell = controller;
      final sending = runtime.sendMentionedMessage(
        conversationId: 'group',
        expectedDraft: 'old',
        aiAccountId: 'ai',
      );
      await persistence.started.future;
      runtime.updateDraft('newer');
      await runtime.selectConversation('other');
      persistence.release.complete();
      await sending;
      await controller.saveDraft('barrier', '');
      expect(controller.draftFor('group'), 'newer');
    } finally {
      if (!persistence.release.isCompleted) persistence.release.complete();
      runtime.dispose();
      await f.cleanup();
    }
  });

  test(
    'same text reintroduced during clear checkpoint stays a new visible draft',
    () async {
      final f = await Fixture.create();
      f.secure = jsonEncode(f.session());
      f.serve = (r) async {
        await r.drain<void>();
        if (r.uri.path == Routes.hostInfo) {
          return f.reply(r, {'error': 'forbidden'}, status: 403);
        }
        if (r.uri.path.endsWith('/sync')) {
          return f.reply(r, {'messages': [], 'hasMore': false});
        }
        return f.reply(r, {
          'conversations': r.uri.path == Routes.conversations
              ? [
                  {'id': 'group', 'name': 'Group', 'ownerAccountId': 'alice'},
                ]
              : [],
        });
      };
      final runtime = ClientRuntime();
      final persistence = _GatedPersistence(gateAt: 2);
      try {
        await initializeAndSettleRefresh(runtime);
        runtime.reconnect?.cancel();
        await runtime.selectConversation('group');
        runtime.updateDraft('same');
        await runtime.shell.saveDraft('group', 'same');
        final controller = ClientShellController(
          persistence: persistence,
          submit: (_) async => const Ok(null),
          requestSync: (_) async {},
        );
        await controller.initialize();
        runtime.shell = controller;
        final work = runtime.sendMentionedMessage(
          conversationId: 'group',
          expectedDraft: 'same',
          aiAccountId: 'ai',
        );
        await persistence.started.future;
        runtime.updateDraft('same');
        persistence.release.complete();
        await work;
        await controller.saveDraft('barrier', '');
        expect(runtime.draft, 'same');
        expect(controller.draftFor('group'), 'same');
      } finally {
        if (!persistence.release.isCompleted) persistence.release.complete();
        runtime.dispose();
        await f.cleanup();
      }
    },
  );

  test('restored queued mention identity is reused when draft still needs clearing', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    var fail = true;
    final bodies = <Map>[];
    f.serve = (r) async {
      final raw = await utf8.decoder.bind(r).join();
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      if (r.uri.path.endsWith('/messages')) {
        bodies.add(jsonDecode(raw) as Map);
        return f.reply(
          r,
          fail ? {'error': 'unavailable'} : {},
          status: fail ? 503 : 200,
        );
      }
      if (r.uri.path.endsWith('/sync')) {
        return f.reply(r, {'messages': [], 'hasMore': false});
      }
      return f.reply(r, {
        'conversations': r.uri.path == Routes.conversations
            ? [
                {'id': 'group', 'name': 'Group', 'ownerAccountId': 'alice'},
              ]
            : [],
      });
    };
    var runtime = ClientRuntime();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      final id = await runtime.shell.enqueue('group', MessageKind.text, {
        'text': 'recover',
        'mentionAccountIds': ['ai'],
      });
      await runtime.shell.saveDraft('group', 'recover');
      runtime.dispose();
      runtime = ClientRuntime();
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      await runtime.selectConversation('group');
      expect(runtime.draft, 'recover');
      expect(runtime.queuedCount, 1);
      fail = false;
      await runtime.sendMentionedMessage(
        conversationId: 'group',
        expectedDraft: 'recover',
        aiAccountId: 'ai',
      );
      expect(bodies.map((body) => body['clientMsgId']).toSet(), {id});
      expect(runtime.queuedCount, 0);
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });

  test('invalid mention ID and stale composer context never enqueue', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    f.serve = (r) async {
      await r.drain<void>();
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      if (r.uri.path.endsWith('/sync')) {
        return f.reply(r, {'messages': [], 'hasMore': false});
      }
      return f.reply(r, {
        'conversations': r.uri.path == Routes.conversations
            ? [
                {'id': 'group', 'name': 'Group', 'ownerAccountId': 'alice'},
              ]
            : [],
      });
    };
    final runtime = ClientRuntime();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      await runtime.selectConversation('group');
      runtime.updateDraft('draft');
      await runtime.shell.saveDraft('group', 'draft');
      for (final args in [
        (group: 'group', draft: 'draft', target: 'bad/id'),
        (group: 'other', draft: 'draft', target: 'ai'),
        (group: 'group', draft: 'old', target: 'ai'),
      ]) {
        await (runtime as dynamic).sendMentionedMessage(
          conversationId: args.group,
          expectedDraft: args.draft,
          aiAccountId: args.target,
        );
      }
      expect(runtime.queuedCount, 0);
      expect(runtime.draft, 'draft');
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });
}
