import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/social/social_routes.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _FastHasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String value) async => 'test:$value';

  @override
  Future<bool> verifyAsync(String value, String encodedHash) async =>
      encodedHash == 'test:$value';
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AccountsDomain accounts;
  late ConversationService conversations;
  late Pipeline pipeline;
  late Map<String, String> tokens;
  late String groupId;
  const password = 'Test-Password-9';

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('group-members-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...messagesMigrations,
        ...socialMigrations,
      ],
    );
    final clock = FakeClock(DateTime.utc(2026, 11, 14, 9));
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    final adminId = (await accounts.bootstrapAdmin(
      displayName: 'Admin',
      password: password,
    )).value;
    final admin = (await accounts.scope(
      (await accounts.login(adminId, password, deviceName: 'admin')).value
          .accessToken,
    )).value;
    final ownerId = (await admin.accounts.createHuman(
      displayName: 'Owner',
      password: password,
    )).value;
    final memberId = (await admin.accounts.createHuman(
      displayName: 'Member',
      password: password,
    )).value;
    final outsiderId = (await admin.accounts.createHuman(
      displayName: 'Outsider',
      password: password,
    )).value;
    tokens = {
      'owner': (await accounts.login(ownerId, password, deviceName: 'o')).value
          .accessToken,
      'member': (await accounts.login(memberId, password, deviceName: 'm')).value
          .accessToken,
      'outsider':
          (await accounts.login(outsiderId, password, deviceName: 'x')).value
              .accessToken,
    };
    conversations = ConversationService(
      database: db,
      clock: clock,
      headSeq: (tx, id) async => 0,
      accountExists: (tx, id) async => (await tx.query(
        'SELECT id FROM account WHERE id = ? AND disabled = 0',
        [id],
      )).isNotEmpty,
    );
    final group = (await conversations.createGroup(
      ownerAccountId: ownerId.value,
      name: 'Members group',
    )).value;
    groupId = group.id;
    await conversations.addMember(
      actorAccountId: ownerId.value,
      conversationId: groupId,
      memberAccountId: memberId.value,
    );
    final router = Router();
    mountSocialRoutes(router, conversations);
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(accounts).call,
    );
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<HostResponse> list(String? token) => pipeline.handle(
    HostRequest(
      method: 'GET',
      path: Routes.conversationMembers.replaceFirst(
        '{conversationId}',
        groupId,
      ),
      headers: {if (token != null) 'authorization': 'Bearer $token'},
    ),
  );

  test('members can list the roster with owner flag', () async {
    final asOwner = await list(tokens['owner']);
    expect(asOwner.status, 200);
    final members = ((asOwner.json! as Map)['members'] as List)
        .cast<Map<String, Object?>>();
    expect(members, hasLength(2));
    final owners = members.where((m) => m['isOwner'] == true).toList();
    expect(owners, hasLength(1));
    expect(
      ((await list(tokens['member'])).json! as Map)['members'],
      hasLength(2),
    );
  });

  test('non-members are denied and anonymous is 401', () async {
    expect((await list(tokens['outsider'])).status, 404);
    expect((await list(null)).status, 401);
  });
}
