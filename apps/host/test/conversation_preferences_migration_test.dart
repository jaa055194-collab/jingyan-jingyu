import 'dart:io';

import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/social/conversation_preferences_migration.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  test(
    '306 upgrades existing conversation databases without requiring 305',
    () async {
      final dir = await Directory.systemTemp.createTemp('pin-upgrade-');
      final path = '${dir.path}/db.sqlite';
      final baseline = [
        ...allMigrations,
        ...accountsMigrations,
        // Model the pre-announcement database even after main registers 305.
        ...socialMigrations.where((migration) => migration.version != 305),
        privateConversationMigration,
      ];
      var db = await SqliteDatabase.open(path, migrations: baseline);
      try {
        await db.execute(
          "INSERT INTO account VALUES ('owner','Owner','human',1,0,'fixture',0,0)",
        );
        await db.execute(
          "INSERT INTO social_conversations VALUES ('group','owner','Before','all',1)",
        );
        await db.execute(
          "INSERT INTO social_members VALUES ('group','owner',1,1)",
        );
        final before = await db.query('SELECT * FROM social_conversations');
        await db.close();
        db = await SqliteDatabase.open(
          path,
          migrations: [...baseline, conversationPreferencesMigration],
        );
        expect(await db.query('SELECT * FROM social_conversations'), before);
        expect(
          await db.query('SELECT * FROM conversation_preferences'),
          isEmpty,
        );
        expect(
          await db.query('SELECT 1 FROM schema_migrations WHERE version=305'),
          isEmpty,
        );
        await db.execute(
          "INSERT INTO conversation_preferences VALUES ('owner','group',1)",
        );
        await expectLater(
          db.execute(
            "UPDATE conversation_preferences SET pinned=2 WHERE account_id='owner' AND conversation_id='group'",
          ),
          throwsA(isA<Exception>()),
        );
        await db.close();
        db = await SqliteDatabase.open(
          path,
          migrations: [...baseline, conversationPreferencesMigration],
        );
        expect(
          (await db.query(
            'SELECT pinned FROM conversation_preferences',
          )).single['pinned'],
          1,
        );
        expect(
          await db.query('SELECT 1 FROM schema_migrations WHERE version=306'),
          hasLength(1),
        );
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
