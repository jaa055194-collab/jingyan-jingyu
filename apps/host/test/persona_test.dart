import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/ai/persona/persona_migrations.dart';
import 'package:jingyu_host/src/ai/persona/persona_service.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

const _migrations = [
  ...allMigrations,
  ...accountsMigrations,
  aiIdentityMigration,
  ...personaMigrations,
];

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late FakeClock clock;
  late SqlitePersonaService owner;
  late SqlitePersonaService ai;
  final profile = AiId.parse('profile');
  PersonaLayers initial() => PersonaLayers(
    p0: {'name': 'Nora', 'boundaries': 'Respect privacy'},
    p1: {'style': 'warm', 'humor': 'gentle'},
    p2: {'mood': 'calm', 'energy': 'rested'},
  );
  SqlitePersonaService service(String scope, String actor) =>
      SqlitePersonaService.forOwner(
        ownerId: scope,
        actorAccountId: actor,
        database: db,
        cipher: cipher,
        clock: clock,
      );
  Future<PersonaCard> initialize() async =>
      (await owner.initialize(profile, initial: initial())).value;
  Future<PersonaChange> iterate({
    int version = 1,
    PersonaDiff? diff,
    String reason = 'Conversation review',
    List<String> evidence = const ['message_1'],
  }) async => (await ai.selfIterate(
    profile,
    diff ?? PersonaDiff(p1: {'style': 'concise'}),
    expectedVersion: version,
    reason: reason,
    evidenceIds: evidence,
  )).value;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('persona-');
    db = await SqliteDatabase.open(
      '${directory.path}/persona.sqlite',
      migrations: _migrations,
    );
    cipher = AesGcmColumnCipher(List.filled(32, 41));
    clock = FakeClock(DateTime.utc(2026, 11, 13, 8));
    for (final id in ['owner', 'other', 'admin', 'ai', 'other_ai']) {
      final isAi = id == 'ai' || id == 'other_ai';
      await db.execute(
        '''INSERT INTO account
(id,display_name,kind,is_admin,disabled,password_hash,failed_passwords,locked_until)
VALUES (?,?,?,?,0,?,0,0)''',
        [
          id,
          id,
          isAi ? 'ai' : 'human',
          id == 'admin' ? 1 : 0,
          isAi ? null : 'fixture',
        ],
      );
    }
    await db.execute("INSERT INTO ai_operator VALUES ('ai','owner')");
    await db.execute("INSERT INTO ai_operator VALUES ('other_ai','other')");
    await db.execute("INSERT INTO ai_profile VALUES ('profile','ai')");
    await db.execute(
      "INSERT INTO ai_profile VALUES ('other_profile','other_ai')",
    );
    owner = service('owner', 'owner');
    ai = service('owner', 'ai');
  });

  tearDown(() async {
    await db.close();
    cipher.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'bounded history caps defaults and maximum without changing internal history',
    () async {
      await initialize();
      for (var version = 1; version <= 101; version++) {
        await iterate(
          version: version,
          diff: PersonaDiff(p2: {'mood': 'mood_$version'}),
        );
      }
      final first = (await owner.historyPage(profile)).value;
      expect(
        first.changes.map((c) => c.version),
        List.generate(50, (i) => i + 1),
      );
      expect(first.nextAfterVersion, 50);
      final hundred = (await owner.historyPage(profile, limit: 100)).value;
      expect(hundred.changes, hasLength(100));
      expect(hundred.nextAfterVersion, 100);
      final last = (await owner.historyPage(
        profile,
        afterVersion: 100,
        limit: 2,
      )).value;
      expect(last.changes.map((c) => c.version), [101, 102]);
      expect(last.nextAfterVersion, null);
      expect((await owner.history(profile)).value, hasLength(102));
      expect(() => first.changes.clear(), throwsUnsupportedError);
      for (final args in [(-1, 50), (0, 0), (0, 101)]) {
        expect(
          (await owner.historyPage(
            profile,
            afterVersion: args.$1,
            limit: args.$2,
          )).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
      }
    },
  );

  test(
    'FR41 explicit initialization is encrypted and does not happen on read',
    () async {
      expect(
        (await owner.current(profile)).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await owner.history(profile)).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(await db.query('SELECT * FROM persona_cards'), isEmpty);
      final card = await initialize();
      expect(card.version, 1);
      expect(card.locked, isFalse);
      expect(card.layers.p0['name'], 'Nora');
      expect((await ai.current(profile)).value.layers.p1['style'], 'warm');
      final changes = (await owner.history(profile)).value;
      expect(changes.single.kind, PersonaChangeKind.initialize);
      expect(changes.single.before, isNull);
      expect(changes.single.after.p2['mood'], 'calm');
      expect(changes.single.at, clock.now());
      expect(
        (await owner.initialize(
          profile,
          initial: initial(),
        )).failureOrNull?.code,
        FailureCode.conflict,
      );
      for (final table in ['persona_cards', 'persona_history']) {
        final raw = jsonEncode(await db.query('SELECT * FROM $table'));
        for (final plaintext in ['Nora', 'Respect privacy', 'warm', 'calm']) {
          expect(raw, isNot(contains(plaintext)));
        }
      }
      expect(await db.schemaVersion(), 601);
    },
  );

  test(
    'A1 unlocked P0 and P1 iterate without an invented approval step',
    () async {
      await initialize();
      clock.advance(const Duration(minutes: 1));
      final change = await iterate(
        diff: PersonaDiff(p0: {'name': 'Nova'}, p1: {'style': 'concise'}),
      );
      expect(change.version, 2);
      expect(change.kind, PersonaChangeKind.selfIterate);
      expect(change.before!.p0['name'], 'Nora');
      expect(change.after.p0['name'], 'Nova');
      expect(change.after.p1['humor'], 'gentle');
      expect(change.reason, 'Conversation review');
      expect(change.evidenceIds, ['message_1']);
      expect(change.at, clock.now());
      expect((await owner.current(profile)).value.layers.p0['name'], 'Nova');
    },
  );

  test(
    'A1 lock blocks P0 P1 atomically but P2 remains fully autonomous',
    () async {
      await initialize();
      expect(
        (await owner.lock(
          profile,
          locked: true,
          expectedVersion: 1,
        )).value.version,
        2,
      );
      for (final diff in [
        PersonaDiff(p0: {'name': 'blocked'}),
        PersonaDiff(p1: {'style': 'blocked'}),
        PersonaDiff(p1: {'style': 'blocked'}, p2: {'mood': 'blocked'}),
      ]) {
        expect(
          (await ai.selfIterate(
            profile,
            diff,
            expectedVersion: 2,
            reason: 'review',
            evidenceIds: ['e1'],
          )).failureOrNull?.code,
          FailureCode.forbidden,
        );
      }
      expect((await owner.current(profile)).value.layers.p2['mood'], 'calm');
      final p2 = await iterate(
        version: 2,
        diff: PersonaDiff(p2: {'mood': 'happy'}),
      );
      expect(p2.version, 3);
      expect((await owner.current(profile)).value.locked, isTrue);
      expect(p2.after.p2['mood'], 'happy');
      await owner.lock(profile, locked: false, expectedVersion: 3);
      expect((await iterate(version: 4)).version, 5);
      expect((await owner.history(profile)).value.length, 5);
    },
  );

  test('owner edit works while locked and versions are never reused', () async {
    await initialize();
    await owner.lock(profile, locked: true, expectedVersion: 1);
    final change = (await owner.edit(
      profile,
      PersonaDiff(p0: {'name': 'Owner choice'}),
      expectedVersion: 2,
      reason: 'Manual correction',
    )).value;
    expect(change.kind, PersonaChangeKind.edit);
    expect(change.version, 3);
    expect(change.after.p0['name'], 'Owner choice');
    expect((await owner.current(profile)).value.locked, isTrue);
  });

  test(
    'only current owner or exact active AI reads; admin has no override',
    () async {
      await initialize();
      for (final reader in [
        service('other', 'other'),
        service('admin', 'admin'),
        service('owner', 'other'),
        service('owner', 'admin'),
        service('owner', 'other_ai'),
        service('other', 'ai'),
      ]) {
        expect(
          (await reader.current(profile)).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await reader.history(profile)).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await reader.initialize(
            profile,
            initial: initial(),
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await reader.edit(
            profile,
            PersonaDiff(p0: {'name': 'stolen'}),
            expectedVersion: 1,
            reason: 'attack',
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await reader.lock(
            profile,
            locked: true,
            expectedVersion: 1,
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await reader.revert(
            profile,
            'missing',
            expectedVersion: 1,
            reason: 'attack',
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await reader.selfIterate(
            profile,
            PersonaDiff(p2: {'mood': 'stolen'}),
            expectedVersion: 1,
            reason: 'attack',
            evidenceIds: ['e1'],
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
      }
      expect(
        (await owner.current(AiId.parse('other_profile'))).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await owner.current(AiId.parse('ai'))).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect((await owner.current(profile)).value.version, 1);
    },
  );

  test(
    'AI cannot initialize lock edit revert and human cannot impersonate self iteration',
    () async {
      expect(
        (await ai.initialize(profile, initial: initial())).failureOrNull?.code,
        FailureCode.forbidden,
      );
      await initialize();
      expect(
        (await ai.lock(
          profile,
          locked: true,
          expectedVersion: 1,
        )).failureOrNull?.code,
        FailureCode.forbidden,
      );
      expect(
        (await ai.edit(
          profile,
          PersonaDiff(p1: {'style': 'x'}),
          expectedVersion: 1,
          reason: 'x',
        )).failureOrNull?.code,
        FailureCode.forbidden,
      );
      final change = await iterate();
      expect(
        (await ai.revert(
          profile,
          change.id,
          expectedVersion: 2,
          reason: 'x',
        )).failureOrNull?.code,
        FailureCode.forbidden,
      );
      expect(
        (await owner.selfIterate(
          profile,
          PersonaDiff(p2: {'mood': 'x'}),
          expectedVersion: 2,
          reason: 'x',
          evidenceIds: ['e1'],
        )).failureOrNull?.code,
        FailureCode.forbidden,
      );
    },
  );

  test(
    'canonical operator revocation and disabled accounts are checked every time',
    () async {
      await initialize();
      for (final id in ['owner', 'ai']) {
        await db.execute('UPDATE account SET disabled=1 WHERE id=?', [id]);
        expect(
          (await owner.current(profile)).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await ai.current(profile)).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await owner.lock(
            profile,
            locked: true,
            expectedVersion: 1,
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
        await db.execute('UPDATE account SET disabled=0 WHERE id=?', [id]);
      }
      await db.execute(
        "UPDATE ai_operator SET operator_id='other' WHERE ai_id='ai'",
      );
      expect(
        (await owner.current(profile)).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await ai.current(profile)).failureOrNull?.code,
        FailureCode.notFound,
      );
      // A new operator must not inherit old owner ciphertext or replace its card.
      final transferred = service('other', 'other');
      expect(
        (await transferred.current(profile)).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await transferred.initialize(
          profile,
          initial: initial(),
        )).failureOrNull?.code,
        FailureCode.conflict,
      );
    },
  );

  test(
    'self iteration rejects absent reason evidence and no-op diffs without writing',
    () async {
      await initialize();
      for (final input in [
        (reason: '', evidence: ['e1']),
        (reason: '  ', evidence: ['e1']),
        (reason: 'review', evidence: <String>[]),
        (reason: 'review', evidence: ['']),
        (reason: 'review', evidence: ['bad/id']),
      ]) {
        expect(
          (await ai.selfIterate(
            profile,
            PersonaDiff(p1: {'style': 'new'}),
            expectedVersion: 1,
            reason: input.reason,
            evidenceIds: input.evidence,
          )).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
      }
      for (final diff in [
        PersonaDiff(),
        PersonaDiff(p1: {'style': 'warm'}),
      ]) {
        expect(
          (await ai.selfIterate(
            profile,
            diff,
            expectedVersion: 1,
            reason: 'review',
            evidenceIds: ['e1'],
          )).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
      }
      expect((await owner.current(profile)).value.version, 1);
      expect((await owner.history(profile)).value.length, 1);
    },
  );

  test(
    'initial layers and mutation arguments are validated before any write',
    () async {
      expect(
        (await owner.initialize(
          profile,
          initial: PersonaLayers(
            p0: {},
            p1: {'style': 'warm'},
            p2: {'mood': 'calm'},
          ),
        )).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(await db.query('SELECT * FROM persona_cards'), isEmpty);
      await initialize();
      for (final version in [0, -1]) {
        expect(
          (await owner.edit(
            profile,
            PersonaDiff(p1: {'style': 'new'}),
            expectedVersion: version,
            reason: 'manual',
          )).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
      }
      for (final diff in [
        PersonaDiff(p1: {'': 'invalid'}),
        PersonaDiff(p1: {'style': ' '}),
        PersonaDiff(p0: {'name': null, 'boundaries': null}),
      ]) {
        expect(
          (await owner.edit(
            profile,
            diff,
            expectedVersion: 1,
            reason: 'manual',
          )).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
      }
      expect(
        (await owner.edit(
          profile,
          PersonaDiff(p1: {'style': 'new'}),
          expectedVersion: 1,
          reason: ' ',
        )).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect((await owner.current(profile)).value.version, 1);
    },
  );

  test(
    'CAS rejects stale edits lock self iteration and revert without losing changes',
    () async {
      await initialize();
      final first = await iterate();
      expect(
        (await ai.selfIterate(
          profile,
          PersonaDiff(p2: {'mood': 'stale'}),
          expectedVersion: 1,
          reason: 'review',
          evidenceIds: ['e1'],
        )).failureOrNull?.code,
        FailureCode.conflict,
      );
      expect(
        (await owner.edit(
          profile,
          PersonaDiff(p0: {'name': 'stale'}),
          expectedVersion: 1,
          reason: 'manual',
        )).failureOrNull?.code,
        FailureCode.conflict,
      );
      expect(
        (await owner.lock(
          profile,
          locked: true,
          expectedVersion: 1,
        )).failureOrNull?.code,
        FailureCode.conflict,
      );
      expect(
        (await owner.revert(
          profile,
          first.id,
          expectedVersion: 1,
          reason: 'undo',
        )).failureOrNull?.code,
        FailureCode.conflict,
      );
      final competing = await Future.wait([
        owner.edit(
          profile,
          PersonaDiff(p1: {'style': 'a'}),
          expectedVersion: 2,
          reason: 'a',
        ),
        owner.edit(
          profile,
          PersonaDiff(p1: {'style': 'b'}),
          expectedVersion: 2,
          reason: 'b',
        ),
      ]);
      expect(competing.where((r) => r.isOk).length, 1);
      expect(
        competing
            .where((r) => r.failureOrNull?.code == FailureCode.conflict)
            .length,
        1,
      );
      expect((await owner.current(profile)).value.version, 3);
      expect((await owner.history(profile)).value.map((c) => c.version), [
        1,
        2,
        3,
      ]);
    },
  );

  test(
    'revert restores prior content as a new version and preserves history and lock',
    () async {
      await initialize();
      final change = await iterate(
        diff: PersonaDiff(p1: {'style': 'terse', 'humor': null}),
      );
      final originalHistory = await db.query(
        'SELECT * FROM persona_history ORDER BY version',
      );
      await owner.lock(profile, locked: true, expectedVersion: 2);
      final reverted = (await owner.revert(
        profile,
        change.id,
        expectedVersion: 3,
        reason: 'Restore previous style',
      )).value;
      expect(reverted.version, 4);
      expect(reverted.kind, PersonaChangeKind.revert);
      expect(reverted.revertsChangeId, change.id);
      expect(reverted.after.p1, {'style': 'warm', 'humor': 'gentle'});
      expect((await owner.current(profile)).value.locked, isTrue);
      expect(
        (await db.query(
          'SELECT * FROM persona_history ORDER BY version',
        )).take(2),
        originalHistory,
      );
      final history = (await owner.history(profile)).value;
      expect(history.map((c) => c.version), [1, 2, 3, 4]);
      expect(
        (await owner.revert(
          profile,
          history.first.id,
          expectedVersion: 4,
          reason: 'invalid initial revert',
        )).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(
        (await owner.revert(
          profile,
          'missing',
          expectedVersion: 4,
          reason: 'missing',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
    },
  );

  test('history cannot be updated or deleted even through SQL', () async {
    await initialize();
    await expectLater(
      db.execute("UPDATE persona_history SET actor_id='admin'"),
      throwsException,
    );
    await expectLater(
      db.execute('DELETE FROM persona_history'),
      throwsException,
    );
    expect((await owner.history(profile)).value.length, 1);
  });

  for (final collision in ['id', 'version']) {
    test('history rejects INSERT OR REPLACE on an existing $collision', () async {
      await initialize();
      // Keep recursive triggers off: the migration must enforce its invariant
      // without relying on REPLACE's implicit deletion firing a delete trigger.
      await db.execute('PRAGMA recursive_triggers=OFF');
      final original = await db.query('SELECT * FROM persona_history');
      final replacement = Map<String, Object?>.from(original.single);
      replacement['actor_id'] = 'admin';
      if (collision == 'id') {
        replacement['version'] = 2;
        replacement['kind'] = 'edit';
        replacement['locked_before'] = 0;
      } else {
        replacement['id'] = 'replacement_change';
      }
      final columns = replacement.keys.join(',');
      final placeholders = List.filled(replacement.length, '?').join(',');
      await expectLater(
        db.execute(
          'INSERT OR REPLACE INTO persona_history ($columns) '
          'VALUES ($placeholders)',
          replacement.values.toList(),
        ),
        throwsException,
      );
      expect(await db.query('SELECT * FROM persona_history'), original);
      expect(
        (await owner.history(profile)).value.single.actorAccountId,
        AccountId.parse('owner'),
      );
    });
  }

  test('a history insertion failure rolls back the CAS card write', () async {
    await initialize();
    await db.execute(
      '''CREATE TRIGGER fixture_block_history BEFORE INSERT ON persona_history
BEGIN SELECT RAISE(ABORT, 'fixture failure'); END''',
    );
    await expectLater(
      ai.selfIterate(
        profile,
        PersonaDiff(p1: {'style': 'lost'}),
        expectedVersion: 1,
        reason: 'review',
        evidenceIds: ['e1'],
      ),
      throwsException,
    );
    expect((await owner.current(profile)).value.version, 1);
    expect((await owner.current(profile)).value.layers.p1['style'], 'warm');
    expect((await owner.history(profile)).value.length, 1);
  });

  test('restart retains card history lock and ciphertext AAD', () async {
    await initialize();
    await iterate();
    await owner.lock(profile, locked: true, expectedVersion: 2);
    await db.close();
    db = await SqliteDatabase.open(
      '${directory.path}/persona.sqlite',
      migrations: _migrations,
    );
    owner = service('owner', 'owner');
    ai = service('owner', 'ai');
    final current = (await owner.current(profile)).value;
    expect(current.version, 3);
    expect(current.layers.p1['style'], 'concise');
    expect(current.locked, isTrue);
    expect((await owner.history(profile)).value.map((c) => c.version), [
      1,
      2,
      3,
    ]);
    expect(
      (await ai.selfIterate(
        profile,
        PersonaDiff(p0: {'name': 'blocked'}),
        expectedVersion: 3,
        reason: 'review',
        evidenceIds: ['e1'],
      )).failureOrNull?.code,
      FailureCode.forbidden,
    );
    expect(await db.integrityCheck(), 'ok');
  });

  test('AAD authenticates owner AI version and field independently', () async {
    await initialize();
    await iterate();
    final row = (await db.query('SELECT * FROM persona_cards')).single;
    final encrypted = row['encrypted_card'] as String;
    final aad = jsonEncode(['owner', 'profile', 2, 'card']);
    expect(cipher.decrypt(encrypted, aad: aad).isOk, isTrue);
    for (final wrong in [
      ['other', 'profile', 2, 'card'],
      ['owner', 'other_profile', 2, 'card'],
      ['owner', 'profile', 1, 'card'],
      ['owner', 'profile', 2, 'after'],
    ]) {
      expect(cipher.decrypt(encrypted, aad: jsonEncode(wrong)).isErr, isTrue);
    }
    final change = (await db.query(
      'SELECT * FROM persona_history WHERE version=2',
    )).single;
    for (final field in ['before', 'after', 'diff', 'reason', 'evidence']) {
      final sealed = change['encrypted_$field'] as String;
      expect(
        cipher
            .decrypt(sealed, aad: jsonEncode(['owner', 'profile', 2, field]))
            .isOk,
        isTrue,
      );
      expect(
        cipher
            .decrypt(sealed, aad: jsonEncode(['owner', 'profile', 2, 'card']))
            .isErr,
        isTrue,
      );
    }
  });

  test(
    'card ciphertext cannot be transplanted across owners profiles or versions',
    () async {
      await initialize();
      final old = (await db.query(
        'SELECT encrypted_card FROM persona_cards',
      )).single['encrypted_card'];
      await iterate();
      await db.execute('UPDATE persona_cards SET encrypted_card=?', [old]);
      expect((await owner.current(profile)).isErr, isTrue);
      expect(
        (await owner.lock(profile, locked: true, expectedVersion: 2)).isErr,
        isTrue,
      );
      expect((await owner.history(profile)).value.length, 2);
    },
  );

  test(
    'different profiles under one owner cannot read or revert each other history',
    () async {
      await initialize();
      final change = await iterate();
      await db.execute(
        "UPDATE ai_operator SET operator_id='owner' WHERE ai_id='other_ai'",
      );
      final second = AiId.parse('other_profile');
      await owner.initialize(second, initial: initial());
      expect(
        (await owner.revert(
          second,
          change.id,
          expectedVersion: 1,
          reason: 'cross AI',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      final card = (await db.query(
        'SELECT encrypted_card FROM persona_cards WHERE ai_profile_id=?',
        ['profile'],
      )).single['encrypted_card'];
      await db.execute(
        'UPDATE persona_cards SET encrypted_card=? WHERE ai_profile_id=?',
        [card, 'other_profile'],
      );
      expect((await owner.current(second)).isErr, isTrue);
    },
  );

  test('persona settings and review reasons preserve multiline text', () async {
    final card = (await owner.initialize(
      profile,
      initial: PersonaLayers(
        p0: {'setting': 'Lives by the sea.\nKeeps a journal.'},
        p1: {'style': 'warm'},
        p2: {'mood': 'calm'},
      ),
    )).value;
    expect(card.layers.p0['setting'], 'Lives by the sea.\nKeeps a journal.');
    final change = await iterate(
      diff: PersonaDiff(p1: {'style': 'warm\nand concise'}),
      reason: 'Review:\nConversation remained engaging.',
    );
    expect(change.reason, 'Review:\nConversation remained engaging.');
    expect(
      (await owner.current(profile)).value.layers.p1['style'],
      'warm\nand concise',
    );
    expect(
      (await owner.history(profile)).value.last.reason,
      'Review:\nConversation remained engaging.',
    );
  });

  test('returned layers diffs and evidence are immutable snapshots', () async {
    final source = {'name': 'Nora'};
    final layers = PersonaLayers(
      p0: source,
      p1: {'style': 'warm'},
      p2: {'mood': 'calm'},
    );
    source['name'] = 'tampered';
    await owner.initialize(profile, initial: layers);
    expect((await owner.current(profile)).value.layers.p0['name'], 'Nora');
    final change = await iterate();
    expect(() => change.after.p1['style'] = 'tamper', throwsUnsupportedError);
    expect(() => change.diff.p1['style'] = 'tamper', throwsUnsupportedError);
    expect(() => change.evidenceIds.add('tamper'), throwsUnsupportedError);
    expect((await owner.current(profile)).value.layers.p1['style'], 'concise');
  });
}
