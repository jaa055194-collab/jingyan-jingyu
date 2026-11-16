import 'dart:io';

import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/creative/creative_activity_writer.dart';
import 'package:jingyu_host/src/creative/creative_migrations.dart';
import 'package:jingyu_host/src/creative/reports/reports_models.dart';
import 'package:jingyu_host/src/creative/sqlite_creative_authorization_store.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late SqliteDatabase database;
  late SqliteCreativeAuthorizationStore authorization;
  late SqliteCreativeActivityWriter writer;

  Future<void> addAccount(String id, String kind) => database.execute(
    'INSERT INTO account(id, display_name, kind, is_admin, disabled, password_hash, failed_passwords, locked_until) VALUES(?,?,?,?,?,?,?,?)',
    [id, id, kind, 0, 0, kind == 'human' ? 'x' : null, 0, 0],
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jingyu-creative-writer-');
    database = await SqliteDatabase.open(
      '${dir.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        aiIdentityMigration,
        ...creativeMigrations,
      ],
    );
    authorization = SqliteCreativeAuthorizationStore(database: database);
    writer = SqliteCreativeActivityWriter(database: database);
    await addAccount('owner1', 'human');
    await addAccount('ai-account1', 'ai');
    await database.execute(
      'INSERT INTO ai_operator(ai_id, operator_id) VALUES(?,?)',
      ['ai-account1', 'owner1'],
    );
    await database.execute(
      'INSERT INTO ai_profile(id, account_id) VALUES(?,?)',
      ['profile1', 'ai-account1'],
    );
  });

  tearDown(() async {
    await database.close();
    await dir.delete(recursive: true);
  });

  test(
    'activity write is denied before explicit owner authorization',
    () async {
      await expectLater(
        writer.record(
          ownerAccountId: 'owner1',
          aiProfileId: 'profile1',
          scope: CreativeScope.privateChat,
          kind: CreativeActivityKind.topic,
          dayKey: '2026-11-16',
          label: 'books',
          value: 2,
        ),
        throwsA(isA<CreativeActivityWriteDenied>()),
      );
      expect(await database.query('SELECT * FROM creative_activity'), isEmpty);
    },
  );

  test(
    'authorized structured activity writes a bounded owner-scoped aggregate',
    () async {
      await authorization.setAuthorization(
        ownerAccountId: 'owner1',
        aiProfileId: 'profile1',
        scopes: {CreativeScope.privateChat},
        radioEnabled: false,
      );
      await writer.record(
        ownerAccountId: 'owner1',
        aiProfileId: 'profile1',
        scope: CreativeScope.privateChat,
        kind: CreativeActivityKind.topic,
        dayKey: '2026-11-16',
        label: 'books',
        value: 2,
      );
      expect(
        await database.query(
          'SELECT owner_account_id, ai_id, scope, kind, day_key, label, value FROM creative_activity',
        ),
        [
          {
            'owner_account_id': 'owner1',
            'ai_id': 'profile1',
            'scope': 'privateChat',
            'kind': 'topic',
            'day_key': '2026-11-16',
            'label': 'books',
            'value': 2,
          },
        ],
      );
    },
  );

  test(
    'activity writer validates AI ownership even after a stale grant',
    () async {
      await authorization.setAuthorization(
        ownerAccountId: 'owner1',
        aiProfileId: 'profile1',
        scopes: {CreativeScope.privateChat},
        radioEnabled: false,
      );
      await database.execute('UPDATE account SET disabled=1 WHERE id=?', [
        'ai-account1',
      ]);
      await expectLater(
        writer.record(
          ownerAccountId: 'owner1',
          aiProfileId: 'profile1',
          scope: CreativeScope.privateChat,
          kind: CreativeActivityKind.topic,
          dayKey: '2026-11-16',
          label: 'books',
        ),
        throwsA(isA<CreativeActivityWriteDenied>()),
      );
      expect(await database.query('SELECT * FROM creative_activity'), isEmpty);
    },
  );

  test(
    'activity writer rejects invalid labels and dates before storage',
    () async {
      await authorization.setAuthorization(
        ownerAccountId: 'owner1',
        aiProfileId: 'profile1',
        scopes: {CreativeScope.privateChat},
        radioEnabled: false,
      );
      await expectLater(
        writer.record(
          ownerAccountId: 'owner1',
          aiProfileId: 'profile1',
          scope: CreativeScope.privateChat,
          kind: CreativeActivityKind.topic,
          dayKey: '2026-2-2',
          label: 'bad\nlabel',
        ),
        throwsFormatException,
      );
      expect(await database.query('SELECT * FROM creative_activity'), isEmpty);
    },
  );
}
