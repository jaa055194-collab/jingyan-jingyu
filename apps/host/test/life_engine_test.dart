import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/ai/life/life_engine.dart';
import 'package:jingyu_host/src/ai/life/life_migrations.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

const _migrations = [
  ...allMigrations,
  ...accountsMigrations,
  aiIdentityMigration,
  ...lifeMigrations,
];

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late FakeClock clock;
  late LifeEngine engine;
  final ai = AiId.parse('profile');
  final otherAi = AiId.parse('other_profile');
  final start = DateTime.utc(2026, 11, 13, 8);
  const reading = LifeState(
    activity: LifeActivity.reading,
    location: LifeLocation.home,
    energy: 72,
    mood: LifeMood.calm,
    presence: LifePresence.available,
    focus: 80,
  );
  LifeEngine service({
    String owner = 'owner',
    Duration threshold = const Duration(minutes: 5),
    LifeRuleSelector? selector,
  }) => LifeEngine.forOwner(
    ownerId: owner,
    db: db,
    clock: clock,
    ruleSelector: selector ?? (_, _, _) => reading,
    gapThreshold: threshold,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('life-engine-');
    db = await SqliteDatabase.open(
      '${directory.path}/life.sqlite',
      migrations: _migrations,
    );
    clock = FakeClock(start);
    for (final id in ['owner', 'other', 'admin', 'ai', 'other_ai']) {
      final isAi = id == 'ai' || id == 'other_ai';
      await db.execute(
        '''INSERT INTO account
(id,display_name,kind,is_admin,disabled,password_hash,failed_passwords,locked_until)
VALUES (?,?,?,?,0,?,0,0)''',
        [id, id, isAi ? 'ai' : 'human', id == 'admin' ? 1 : 0,
          isAi ? null : 'fixture'],
      );
    }
    await db.execute("INSERT INTO ai_operator VALUES ('ai','owner')");
    await db.execute("INSERT INTO ai_operator VALUES ('other_ai','other')");
    await db.execute("INSERT INTO ai_profile VALUES ('profile','ai')");
    await db.execute("INSERT INTO ai_profile VALUES ('other_profile','other_ai')");
    engine = service();
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test('60 second cadence records a current rule event with a durable S1 id', () async {
    expect((await engine.recentActivity(ai)).value, isEmpty);
    final first = (await engine.tick(ai)).value!;
    expect(first.id, isNotEmpty);
    expect(first.kind, LifeRecordKind.activity);
    expect(first.at, start);
    expect(first.state!.activity, LifeActivity.reading);
    expect(first.state!.energy, 72);
    expect(first.state!.focus, 80);
    clock.advance(const Duration(seconds: 59, milliseconds: 999));
    expect((await engine.tick(ai)).value, isNull);
    clock.advance(const Duration(milliseconds: 1));
    final second = (await engine.tick(ai)).value!;
    expect(second.at, start.add(const Duration(seconds: 60)));
    expect(second.id, isNot(first.id));
    expect((await engine.tick(ai)).value, isNull);
    expect((await engine.recentActivity(ai)).value.map((r) => r.id),
      [second.id, first.id]);
    expect(await db.schemaVersion(), 602);
  });

  test('polling updates the durable heartbeat without postponing rule cadence', () async {
    engine = service(threshold: const Duration(seconds: 60));
    await engine.tick(ai);
    clock.advance(const Duration(seconds: 40));
    expect((await engine.tick(ai)).value, isNull);
    clock.advance(const Duration(seconds: 20));
    expect((await engine.tick(ai)).value!.kind, LifeRecordKind.activity);
    expect((await engine.recentActivity(ai)).value.length, 2);
  });

  test('gap threshold is explicit, at least 60 seconds, and exact 60 is a tick', () async {
    expect(() => service(threshold: const Duration(seconds: 59)), throwsArgumentError);
    engine = service(threshold: const Duration(seconds: 60));
    await engine.tick(ai);
    clock.advance(const Duration(seconds: 60));
    expect((await engine.tick(ai)).value!.kind, LifeRecordKind.activity);
    clock.advance(const Duration(seconds: 60, microseconds: 1));
    final gap = (await engine.tick(ai)).value!;
    expect(gap.kind, LifeRecordKind.gap);
    expect(gap.state, isNull);
    expect(gap.gapStart, start.add(const Duration(seconds: 60)));
  });

  test('restart persists cadence and writes one gap without missed activities', () async {
    await engine.tick(ai);
    clock.advance(const Duration(seconds: 30));
    await db.close();
    db = await SqliteDatabase.open('${directory.path}/life.sqlite', migrations: _migrations);
    engine = service();
    expect((await engine.tick(ai)).value, isNull);
    clock.advance(const Duration(hours: 3));
    await db.close();
    db = await SqliteDatabase.open('${directory.path}/life.sqlite', migrations: _migrations);
    engine = service(selector: (_, _, _) => throw StateError('No offline selection'));
    final gap = (await engine.tick(ai)).value!;
    expect(gap.kind, LifeRecordKind.gap);
    expect(gap.gapStart, start.add(const Duration(seconds: 30)));
    expect(gap.at, clock.now());
    expect((await engine.tick(ai)).value, isNull);
    engine = service();
    expect((await engine.tick(ai)).value, isNull);
    clock.advance(const Duration(seconds: 59));
    expect((await engine.tick(ai)).value, isNull);
    clock.advance(const Duration(seconds: 1));
    expect((await engine.tick(ai)).value!.kind, LifeRecordKind.activity);
    final records = (await engine.recentActivity(ai)).value;
    expect(records.map((r) => r.kind),
      [LifeRecordKind.activity, LifeRecordKind.gap, LifeRecordKind.activity]);
    expect(records.where((r) => r.kind == LifeRecordKind.activity).length, 2);
  });

  test('concurrent engines sharing the database record one tick and one gap', () async {
    final engines = List.generate(12, (_) => service());
    var results = await Future.wait(engines.map((e) => e.tick(ai)));
    expect(results.where((r) => r.value != null).length, 1);
    clock.advance(const Duration(hours: 1));
    results = await Future.wait(engines.map((e) => e.tick(ai)));
    expect(results.where((r) => r.value != null).single.value!.kind, LifeRecordKind.gap);
    expect((await engine.recentActivity(ai)).value.length, 2);
  });

  test('current canonical owner scopes reads and writes including after transfer', () async {
    await engine.tick(ai);
    for (final owner in ['other', 'admin', 'ai']) {
      expect((await service(owner: owner).tick(ai)).failureOrNull?.code, FailureCode.notFound);
      expect((await service(owner: owner).recentActivity(ai)).failureOrNull?.code, FailureCode.notFound);
    }
    expect((await engine.tick(otherAi)).failureOrNull?.code, FailureCode.notFound);
    expect((await engine.recentActivity(AiId.parse('missing'))).failureOrNull?.code, FailureCode.notFound);
    await db.execute("UPDATE ai_operator SET operator_id='other' WHERE ai_id='ai'");
    expect((await engine.tick(ai)).failureOrNull?.code, FailureCode.notFound);
    expect((await engine.recentActivity(ai)).failureOrNull?.code, FailureCode.notFound);
    expect((await service(owner: 'other').recentActivity(ai)).value, isEmpty);
    expect((await service(owner: 'other').tick(ai)).value!.kind, LifeRecordKind.activity);
    expect((await service(owner: 'other').recentActivity(ai)).value.length, 1);
    expect((await db.query('SELECT id FROM activity_log')).length, 2);
  });

  test('disabled AI or disabled human operator cannot select, tick or read', () async {
    await engine.tick(ai);
    for (final id in ['ai', 'owner']) {
      await db.execute('UPDATE account SET disabled=1 WHERE id=?', [id]);
      final guarded = service(selector: (_, _, _) => throw StateError('Unauthorized selection'));
      expect((await guarded.tick(ai)).failureOrNull?.code, FailureCode.notFound);
      expect((await guarded.recentActivity(ai)).failureOrNull?.code, FailureCode.notFound);
      await db.execute('UPDATE account SET disabled=0 WHERE id=?', [id]);
    }
    expect((await db.query('SELECT id FROM activity_log')).length, 1);
  });

  test('trusted synchronous rule updates state with no model or proactive dependencies', () async {
    engine = service(selector: (selectedAi, now, previous) {
      if (previous == null) return reading;
      return const LifeState(
        activity: LifeActivity.wateringPlants,
        location: LifeLocation.neighborhood,
        energy: 65,
        mood: LifeMood.happy,
        presence: LifePresence.busy,
        focus: 45,
      );
    });
    await engine.tick(ai);
    clock.advance(const Duration(seconds: 60));
    final event = (await engine.tick(ai)).value!;
    expect(event.state!.activity, LifeActivity.wateringPlants);
    expect(event.state!.location, LifeLocation.neighborhood);
    expect(event.state!.mood, LifeMood.happy);
    expect(event.state!.presence, LifePresence.busy);
    expect((await engine.recentActivity(ai)).value.first.id, event.id);
    // A real DB containing only identity/life schemas is sufficient: no models,
    // budget, scheduler, memory, messages or network service exists in this test.
    expect(await db.integrityCheck(), 'ok');
  });

  test('recent reads are bounded, deterministic, immutable and isolated by AI', () async {
    await engine.tick(ai);
    clock.advance(const Duration(seconds: 60));
    final latest = (await engine.tick(ai)).value!;
    await service(owner: 'other').tick(otherAi);
    expect((await engine.recentActivity(ai, limit: 1)).value.single.id, latest.id);
    expect((await engine.recentActivity(ai, limit: 0)).failureOrNull?.code, FailureCode.invalidArgument);
    expect((await engine.recentActivity(ai, limit: 101)).failureOrNull?.code, FailureCode.invalidArgument);
    final records = (await engine.recentActivity(ai)).value;
    expect(() => records.clear(), throwsUnsupportedError);
    expect(records.length, 2);
  });

  test('clock rollback cannot duplicate an event or corrupt the recovery anchor', () async {
    await engine.tick(ai);
    clock.set(start.subtract(const Duration(hours: 2)));
    expect((await engine.tick(ai)).value, isNull);
    clock.set(start.add(const Duration(seconds: 60)));
    expect((await engine.tick(ai)).value!.kind, LifeRecordKind.activity);
    expect((await engine.recentActivity(ai)).value.length, 2);
  });

  test('SQL rejects unknown enum values in state and activity rows', () async {
    expect(
      () => db.execute(
        '''INSERT INTO life_state
(owner_id,ai_profile_id,last_heartbeat_at,last_activity_at,activity,location,energy,mood,presence,focus)
VALUES (?,?,?,?,?,?,?,?,?,?)''',
        ['owner', 'profile', start.toIso8601String(), start.toIso8601String(),
          'unknown_activity', 'home', 50, 'calm', 'available', 50],
      ),
      throwsA(isA<Object>()),
    );
    expect(
      () => db.execute(
        '''INSERT INTO activity_log
(id,owner_id,ai_profile_id,kind,at,activity,location,energy,mood,presence,focus)
VALUES (?,?,?,?,?,?,?,?,?,?,?)''',
        ['bad', 'owner', 'profile', 'activity', start.toIso8601String(),
          'reading', 'unknown_location', 50, 'calm', 'available', 50],
      ),
      throwsA(isA<Object>()),
    );
  });

  test('rule ArgumentError is returned with a fixed safe message', () async {
    engine = service(selector: (_, _, _) => throw ArgumentError('private selector detail'));
    final result = await engine.tick(ai);
    expect(result.failureOrNull?.code, FailureCode.invalidArgument);
    expect(result.failureOrNull?.message, 'Invalid life state');
  });

  test('invalid rule state rolls back without storing or disclosing rule prose', () async {
    engine = service(selector: (_, _, _) => const LifeState(
      activity: LifeActivity.reading,
      location: LifeLocation.home,
      energy: 101,
      mood: LifeMood.calm,
      presence: LifePresence.available,
      focus: 80,
    ));
    final result = await engine.tick(ai);
    expect(result.failureOrNull?.code, FailureCode.invalidArgument);
    expect(await db.query('SELECT * FROM life_state'), isEmpty);
    expect(await db.query('SELECT * FROM activity_log'), isEmpty);
    expect((await service().tick(ai)).value!.kind, LifeRecordKind.activity);
  });
}
