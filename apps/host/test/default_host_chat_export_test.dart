import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/social/combined_membership.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/social/private_conversations.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

Map<String, Object?> _object(Object? value) => value as Map<String, Object?>;

void main() {
  test(
    'default host exports only the authenticated account’s visible history',
    () async {
      final directory = await Directory.systemTemp.createTemp('chat-export-');
      addTearDown(() => directory.delete(recursive: true));
      final host = await buildHost(
        config: HostConfig(dataDir: directory.path),
        clock: FakeClock(DateTime.utc(2026, 11, 19)),
      );
      addTearDown(host.shutdown);
      const password = 'synthetic-export-test-password';
      final owner = (await host.auth.bootstrapAdmin(
        displayName: 'Group owner',
        password: password,
      )).value;

      Future<String> token(AccountId account) async => (await host.auth.login(
        account,
        password,
        deviceName: 'export-test',
      )).value.accessToken;

      final ownerToken = await token(owner);
      final admin = (await host.auth.scope(ownerToken)).value.accounts;
      final member = (await admin.createHuman(
        displayName: 'Late member',
        password: password,
      )).value;
      final outsider = (await admin.createHuman(
        displayName: 'Other owner',
        password: password,
      )).value;
      final memberToken = await token(member);
      final outsiderToken = await token(outsider);

      Future<HostResponse> post(
        String path, {
        String? token,
        Map<String, Object?>? body,
      }) => host.pipeline.handle(
        HostRequest(
          method: 'POST',
          path: path,
          headers: {if (token != null) 'authorization': 'Bearer $token'},
          body: body,
        ),
      );

      Future<Object?> authorizedPost(
        String token,
        String path, [
        Map<String, Object?>? body,
      ]) async {
        final response = await post(path, token: token, body: body);
        expect(response.status, 200, reason: path);
        return response.json;
      }

      String conversationRoute(String route, String id) =>
          route.replaceFirst('{conversationId}', id);

      Future<String> group(
        String token,
        String name, {
        bool joined = false,
      }) async {
        final response = await authorizedPost(token, Routes.conversations, {
          'name': name,
          'historyVisibility': joined ? 'joined' : 'all',
        });
        return _object(response)['id'] as String;
      }

      Future<String> friendChat(
        AccountId first,
        String firstToken,
        AccountId second,
        String secondToken,
      ) async {
        await authorizedPost(
          firstToken,
          Routes.friendRequest.replaceFirst('{accountId}', second.value),
        );
        await authorizedPost(
          secondToken,
          Routes.friendAccept.replaceFirst('{accountId}', first.value),
        );
        final response = await authorizedPost(
          firstToken,
          Routes.directConversations,
          {'accountId': second.value},
        );
        return _object(response)['id'] as String;
      }

      Future<Map<String, Object?>> send(
        String token,
        String id,
        String key,
        String text,
      ) async {
        final response = await authorizedPost(
          token,
          conversationRoute(Routes.messages, id),
          {
            'clientMsgId': key,
            'kind': 'text',
            'body': {'text': text},
          },
        );
        return _object(_object(response)['message']);
      }

      final joined = await group(ownerToken, 'Joined group', joined: true);
      await send(ownerToken, joined, 'before-1', 'hidden before join 1');
      await send(ownerToken, joined, 'before-2', 'hidden before join 2');
      await authorizedPost(
        ownerToken,
        conversationRoute(Routes.conversationMembers, joined),
        {'accountId': member.value},
      );
      final firstVisible = await send(
        ownerToken,
        joined,
        'after-3',
        'visible 3',
      );

      // Seed additional rows through the default host’s canonical SQLite store;
      // the 201 visible rows span its 200-row export page size.
      final store = host.registry.services.get<MessageStore>();
      for (var seq = 4; seq <= 202; seq++) {
        final result = await store.append(
          conversationId: joined,
          senderId: owner.value,
          clientMsgId: 'after-$seq',
          kind: MessageKind.text,
          body: {'text': 'visible $seq'},
        );
        expect(result.isOk, isTrue);
      }
      final lastVisible = await send(
        memberToken,
        joined,
        'after-203',
        'visible 203',
      );
      final empty = await group(memberToken, 'Empty group');
      final otherGroup = await group(outsiderToken, 'Other group');
      await send(
        outsiderToken,
        otherGroup,
        'private-group',
        'foreign group text',
      );

      final memberDirect = await friendChat(
        owner,
        ownerToken,
        member,
        memberToken,
      );
      final visibleDirect = await send(
        ownerToken,
        memberDirect,
        'direct',
        'my direct text',
      );
      final otherDirect = await friendChat(
        owner,
        ownerToken,
        outsider,
        outsiderToken,
      );
      await send(
        outsiderToken,
        otherDirect,
        'foreign-direct',
        'foreign direct text',
      );

      expect((await post(Routes.lifecycleExport)).status, 401);
      // An untrusted owner in the request body must not override the principal.
      final bundle = _object(
        await authorizedPost(memberToken, Routes.lifecycleExport, {
          'ownerAccountId': outsider.value,
        }),
      );
      expect(bundle['ownerAccountId'], member.value);
      final manifest = _object(bundle['manifest']);
      expect(manifest['ownerAccountId'], member.value);
      expect(manifest['formatVersion'], 1);
      expect(manifest['counts'], {
        'conversations': 3,
        'messages': 202,
        'memories': 0,
        'attachments': 0,
        'persona': 0,
      });
      expect(manifest['coverage'], {
        'scope': 'chatHistory',
        'completeAccountExport': false,
        'pendingDomains': ['persona', 'memories', 'attachments'],
      });

      final files = _object(bundle['files']).cast<String, String>();
      String chatFile(String id) => 'conversations/$id.jsonl';
      final expectedPaths = [
        chatFile(joined),
        chatFile(empty),
        chatFile(memberDirect),
      ]..sort();
      expect(
        files.keys.where((path) => path.startsWith('conversations/')),
        expectedPaths,
      );
      expect(files[chatFile(empty)], '');
      expect(jsonDecode(files[chatFile(memberDirect)]!), visibleDirect);
      final rows = const LineSplitter()
          .convert(files[chatFile(joined)]!)
          .map((line) => _object(jsonDecode(line)))
          .toList();
      expect(rows.map((row) => row['seq']), List.generate(201, (i) => i + 3));
      expect(rows.first, firstVisible);
      expect(rows.last, lastVisible);
      final text = files.values.join('\n');
      for (final hidden in [
        'hidden before join 1',
        'hidden before join 2',
        'foreign group text',
        'foreign direct text',
        memberToken,
      ]) {
        expect(text, isNot(contains(hidden)));
      }
      final checksumPaths =
          files.keys.where((path) => path != 'SHA256SUMS').toList()..sort();
      final expectedSums = checksumPaths
          .map((path) => '${sha256.convert(utf8.encode(files[path]!))}  $path')
          .join('\n');
      expect(files['SHA256SUMS'], expectedSums);
      expect(bundle['sha256sums'], expectedSums);
      expect(jsonDecode(files['manifest.json']!), manifest);

      // The authenticated other account gets its own conversations, not the
      // member's joined group, their empty group, or their private conversation.
      final outsiderBundle = _object(
        await authorizedPost(outsiderToken, Routes.lifecycleExport),
      );
      final outsiderFiles = _object(outsiderBundle['files']);
      expect(
        outsiderFiles.keys.where((path) => path.startsWith('conversations/')),
        unorderedEquals([chatFile(otherGroup), chatFile(otherDirect)]),
      );
      expect(
        _object(outsiderBundle['manifest'])['ownerAccountId'],
        outsider.value,
      );
      expect(await authorizedPost(memberToken, Routes.lifecycleExport), bundle);

      final database = host.registry.services.get<Database>();
      final groups = host.registry.services.get<ConversationService>();
      final entered = Completer<void>();
      final resume = Completer<void>();
      final policy = CombinedMembership(
        db: database,
        group: groups,
        direct: host.registry.services.get<PrivateConversations>(),
        groupHistoryInTransaction: (tx, account, id) async {
          final floor = await groups.firstVisibleSeqInTransaction(
            tx,
            account,
            id,
          );
          if (id == empty) {
            entered.complete();
            await resume.future;
          }
          return floor;
        },
      );
      final history = policy.historySnapshot(member.value, [
        empty,
        joined,
        memberDirect,
      ]);
      await Future.any([
        entered.future,
        history.then(
          (_) =>
              throw StateError('Snapshot did not use the transaction callback'),
        ),
      ]);
      // Queue the leave immediately, in this caller's zone. If snapshots use
      // one transaction per ID, it can commit before the joined group is read.
      final leaving = groups.leave(
        actorId: member.value,
        conversationId: joined,
      );
      resume.complete();
      final snapshot = await history;
      expect((await leaving).isOk, isTrue);
      expect(snapshot, {empty: 1, joined: 3, memberDirect: 1});
      expect(await policy.firstVisibleSeq(member.value, joined), isNull);
      final afterLeaving = _object(
        await authorizedPost(memberToken, Routes.lifecycleExport),
      );
      final remainingFiles = _object(afterLeaving['files']);
      expect(
        remainingFiles.keys.where((path) => path.startsWith('conversations/')),
        unorderedEquals([chatFile(empty), chatFile(memberDirect)]),
      );
      expect(
        _object(_object(afterLeaving['manifest'])['counts'])['messages'],
        1,
      );

      // Simulate inconsistent storage claiming the same ID is both a group
      // and a direct. Neither HTTP sync nor export should expose its rows.
      await database.execute(
        '''INSERT INTO social_conversations
           (id, owner_account_id, name, history_visibility, created_at)
           VALUES (?, ?, 'Conflicting group ID', 'all', 0)''',
        [memberDirect, member.value],
      );
      final deniedSync = await host.pipeline.handle(
        HostRequest(
          method: 'GET',
          path: conversationRoute(Routes.sync, memberDirect),
          headers: {'authorization': 'Bearer $memberToken'},
        ),
      );
      expect(deniedSync.status, 404);
      final ambiguousBundle = _object(
        await authorizedPost(memberToken, Routes.lifecycleExport),
      );
      expect(
        _object(ambiguousBundle['files']),
        isNot(contains(chatFile(memberDirect))),
      );

      await database.execute('DELETE FROM social_conversations WHERE id = ?', [
        memberDirect,
      ]);
      await database.execute(
        'UPDATE messages SET body = ? WHERE message_id = ?',
        ['unreadable-ciphertext-marker', visibleDirect['messageId']],
      );
      final unreadable = await post(Routes.lifecycleExport, token: memberToken);
      expect(unreadable.status, 500);
      expect(unreadable.json, {'error': 'internal'});
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
