import 'dart:convert';

import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

import 'hardening_support.dart';

void main() {
  late Harness h;
  late TestUser owner;
  late TestUser participant;
  late Database db;

  setUp(() async {
    h = await Harness.boot();
    addTearDown(h.dispose);
    db = h.host.registry.services.get<Database>();
    owner = await h.seedAccount(
      displayName: 'Fixture owner',
      id: 'tapback-owner',
      token: syntheticToken('o'),
    );
    participant = await h.seedAccount(
      displayName: 'Fixture participant',
      id: 'tapback-participant',
      token: syntheticToken('p'),
    );
  });

  Future<HostResponse> post(
    String path,
    TestUser actor, [
    Map<String, Object?>? body,
  ]) async {
    final response = await h.handle(
      'POST',
      path,
      token: actor.token,
      body: body,
    );
    expectOk(response, 'POST $path');
    return response;
  }

  Future<HostResponse> reactions(
    String method,
    String conversation,
    String message,
    TestUser actor, {
    String emoji = '👍',
  }) => h.handle(
    method,
    '/api/v1/conversations/$conversation/messages/$message/reactions',
    token: actor.token,
    body: method == 'POST' ? {'emoji': emoji} : null,
  );

  Future<void> expectHidden(
    String conversation,
    String message,
    TestUser actor,
  ) async {
    final get = await reactions('GET', conversation, message, actor);
    final post = await reactions('POST', conversation, message, actor);
    expect([get.status, post.status], [404, 404]);
    expect(get.json, {'error': 'not_found'});
    expect(post.json, get.json);
  }

  Future<List<Map<String, Object?>>> audit(String message) async => [
    for (final row in await db.query(
      '''
SELECT actor_id, action, target_kind, meta FROM audit_log
WHERE target_id=? AND action IN ('message.react','message.unreact') ORDER BY id
''',
      [message],
    ))
      {...row, 'meta': jsonDecode(row['meta'] as String)},
  ];

  test('tapbacks respect the joined group history boundary', () async {
    final group =
        asMap(
              await post(Routes.conversations, owner, {
                'name': 'Joined group',
                'historyVisibility': 'joined',
              }),
            )['id']
            as String;
    final earlier = await sendText(h, owner.token, group, 'Older text', 'old');
    expect((await reactions('POST', group, earlier, owner)).status, 200);
    await post(
      fillPath(Routes.conversationMembers, {'conversationId': group}),
      owner,
      {'accountId': participant.id},
    );
    final visible = await sendText(h, owner.token, group, 'New text', 'new');

    await expectHidden(group, earlier, participant);
    final oldForOwner = await reactions('GET', group, earlier, owner);
    expect(asMap(oldForOwner)['reactions'], [
      {'accountId': owner.id, 'emoji': '👍'},
    ]);
    expect((await reactions('POST', group, visible, participant)).status, 200);
    final newForParticipant = await reactions(
      'GET',
      group,
      visible,
      participant,
    );
    expect(asMap(newForParticipant)['reactions'], [
      {'accountId': participant.id, 'emoji': '👍'},
    ]);
  });

  test(
    'missing and wrong-conversation targets do not return empty success',
    () async {
      final group = await createGroup(h, owner.token, 'Target group');
      final other = await createGroup(h, owner.token, 'Other group');
      final message = await sendText(h, owner.token, group, 'Text', 'fixture');
      await expectHidden(group, 'missing-message', owner);
      await expectHidden(other, message, owner);
      await expectHidden(group, message, participant);
      expect(await audit(message), isEmpty);
      final visible = await reactions('GET', group, message, owner);
      expect(visible.status, 200);
      expect(visible.json, {'reactions': []});
    },
  );

  test('recall hides existing reactions and rejects another toggle', () async {
    final group = await createGroup(h, owner.token, 'Recall target');
    final message = await sendText(h, owner.token, group, 'Text', 'fixture');
    expect((await reactions('POST', group, message, owner)).status, 200);
    await recallMessage(h, owner.token, group, message);

    await expectHidden(group, message, owner);
    expect(await audit(message), hasLength(1));
  });

  test(
    'blocked direct participants retain read but lose toggle permission',
    () async {
      await post(
        fillPath(Routes.friendRequest, {'accountId': participant.id}),
        owner,
      );
      await post(
        fillPath(Routes.friendAccept, {'accountId': owner.id}),
        participant,
      );
      final direct =
          asMap(
                await post(Routes.directConversations, owner, {
                  'accountId': participant.id,
                }),
              )['id']
              as String;
      final message = await sendText(h, owner.token, direct, 'Text', 'fixture');
      expect(
        (await reactions('POST', direct, message, participant)).status,
        200,
      );
      await post(
        fillPath(Routes.friendBlock, {'accountId': participant.id}),
        owner,
      );

      for (final actor in [owner, participant]) {
        final read = await reactions('GET', direct, message, actor);
        expect(read.status, 200);
        expect(asMap(read)['reactions'], [
          {'accountId': participant.id, 'emoji': '👍'},
        ]);
        final denied = await reactions('POST', direct, message, actor);
        expect(denied.status, 404);
        expect(denied.json, {'error': 'not_found'});
      }
    },
  );

  test(
    'revoking owner chat keeps history readable but blocks toggles',
    () async {
      final ai =
          asMap(
                await post(Routes.ownAiAccounts, owner, {
                  'displayName': 'Synthetic AI',
                }),
              )['accountId']
              as String;
      final profile =
          asMap(
                await post(Routes.aiProfileRegister, owner, {'accountId': ai}),
              )['profileId']
              as String;
      final consent = fillPath(Routes.ownerAiDirectConsent, {'aiId': profile});
      final grant = asMap(await post(consent, owner, {'expectedRevision': 0}));
      final direct = grant['conversationId'] as String;
      final message = await sendText(h, owner.token, direct, 'Text', 'fixture');
      expect((await reactions('POST', direct, message, owner)).status, 200);
      expect(
        (await h.handle(
          'DELETE',
          consent,
          token: owner.token,
          body: {'expectedRevision': grant['revision']},
        )).status,
        200,
      );

      final read = await reactions('GET', direct, message, owner);
      expect(read.status, 200);
      expect(asMap(read)['reactions'], [
        {'accountId': owner.id, 'emoji': '👍'},
      ]);
      final denied = await reactions('POST', direct, message, owner);
      expect(denied.status, 404);
      expect(denied.json, {'error': 'not_found'});
    },
  );

  test(
    'tapback audit records changes without the user-supplied value',
    () async {
      final group = await createGroup(h, owner.token, 'Audit target');
      final message = await sendText(
        h,
        owner.token,
        group,
        'Private text',
        'fixture',
      );
      // Older clients can still use opaque nonempty strings, not just a palette.
      const emoji = 'legacy opaque value';
      for (final active in [true, false]) {
        final result = await reactions(
          'POST',
          group,
          message,
          owner,
          emoji: emoji,
        );
        expect(result.status, 200);
        expect(result.json, {'emoji': emoji, 'active': active});
      }
      expect(await audit(message), [
        {
          'actor_id': owner.id,
          'action': 'message.react',
          'target_kind': 'message',
          'meta': {'conversationId': group},
        },
        {
          'actor_id': owner.id,
          'action': 'message.unreact',
          'target_kind': 'message',
          'meta': {'conversationId': group},
        },
      ]);
    },
  );

  for (final active in [false, true]) {
    test(
      'failed audit rolls back reaction ${active ? 'removal' : 'addition'}',
      () async {
        final group = await createGroup(h, owner.token, 'Atomic audit');
        final message = await sendText(
          h,
          owner.token,
          group,
          'Text',
          'fixture',
        );
        if (active) {
          expect((await reactions('POST', group, message, owner)).status, 200);
        }
        await db.execute('''
CREATE TRIGGER reject_tapback_audit BEFORE INSERT ON audit_log
WHEN NEW.action IN ('message.react','message.unreact')
BEGIN SELECT RAISE(ABORT, 'fixture audit failure'); END
''');
        final result = await reactions('POST', group, message, owner);
        expect(result.status, 500);
        expect(result.json, {'error': 'internal'});
        final read = await reactions('GET', group, message, owner);
        expect(asMap(read)['reactions'], [
          if (active) {'accountId': owner.id, 'emoji': '👍'},
        ]);
        expect(await audit(message), hasLength(active ? 1 : 0));
      },
    );
  }
}
