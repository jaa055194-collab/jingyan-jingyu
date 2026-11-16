import 'dart:io';

import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/creative/creative_activity_writer.dart';
import 'package:jingyu_host/src/creative/creative_migrations.dart';
import 'package:jingyu_host/src/creative/reports/reports_models.dart';
import 'package:jingyu_host/src/creative/creative_authorization_module.dart';
import 'package:jingyu_host/src/creative/sqlite_creative_authorization_store.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late SqliteDatabase database;
  late SqliteCreativeAuthorizationStore store;
  late Pipeline pipeline;

  Future<void> addAccount(String id, String kind) => database.execute(
    'INSERT INTO account(id, display_name, kind, is_admin, disabled, password_hash, failed_passwords, locked_until) VALUES(?,?,?,?,?,?,?,?)',
    [id, id, kind, 0, 0, kind == 'human' ? 'x' : null, 0, 0],
  );

  Future<HostResponse> put(String aiId, Object? body, {String? token}) =>
      pipeline.handle(
        HostRequest(
          method: 'PUT',
          path: Routes.creativeOwnerConsent.replaceFirst('{aiId}', aiId),
          headers: {if (token != null) 'authorization': 'Bearer $token'},
          body: body,
        ),
      );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jingyu-creative-auth-routes-');
    database = await SqliteDatabase.open(
      '${dir.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        aiIdentityMigration,
        ...creativeMigrations,
      ],
    );
    store = SqliteCreativeAuthorizationStore(database: database);
    await addAccount('owner1', 'human');
    await addAccount('owner2', 'human');
    await addAccount('ai-account1', 'ai');
    await database.execute(
      'INSERT INTO ai_operator(ai_id, operator_id) VALUES(?,?)',
      ['ai-account1', 'owner1'],
    );
    await database.execute(
      'INSERT INTO ai_profile(id, account_id) VALUES(?,?)',
      ['profile1', 'ai-account1'],
    );
    final router = Router();
    CreativeAuthorizationModule(
      store: store,
      activityWriter: SqliteCreativeActivityWriter(database: database),
    ).mount(router);
    pipeline = Pipeline(
      router: router,
      authenticate: (request) async => switch (request
          .headers['authorization']) {
        'Bearer owner1' => const Principal(accountId: 'owner1', deviceId: 'd1'),
        'Bearer owner2' => const Principal(accountId: 'owner2', deviceId: 'd2'),
        _ => null,
      },
    );
  });

  tearDown(() async {
    await database.close();
    await dir.delete(recursive: true);
  });

  test('requires authentication', () async {
    final response = await put('profile1', {
      'scopes': ['privateChat'],
      'radioEnabled': false,
    });
    expect(response.status, 401);
  });

  test(
    'owner explicitly grants and revokes each report scope and radio',
    () async {
      final granted = await put('profile1', {
        'scopes': ['privateChat', 'moments'],
        'radioEnabled': true,
      }, token: 'owner1');
      expect(granted.status, 200);
      expect(
        await store.scopesFor(
          ownerAccountId: 'owner1',
          aiProfileId: 'profile1',
        ),
        {CreativeScope.privateChat, CreativeScope.moments},
      );
      expect(
        await store.radioEnabledFor(
          ownerAccountId: 'owner1',
          aiProfileId: 'profile1',
        ),
        isTrue,
      );

      final revoked = await put('profile1', {
        'scopes': <String>[],
        'radioEnabled': false,
      }, token: 'owner1');
      expect(revoked.status, 200);
      expect(
        await store.scopesFor(
          ownerAccountId: 'owner1',
          aiProfileId: 'profile1',
        ),
        isEmpty,
      );
      expect(
        await store.radioEnabledFor(
          ownerAccountId: 'owner1',
          aiProfileId: 'profile1',
        ),
        isFalse,
      );
    },
  );

  test(
    'another account cannot create an authorization for this profile',
    () async {
      final response = await put('profile1', {
        'scopes': ['privateChat'],
        'radioEnabled': true,
      }, token: 'owner2');
      expect(response.status, 404);
      expect(
        await store.scopesFor(
          ownerAccountId: 'owner1',
          aiProfileId: 'profile1',
        ),
        isEmpty,
      );
    },
  );

  test('unknown scopes or unexpected body fields fail closed', () async {
    final unknown = await put('profile1', {
      'scopes': ['allMessages'],
      'radioEnabled': true,
    }, token: 'owner1');
    expect(unknown.status, 400);
    expect(
      await store.scopesFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'),
      isEmpty,
    );

    final extra = await put('profile1', {
      'scopes': ['privateChat'],
      'radioEnabled': false,
      'body': 'private',
    }, token: 'owner1');
    expect(extra.status, 400);
    expect(
      await store.scopesFor(ownerAccountId: 'owner1', aiProfileId: 'profile1'),
      isEmpty,
    );
  });
}
