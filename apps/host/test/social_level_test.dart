import 'dart:io';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/ai/persona/persona_migrations.dart';
import 'package:jingyu_host/src/ai/life/life_migrations.dart';
import 'package:jingyu_host/src/ai/social_level/social_level_service.dart';
import 'package:jingyu_host/src/ai/social_level/social_level_store.dart';
import 'package:jingyu_host/src/ai/social_level/social_level_migrations.dart';
import 'package:jingyu_host/src/ai/social_level/sqlite_social_level_store.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';
import 'social_level_store_contract.dart';

class _MemoryFixture implements SocialLevelFixture {
  String operator = 'owner';
  bool ownerActive = true, aiActive = true;
  @override
  final clock = FakeClock(DateTime.utc(2026, 11, 16));
  @override
  late final SocialLevelService store = InMemorySocialLevelStore(
    clock: clock,
    ownsActiveAi: (owner, ai) =>
        ownerActive &&
        aiActive &&
        owner.value == operator &&
        ai.value == 'profile',
  );
  @override
  Future<void> transfer(String owner) async {
    operator = owner;
  }

  @override
  Future<void> setOwnerActive(bool active) async {
    ownerActive = active;
  }

  @override
  Future<void> setAiActive(bool active) async {
    aiActive = active;
  }

  @override
  Future<void> close() async {}
}

class _SqlFixture implements SocialLevelFixture {
  late Directory directory;
  late SqliteDatabase db;
  @override
  final clock = FakeClock(DateTime.utc(2026, 11, 16));
  @override
  late SocialLevelService store;
  static const migrations = [
    ...allMigrations,
    ...accountsMigrations,
    aiIdentityMigration,
    socialLevelMigration,
  ];
  static Future<_SqlFixture> create() async {
    final f = _SqlFixture();
    f.directory = await Directory.systemTemp.createTemp('social-level-store-');
    f.db = await SqliteDatabase.open(
      '${f.directory.path}/host.sqlite',
      migrations: migrations,
    );
    for (final name in ['owner', 'other']) {
      await f.db.execute(
        "INSERT INTO account VALUES (?,?,'human',0,0,'fixture',0,0)",
        [name, name],
      );
    }
    await f.db.execute(
      "INSERT INTO account VALUES ('ai','AI','ai',0,0,NULL,0,0)",
    );
    await f.db.execute("INSERT INTO ai_operator VALUES ('ai','owner')");
    await f.db.execute("INSERT INTO ai_profile VALUES ('profile','ai')");
    f.store = SqliteSocialLevelStore(database: f.db, clock: f.clock);
    return f;
  }

  @override
  Future<void> transfer(String owner) async {
    await db.execute("UPDATE ai_operator SET operator_id=? WHERE ai_id='ai'", [
      owner,
    ]);
  }

  @override
  Future<void> setOwnerActive(bool active) async {
    await db.execute("UPDATE account SET disabled=? WHERE id='owner'", [
      active ? 0 : 1,
    ]);
  }

  @override
  Future<void> setAiActive(bool active) async {
    await db.execute("UPDATE account SET disabled=? WHERE id='ai'", [
      active ? 0 : 1,
    ]);
  }

  @override
  Future<void> close() async {
    await db.close();
    await directory.delete(recursive: true);
  }
}

class _AbortAfterWrite implements Database {
  _AbortAfterWrite(this.inner);
  final Database inner;
  @override
  Future<T> transaction<T>(Future<T> Function(Tx) body) =>
      inner.transaction((tx) async {
        await body(tx);
        throw StateError('synthetic transaction abort');
      });
  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) => throw StateError('outer query forbidden');
  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) =>
      throw StateError('outer write forbidden');
  @override
  Future<int> schemaVersion() => inner.schemaVersion();
  @override
  Future<String> integrityCheck() => inner.integrityCheck();
}

void main() {
  socialLevelContract('memory', () async => _MemoryFixture());
  socialLevelContract('SQLite', _SqlFixture.create);
  test(
    'SQLite no seed rows, restart persists explicit state and malformed time fails closed',
    () async {
      final f = await _SqlFixture.create();
      try {
        expect(await f.db.query('SELECT * FROM ai_social_levels'), isEmpty);
        await f.store.set(
          owner: AccountId.parse('owner'),
          ai: AiId.parse('profile'),
          level: AiSocialLevel.l1,
        );
        await f.db.close();
        f.db = await SqliteDatabase.open(
          '${f.directory.path}/host.sqlite',
          migrations: _SqlFixture.migrations,
        );
        f.store = SqliteSocialLevelStore(database: f.db, clock: f.clock);
        expect(
          (await f.store.get(
            owner: AccountId.parse('owner'),
            ai: AiId.parse('profile'),
          )).value.level,
          AiSocialLevel.l1,
        );
        await f.db.execute("UPDATE ai_social_levels SET updated_at='invalid'");
        expect(
          (await f.store.get(
            owner: AccountId.parse('owner'),
            ai: AiId.parse('profile'),
          )).failureOrNull?.code,
          FailureCode.internal,
        );
      } finally {
        await f.close();
      }
    },
  );
  test(
    'SQLite same-owner second profile remains isolated and CHECK rejects invalid enum',
    () async {
      final f = await _SqlFixture.create();
      try {
        await f.db.execute(
          "INSERT INTO account VALUES ('ai2','AI2','ai',0,0,NULL,0,0)",
        );
        await f.db.execute("INSERT INTO ai_operator VALUES ('ai2','owner')");
        await f.db.execute("INSERT INTO ai_profile VALUES ('profile2','ai2')");
        final owner = AccountId.parse('owner');
        await f.store.set(
          owner: owner,
          ai: AiId.parse('profile'),
          level: AiSocialLevel.l4,
        );
        expect(
          (await f.store.get(
            owner: owner,
            ai: AiId.parse('profile2'),
          )).value.configurationRequired,
          isTrue,
        );
        await f.store.set(
          owner: owner,
          ai: AiId.parse('profile2'),
          level: AiSocialLevel.l0,
        );
        expect(
          (await f.store.get(
            owner: owner,
            ai: AiId.parse('profile'),
          )).value.level,
          AiSocialLevel.l4,
        );
        await expectLater(
          f.db.execute(
            "UPDATE ai_social_levels SET level='L9' WHERE ai_profile_id='profile'",
          ),
          throwsA(isA<Exception>()),
        );
        expect(
          (await f.store.get(
            owner: owner,
            ai: AiId.parse('profile'),
          )).value.level,
          AiSocialLevel.l4,
        );
      } finally {
        await f.close();
      }
    },
  );

  test(
    'pre603 database upgrades without backfill or changing persona and life rows',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'social-level-upgrade-',
      );
      final path = '${directory.path}/host.sqlite';
      final beforeMigrations = [
        ...allMigrations,
        ...accountsMigrations,
        aiIdentityMigration,
        ...personaMigrations,
        ...lifeMigrations,
      ];
      var db = await SqliteDatabase.open(path, migrations: beforeMigrations);
      try {
        await db.execute(
          "INSERT INTO account VALUES ('owner','Owner','human',0,0,'fixture',0,0)",
        );
        await db.execute(
          "INSERT INTO account VALUES ('ai','AI','ai',0,0,NULL,0,0)",
        );
        await db.execute("INSERT INTO ai_operator VALUES ('ai','owner')");
        await db.execute("INSERT INTO ai_profile VALUES ('profile','ai')");
        await db.execute(
          "INSERT INTO persona_cards VALUES ('profile','owner',1,0,'opaque-fixture-ciphertext')",
        );
        await db.execute(
          "INSERT INTO life_state VALUES ('owner','profile','2026-11-16T00:00:00.000Z','2026-11-16T00:00:00.000Z','reading','home',60,'calm','available',40)",
        );
        final persona = await db.query('SELECT * FROM persona_cards');
        final life = await db.query('SELECT * FROM life_state');
        expect(await db.schemaVersion(), 602);
        await db.close();
        db = await SqliteDatabase.open(
          path,
          migrations: [...beforeMigrations, socialLevelMigration],
        );
        expect(await db.schemaVersion(), 603);
        expect(await db.query('SELECT * FROM ai_social_levels'), isEmpty);
        expect(await db.query('SELECT * FROM persona_cards'), persona);
        expect(await db.query('SELECT * FROM life_state'), life);
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test('SQLite corrupt calendar overflow timestamp fails closed', () async {
    final f = await _SqlFixture.create();
    try {
      await f.store.set(
        owner: AccountId.parse('owner'),
        ai: AiId.parse('profile'),
        level: AiSocialLevel.l1,
      );
      await f.db.execute(
        "UPDATE ai_social_levels SET updated_at='2026-11-31T00:00:00.000Z'",
      );
      expect(
        (await f.store.get(
          owner: AccountId.parse('owner'),
          ai: AiId.parse('profile'),
        )).failureOrNull?.code,
        FailureCode.internal,
      );
    } finally {
      await f.close();
    }
  });

  test(
    'SQLite canonical authorization and setting write share rollback transaction',
    () async {
      final f = await _SqlFixture.create();
      try {
        final store = SqliteSocialLevelStore(
          database: _AbortAfterWrite(f.db),
          clock: f.clock,
        );
        await expectLater(
          store.set(
            owner: AccountId.parse('owner'),
            ai: AiId.parse('profile'),
            level: AiSocialLevel.l4,
          ),
          throwsStateError,
        );
        expect(await f.db.query('SELECT * FROM ai_social_levels'), isEmpty);
      } finally {
        await f.close();
      }
    },
  );
  test(
    'SQLite checks live owner kind and removed canonical relationships',
    () async {
      final f = await _SqlFixture.create();
      try {
        await f.store.set(
          owner: AccountId.parse('owner'),
          ai: AiId.parse('profile'),
          level: AiSocialLevel.l1,
        );
        await f.db.execute(
          "UPDATE account SET kind='ai',password_hash=NULL WHERE id='owner'",
        );
        expect(
          (await f.store.get(
            owner: AccountId.parse('owner'),
            ai: AiId.parse('profile'),
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
        await f.db.execute(
          "UPDATE account SET kind='human',password_hash='fixture' WHERE id='owner'",
        );
        await f.db.execute("DELETE FROM ai_operator WHERE ai_id='ai'");
        expect(
          (await f.store.set(
            owner: AccountId.parse('owner'),
            ai: AiId.parse('profile'),
            level: AiSocialLevel.l4,
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await f.db.query(
            'SELECT level FROM ai_social_levels',
          )).single['level'],
          'L1',
        );
      } finally {
        await f.close();
      }
    },
  );
}
