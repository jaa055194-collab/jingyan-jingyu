import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/models/usage_meter.dart';
import 'package:jingyu_host/src/social/group_ai_migrations.dart';
import 'package:jingyu_host/src/social/group_ai_policy.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

AccountId account(String id) => AccountId.parse(id);
ConversationId group(String id) => ConversationId.parse(id);
const baseMigrations = [
  ...allMigrations,
  ...accountsMigrations,
  ...socialMigrations,
  Migration(
    504,
    'already applied higher version',
    'CREATE TABLE higher(id TEXT);',
  ),
];
const migrations = [...baseMigrations, groupAiMigration];

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late FakeClock clock;
  GroupAiPolicy policy(String actor, {int offset = 480}) => GroupAiPolicy(
    actorId: account(actor),
    database: db,
    clock: clock,
    budgetDay: (clock) => BudgetDay.fromClock(clock, offsetMinutes: offset),
  );
  Future<Result<void>> consume(
    String round, {
    String ai = 'ai_a',
    String inGroup = 'g',
    bool mentioned = true,
  }) => policy(
    ai,
  ).tryConsumePost(group(inGroup), roundId: round, mentioned: mentioned);
  Future<void> configure({
    int cap = 10,
    bool hosting = false,
    bool autonomous = false,
    int maxPerRound = 1,
  }) async {
    expect(
      (await policy('group_owner').updateSettings(
        group('g'),
        GroupAiSettings(
          dailyCap: cap,
          hosting: hosting,
          autonomousInterjection: autonomous,
          maxPerRound: maxPerRound,
        ),
      )).isOk,
      isTrue,
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('group-ai-');
    clock = FakeClock(DateTime.utc(2026, 11, 13, 12));
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: baseMigrations,
    );
    await db.close();
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: migrations,
    );
    for (final name in [
      'group_owner',
      'operator_a',
      'outsider',
      'ai_a',
      'ai_b',
      'orphan',
    ]) {
      final ai = name.startsWith('ai_') || name == 'orphan';
      await db.execute(
        '''INSERT INTO account
        (id,display_name,kind,is_admin,disabled,password_hash,failed_passwords,locked_until)
        VALUES (?,?,?,0,0,?,0,0)''',
        [name, name, ai ? 'ai' : 'human', ai ? null : 'hash'],
      );
    }
    for (final ai in ['ai_a', 'ai_b']) {
      await db.execute('INSERT INTO ai_operator VALUES (?,?)', [
        ai,
        'operator_a',
      ]);
    }
    for (final g in ['g', 'g2']) {
      await db.execute(
        "INSERT INTO social_conversations VALUES (?, 'group_owner', 'Group', 'all', 0)",
        [g],
      );
      for (final member in [
        'group_owner',
        'operator_a',
        'ai_a',
        'ai_b',
        'orphan',
      ]) {
        await db.execute('INSERT INTO social_members VALUES (?,?,0,1)', [
          g,
          member,
        ]);
      }
    }
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    '303 is opt-in and migrates below existing higher version only once',
    () async {
      expect(
        (await db.query(
          'SELECT version FROM schema_migrations WHERE version=303',
        )).length,
        1,
      );
      await db.close();
      db = await SqliteDatabase.open(
        '${directory.path}/host.sqlite',
        migrations: migrations,
      );
      expect(
        (await db.query(
          'SELECT version FROM schema_migrations WHERE version=303',
        )).length,
        1,
      );
      final bare = await SqliteDatabase.open(
        ':memory:',
        migrations: baseMigrations,
      );
      try {
        expect(
          await bare.query(
            "SELECT name FROM sqlite_master WHERE name='group_ai_settings'",
          ),
          isEmpty,
        );
      } finally {
        await bare.close();
      }
    },
  );

  test(
    'configuration-only policy updates and reads settings without a budget day',
    () async {
      final owner = GroupAiPolicy.configuration(
        actorId: account('group_owner'),
        database: db,
        clock: clock,
      );
      expect(
        (await owner.updateSettings(
          group('g'),
          const GroupAiSettings(dailyCap: 3, hosting: true),
        )).isOk,
        isTrue,
      );
      final settings = (await owner.getSettings(group('g'))).value;
      expect(settings.dailyCap, 3);
      expect(settings.hosting, isTrue);
      expect(settings.autonomousInterjection, isTrue);

      final operator = GroupAiPolicy.configuration(
        actorId: account('operator_a'),
        database: db,
        clock: clock,
      );
      expect(
        (await operator.updateMinInterval(
          account('ai_a'),
          group('g'),
          const Duration(seconds: 5),
        )).isOk,
        isTrue,
      );
      expect(
        (await db.query(
          'SELECT min_interval_ms FROM group_ai_intervals WHERE group_id=? AND ai_id=?',
          ['g', 'ai_a'],
        )).single['min_interval_ms'],
        5000,
      );
      expect(
        (await owner.setMuted(account('ai_a'), group('g'), muted: true)).isOk,
        isTrue,
      );
      expect(
        (await db.query(
          'SELECT muted FROM group_ai_mutes WHERE group_id=? AND ai_id=?',
          ['g', 'ai_a'],
        )).single['muted'],
        1,
      );
      expect(await db.query('SELECT * FROM group_ai_admissions'), isEmpty);
    },
  );

  test(
    'configuration-only policy rejects posting before opening a transaction',
    () async {
      await configure();
      final configuration = GroupAiPolicy.configuration(
        actorId: account('ai_a'),
        database: db,
        clock: clock,
      );
      // The database rejects nested transactions, so rejection must happen first.
      await db.transaction((tx) async {
        expect(
          (await configuration.mayPost(
            group('g'),
            roundId: 'r1',
            mentioned: true,
          )).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
        expect(
          (await configuration.tryConsumePost(
            group('g'),
            roundId: 'r1',
            mentioned: true,
          )).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
        expect(await tx.query('SELECT * FROM group_ai_admissions'), isEmpty);
      });
      // The original budget-aware constructor still admits the same round/cap.
      expect((await consume('r1')).isOk, isTrue);
      expect((await db.query('SELECT * FROM group_ai_admissions')).length, 1);
    },
  );

  test(
    'unconfigured fails closed; persisted defaults reject unmentioned without consuming',
    () async {
      expect((await consume('r0')).isErr, isTrue);
      await configure();
      final settings = (await policy(
        'group_owner',
      ).getSettings(group('g'))).value;
      expect(settings.minInterval, const Duration(seconds: 30));
      expect(settings.maxPerRound, 1);
      expect(settings.autonomousInterjection, isFalse);
      expect(settings.hosting, isFalse);
      expect(settings.interjectionGap, const Duration(minutes: 10));
      expect(
        (await consume('r1', mentioned: false)).failureOrNull?.code,
        FailureCode.forbidden,
      );
      expect(await db.query('SELECT * FROM group_ai_admissions'), isEmpty);
      await db.close();
      db = await SqliteDatabase.open(
        '${directory.path}/host.sqlite',
        migrations: migrations,
      );
      expect(
        (await policy(
          'ai_a',
        ).mayPost(group('g'), roundId: 'r1', mentioned: true)).isOk,
        isTrue,
      );
      expect(
        (await policy(
          'ai_a',
        ).mayPost(group('g'), roundId: 'r1', mentioned: true)).isOk,
        isTrue,
      );
      expect(await db.query('SELECT * FROM group_ai_admissions'), isEmpty);
      expect((await consume('r1')).isOk, isTrue);
    },
  );

  test(
    'interval exact boundary and old round counts survive intervening rounds and restart',
    () async {
      await configure();
      expect((await consume('r1')).isOk, isTrue);
      clock.advance(const Duration(milliseconds: 29999));
      expect(
        (await consume('r2')).failureOrNull?.code,
        FailureCode.rateLimited,
      );
      clock.advance(const Duration(milliseconds: 1));
      expect((await consume('r2')).isOk, isTrue);
      clock.advance(const Duration(seconds: 30));
      await db.close();
      db = await SqliteDatabase.open(
        '${directory.path}/host.sqlite',
        migrations: migrations,
      );
      expect(
        (await consume('r1')).failureOrNull?.code,
        FailureCode.rateLimited,
      );
      expect((await consume('r3')).isOk, isTrue);
      expect(
        (await policy('ai_a').mayPost(
          group('g'),
          roundId: '',
          mentioned: true,
        )).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
    },
  );

  test(
    'daily cap is shared by AI group members and resets at explicit offset midnight',
    () async {
      clock.set(DateTime.utc(2026, 11, 13, 15, 59, 30));
      await configure(cap: 2);
      expect((await consume('r1')).isOk, isTrue);
      expect((await consume('r1', ai: 'ai_b')).isOk, isTrue);
      expect((await consume('r2', ai: 'ai_b')).isErr, isTrue);
      // A changed offset that still maps to the same civil date cannot reset cap.
      expect(
        (await policy(
          'ai_b',
          offset: 420,
        ).tryConsumePost(group('g'), roundId: 'r2', mentioned: true)).isErr,
        isTrue,
      );
      expect(
        (await policy(
          'group_owner',
        ).updateSettings(group('g2'), const GroupAiSettings(dailyCap: 1))).isOk,
        isTrue,
      );
      expect((await consume('r1', inGroup: 'g2')).isOk, isTrue);
      clock.advance(
        const Duration(seconds: 30),
      ); // UTC 16:00, offset +08 midnight.
      expect((await consume('r2')).isOk, isTrue);
      final rows = await db.query(
        'SELECT budget_day,offset_minutes FROM group_ai_admissions WHERE group_id=? ORDER BY id',
        ['g'],
      );
      expect(rows.map((row) => row['budget_day']), [
        '2026-11-13',
        '2026-11-13',
        '2026-11-14',
      ]);
      expect(rows.map((row) => row['offset_minutes']), everyElement(480));
      // The explicit day key is the bucket identity. Its supplied offset is retained per row.
      expect(
        (await policy(
          'ai_b',
          offset: 540,
        ).tryConsumePost(group('g'), roundId: 'r2', mentioned: true)).isOk,
        isTrue,
      );
      expect(
        (await policy(
          'ai_b',
          offset: 600,
        ).tryConsumePost(group('g'), roundId: 'r3', mentioned: true)).isErr,
        isTrue,
      );
    },
  );

  test(
    'canonical group owner controls shared settings and mute, AI owner controls only interval',
    () async {
      for (final actor in ['operator_a', 'outsider', 'ai_a']) {
        expect(
          (await policy(actor).updateSettings(
            group('g'),
            const GroupAiSettings(dailyCap: 1),
          )).isErr,
          isTrue,
        );
      }
      await db.execute('UPDATE account SET is_admin=1 WHERE id=?', [
        'outsider',
      ]);
      expect(
        (await policy(
          'outsider',
        ).updateSettings(group('g'), const GroupAiSettings(dailyCap: 1))).isErr,
        isTrue,
      );
      await configure();
      expect(
        (await policy('group_owner').updateMinInterval(
          account('ai_a'),
          group('g'),
          const Duration(seconds: 5),
        )).isErr,
        isTrue,
      );
      expect(
        (await policy('operator_a').updateMinInterval(
          account('ai_a'),
          group('g'),
          const Duration(seconds: 5),
        )).isOk,
        isTrue,
      );
      await configure(
        cap: 3,
      ); // Group settings cannot overwrite the AI-owner override.
      expect((await consume('r1')).isOk, isTrue);
      clock.advance(const Duration(seconds: 5));
      expect((await consume('r2')).isOk, isTrue);
      expect(
        (await policy(
          'operator_a',
        ).setMuted(account('ai_a'), group('g'), muted: true)).isErr,
        isTrue,
      );
      expect(
        (await policy(
          'group_owner',
        ).setMuted(account('ai_a'), group('g'), muted: true)).isOk,
        isTrue,
      );
      clock.advance(const Duration(seconds: 5));
      expect((await consume('r3')).failureOrNull?.code, FailureCode.forbidden);
      await policy(
        'group_owner',
      ).setMuted(account('ai_a'), group('g'), muted: false);
      expect((await consume('r3')).isOk, isTrue);
      await db.execute('UPDATE ai_operator SET operator_id=? WHERE ai_id=?', [
        'outsider',
        'ai_a',
      ]);
      expect(
        (await policy(
          'operator_a',
        ).updateMinInterval(account('ai_a'), group('g'), Duration.zero)).isErr,
        isTrue,
      );
    },
  );

  test(
    'posting requires current canonical AI, active human owner, group and membership',
    () async {
      await configure();
      for (final actor in [
        'group_owner',
        'operator_a',
        'outsider',
        'orphan',
        'missing',
      ]) {
        expect(
          (await policy(
            actor,
          ).mayPost(group('g'), roundId: 'r', mentioned: true)).isErr,
          isTrue,
        );
      }
      expect((await consume('r', inGroup: 'missing')).isErr, isTrue);
      await db.execute(
        'DELETE FROM social_members WHERE conversation_id=? AND account_id=?',
        ['g', 'ai_a'],
      );
      expect((await consume('r')).failureOrNull?.code, FailureCode.notFound);
      await db.execute('INSERT INTO social_members VALUES (?,?,0,1)', [
        'g',
        'ai_a',
      ]);
      await db.execute('UPDATE account SET disabled=1 WHERE id=?', [
        'operator_a',
      ]);
      expect((await consume('r')).isErr, isTrue);
      await db.execute('UPDATE account SET disabled=0 WHERE id=?', [
        'operator_a',
      ]);
      await db.execute('UPDATE account SET disabled=1 WHERE id=?', ['ai_a']);
      expect((await consume('r')).isErr, isTrue);
      await db.execute('UPDATE account SET disabled=0 WHERE id=?', ['ai_a']);
      await db.execute(
        'DELETE FROM social_members WHERE conversation_id=? AND account_id=?',
        ['g', 'group_owner'],
      );
      expect(
        (await policy(
          'group_owner',
        ).updateSettings(group('g'), const GroupAiSettings(dailyCap: 5))).isErr,
        isTrue,
      );
      expect(
        (await policy(
          'group_owner',
        ).setMuted(account('ai_a'), group('g'), muted: true)).isErr,
        isTrue,
      );
      expect(await db.query('SELECT * FROM group_ai_admissions'), isEmpty);
    },
  );

  test(
    'hosting enables interjection, shared gap boundary, disabling immediately defeats stale gate',
    () async {
      await configure(hosting: true);
      expect(
        (await policy(
          'group_owner',
        ).getSettings(group('g'))).value.autonomousInterjection,
        isTrue,
      );
      expect((await consume('r1', mentioned: false)).isOk, isTrue);
      clock.advance(
        const Duration(minutes: 10) - const Duration(milliseconds: 1),
      );
      expect(
        (await consume('r2', ai: 'ai_b', mentioned: false)).failureOrNull?.code,
        FailureCode.rateLimited,
      );
      clock.advance(const Duration(milliseconds: 1));
      expect((await consume('r2', ai: 'ai_b', mentioned: false)).isOk, isTrue);
      clock.advance(const Duration(minutes: 10));
      expect(
        (await policy(
          'ai_a',
        ).mayPost(group('g'), roundId: 'r3', mentioned: false)).isOk,
        isTrue,
      );
      await configure(hosting: false, autonomous: true);
      final settings = (await policy(
        'group_owner',
      ).getSettings(group('g'))).value;
      expect(settings.hosting, isFalse);
      expect(settings.autonomousInterjection, isFalse);
      expect(
        (await consume('r3', mentioned: false)).failureOrNull?.code,
        FailureCode.forbidden,
      );
      expect((await consume('r3')).isOk, isTrue);
      // Autonomous interjection can later be explicitly enabled without hosting.
      await configure(autonomous: true);
      clock.advance(const Duration(minutes: 10));
      expect((await consume('r4', mentioned: false)).isOk, isTrue);
    },
  );

  test(
    'admission rechecks changed cap and max per round and serializes concurrent consumes',
    () async {
      await configure(cap: 20, maxPerRound: 2);
      await policy(
        'operator_a',
      ).updateMinInterval(account('ai_a'), group('g'), Duration.zero);
      expect((await consume('r1')).isOk, isTrue);
      expect(
        (await policy(
          'ai_a',
        ).mayPost(group('g'), roundId: 'r1', mentioned: true)).isOk,
        isTrue,
      );
      await configure(cap: 20, maxPerRound: 1);
      expect((await consume('r1')).isErr, isTrue);
      expect(
        (await policy(
          'ai_a',
        ).mayPost(group('g'), roundId: 'r2', mentioned: true)).isOk,
        isTrue,
      );
      await configure(cap: 1);
      expect((await consume('r2')).isErr, isTrue);
      await configure(cap: 2);
      final results = await Future.wait(
        List.generate(
          16,
          (i) => consume('race_$i', ai: i.isEven ? 'ai_a' : 'ai_b'),
        ),
      );
      expect(results.where((r) => r.isOk).length, 1);
      expect((await db.query('SELECT * FROM group_ai_admissions')).length, 2);
    },
  );

  test('same trusted round remains consumed across budget midnight', () async {
    clock.set(DateTime.utc(2026, 11, 13, 15, 59, 30));
    await configure(cap: 1);
    expect((await consume('same_round')).isOk, isTrue);
    clock.advance(const Duration(seconds: 30));
    expect(
      (await consume('same_round')).failureOrNull?.code,
      FailureCode.rateLimited,
    );
    expect((await consume('new_round')).isOk, isTrue);
    expect((await db.query('SELECT * FROM group_ai_admissions')).length, 2);
  });

  test(
    'mentioned reply at nine minutes does not delay ten-minute interjection',
    () async {
      await configure(autonomous: true);
      expect((await consume('auto_1', mentioned: false)).isOk, isTrue);
      clock.advance(const Duration(minutes: 9));
      expect((await consume('mention_1', ai: 'ai_b')).isOk, isTrue);
      clock.advance(
        const Duration(minutes: 1) - const Duration(milliseconds: 1),
      );
      expect(
        (await consume('auto_2', mentioned: false)).failureOrNull?.code,
        FailureCode.rateLimited,
      );
      clock.advance(const Duration(milliseconds: 1));
      expect((await consume('auto_2', mentioned: false)).isOk, isTrue);
    },
  );

  test('settings reads require current active membership', () async {
    await configure();
    expect(
      (await policy('outsider').getSettings(group('g'))).failureOrNull?.code,
      FailureCode.notFound,
    );
    expect((await policy('ai_a').getSettings(group('g'))).isOk, isTrue);
    await db.execute('UPDATE account SET disabled=1 WHERE id=?', ['ai_a']);
    expect(
      (await policy('ai_a').getSettings(group('g'))).failureOrNull?.code,
      FailureCode.notFound,
    );
    await db.execute('UPDATE account SET disabled=1 WHERE id=?', [
      'group_owner',
    ]);
    expect(
      (await policy('group_owner').getSettings(group('g'))).failureOrNull?.code,
      FailureCode.notFound,
    );
  });

  test(
    'invalid settings and intervals reject without replacing current configuration',
    () async {
      await configure();
      for (final settings in [
        const GroupAiSettings(dailyCap: -1),
        const GroupAiSettings(dailyCap: 1, minInterval: Duration(seconds: 5)),
        const GroupAiSettings(dailyCap: 1, maxPerRound: 0),
        const GroupAiSettings(
          dailyCap: 1,
          minInterval: Duration(milliseconds: -1),
        ),
        const GroupAiSettings(
          dailyCap: 1,
          interjectionGap: Duration(seconds: -1),
        ),
      ]) {
        expect(
          (await policy(
            'group_owner',
          ).updateSettings(group('g'), settings)).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
      }
      expect(
        (await policy('operator_a').updateMinInterval(
          account('ai_a'),
          group('g'),
          const Duration(seconds: -1),
        )).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(
        (await policy('group_owner').getSettings(group('g'))).value.dailyCap,
        10,
      );
      await configure(cap: 0);
      expect((await consume('r')).failureOrNull?.code, FailureCode.rateLimited);
    },
  );
}
