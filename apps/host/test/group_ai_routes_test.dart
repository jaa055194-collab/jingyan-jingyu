import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/audit/audit_log.dart';
import 'package:jingyu_host/src/models/usage_meter.dart';
import 'package:jingyu_host/src/social/group_ai_migrations.dart';
import 'package:jingyu_host/src/social/group_ai_policy.dart';
import 'package:jingyu_host/src/social/group_ai_routes.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _FastHasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String password) async => 'test:$password';

  @override
  Future<bool> verifyAsync(String password, String encodedHash) async =>
      encodedHash == 'test:$password';
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AccountsDomain accounts;
  late FakeClock clock;
  late InMemoryAuditLog audit;
  late Pipeline pipeline;
  late Map<String, AccountId> ids;
  late Map<String, String> tokens;
  const password = 'test-password-long';

  Pipeline mounted(Authenticator authenticate) {
    final router = Router();
    mountGroupAiRoutes(
      router,
      db: db,
      clock: clock,
      accounts: accounts,
      audit: audit,
    );
    return Pipeline(router: router, authenticate: authenticate);
  }

  Future<HostResponse> send(
    String method,
    String route, {
    String actor = 'owner',
    String group = 'g',
    String target = 'ai',
    Object? body,
    String? bearer,
    Pipeline? through,
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: method,
      path: route
          .replaceFirst('{conversationId}', group)
          .replaceFirst('{accountId}', ids[target]?.value ?? target),
      headers: {'authorization': 'Bearer ${bearer ?? tokens[actor]}'},
      body: body,
    ),
  );

  Future<HostResponse> configure([Map<String, Object?>? body]) =>
      send('PUT', Routes.groupAiSettings, body: body ?? {'dailyCap': 10});

  GroupAiPolicy postingPolicy(String ai) => GroupAiPolicy(
    actorId: ids[ai]!,
    database: db,
    clock: clock,
    budgetDay: (clock) => BudgetDay.fromClock(clock, offsetMinutes: 480),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('group-ai-routes-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...socialMigrations,
        groupAiMigration,
      ],
    );
    clock = FakeClock(DateTime.utc(2026, 11, 13, 12));
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    ids = {};
    tokens = {};
    ids['admin'] = (await accounts.bootstrapAdmin(
      displayName: 'Admin',
      password: password,
    )).value;
    tokens['admin'] = (await accounts.login(
      ids['admin']!,
      password,
      deviceName: 'admin device',
    )).value.accessToken;
    final admin = (await accounts.scope(tokens['admin']!)).value;
    for (final name in ['owner', 'operator', 'outsider']) {
      ids[name] = (await admin.accounts.createHuman(
        displayName: name,
        password: password,
      )).value;
      tokens[name] = (await accounts.login(
        ids[name]!,
        password,
        deviceName: '$name device',
      )).value.accessToken;
    }
    final operator = (await accounts.scope(tokens['operator']!)).value;
    ids['ai'] = (await operator.accounts.createAi(
      operator: ids['operator']!,
      displayName: 'AI',
    )).value;
    ids['otherAi'] = (await admin.accounts.createAi(
      operator: ids['admin']!,
      displayName: 'Other AI',
    )).value;
    await db.execute(
      "INSERT INTO social_conversations VALUES ('g', ?, 'Group', 'all', 0)",
      [ids['owner']!.value],
    );
    for (final name in ['owner', 'admin', 'ai', 'otherAi']) {
      await db.execute("INSERT INTO social_members VALUES ('g', ?, 0, 1)", [
        ids[name]!.value,
      ]);
    }
    audit = InMemoryAuditLog();
    pipeline = mounted(DbAuthenticator(accounts).call);
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'unconfigured is closed and defaults persist without admitting posts',
    () async {
      expect((await send('GET', Routes.groupAiSettings)).status, 404);
      expect((await configure()).status, 200);
      final response = await send(
        'GET',
        Routes.groupAiSettings,
        actor: 'admin',
      );
      expect(response.status, 200);
      expect(response.json, {
        'dailyCap': 10,
        'minIntervalSeconds': 30,
        'maxPerRound': 1,
        'autonomousInterjection': false,
        'interjectionGapSeconds': 600,
        'hosting': false,
      });
      expect(
        (await postingPolicy('ai').mayPost(
          ConversationId.parse('g'),
          roundId: 'r1',
          mentioned: false,
        )).failureOrNull?.code,
        FailureCode.forbidden,
      );
      expect(await db.query('SELECT * FROM group_ai_admissions'), isEmpty);
      expect(
        (await send('GET', Routes.groupAiSettings, actor: 'operator')).status,
        404,
      );
      expect(
        (await send('GET', Routes.groupAiSettings, actor: 'outsider')).status,
        404,
      );
      expect(
        (await send('GET', Routes.groupAiSettings, group: 'missing')).status,
        404,
      );
    },
  );

  test(
    'only group owner sets shared settings and mute with no admin override',
    () async {
      for (final actor in ['admin', 'operator', 'outsider']) {
        expect(
          (await send(
            'PUT',
            Routes.groupAiSettings,
            actor: actor,
            body: {'dailyCap': 5},
          )).status,
          403,
        );
      }
      expect((await configure()).status, 200);
      for (final actor in ['admin', 'operator', 'outsider']) {
        expect(
          (await send(
            'PUT',
            Routes.groupAiMute,
            actor: actor,
            body: {'muted': true},
          )).status,
          403,
        );
      }
      expect(
        (await send('PUT', Routes.groupAiMute, body: {'muted': true})).status,
        200,
      );
      expect(
        (await postingPolicy('ai').mayPost(
          ConversationId.parse('g'),
          roundId: 'r1',
          mentioned: true,
        )).failureOrNull?.code,
        FailureCode.forbidden,
      );
      expect(
        (await send('PUT', Routes.groupAiMute, body: {'muted': false})).status,
        200,
      );
      expect(
        (await postingPolicy('ai').mayPost(
          ConversationId.parse('g'),
          roundId: 'r1',
          mentioned: true,
        )).isOk,
        isTrue,
      );
      expect(
        (await send(
          'PUT',
          Routes.groupAiMute,
          target: 'owner',
          body: {'muted': true},
        )).status,
        404,
      );
      expect(
        (await send(
          'PUT',
          Routes.groupAiMute,
          target: 'missing',
          body: {'muted': true},
        )).status,
        404,
      );
    },
  );

  test(
    'canonical AI operator alone controls interval and GET keeps shared baseline',
    () async {
      expect((await configure()).status, 200);
      for (final actor in ['owner', 'admin', 'outsider']) {
        expect(
          (await send(
            'PUT',
            Routes.groupAiInterval,
            actor: actor,
            body: {'seconds': 0},
          )).status,
          403,
        );
      }
      expect(
        (await send(
          'PUT',
          Routes.groupAiInterval,
          actor: 'operator',
          body: {'seconds': 0},
        )).status,
        200,
      );
      expect(
        (await send(
          'PUT',
          Routes.groupAiInterval,
          actor: 'operator',
          target: 'otherAi',
          body: {'seconds': 0},
        )).status,
        403,
      );
      expect((await configure({'dailyCap': 2, 'maxPerRound': 2})).status, 200);
      expect(
        ((await send('GET', Routes.groupAiSettings)).json
            as Map<String, Object?>)['minIntervalSeconds'],
        30,
      );
      final group = ConversationId.parse('g');
      expect(
        (await postingPolicy(
          'ai',
        ).tryConsumePost(group, roundId: 'r1', mentioned: true)).isOk,
        isTrue,
      );
      expect(
        (await postingPolicy(
          'ai',
        ).tryConsumePost(group, roundId: 'r1', mentioned: true)).isOk,
        isTrue,
      );
      expect(
        (await postingPolicy(
          'otherAi',
        ).mayPost(group, roundId: 'r2', mentioned: true)).failureOrNull?.code,
        FailureCode.rateLimited,
      );
      expect((await db.query('SELECT * FROM group_ai_admissions')).length, 2);
    },
  );

  test(
    'hosting enables autonomous and switching it off disables autonomous',
    () async {
      expect((await configure({'dailyCap': 8, 'hosting': true})).status, 200);
      expect(
        ((await send('GET', Routes.groupAiSettings)).json
            as Map<String, Object?>)['autonomousInterjection'],
        isTrue,
      );
      expect(
        (await postingPolicy('ai').mayPost(
          ConversationId.parse('g'),
          roundId: 'r1',
          mentioned: false,
        )).isOk,
        isTrue,
      );
      expect(
        (await configure({
          'dailyCap': 8,
          'hosting': false,
          'autonomousInterjection': true,
        })).status,
        200,
      );
      final settings =
          (await send('GET', Routes.groupAiSettings)).json
              as Map<String, Object?>;
      expect(settings['hosting'], isFalse);
      expect(settings['autonomousInterjection'], isFalse);
      expect(await db.query('SELECT * FROM group_ai_admissions'), isEmpty);
    },
  );

  test(
    'settings PUT replaces omitted optionals with constructor defaults',
    () async {
      expect(
        (await configure({
          'dailyCap': 8,
          'maxPerRound': 4,
          'autonomousInterjection': true,
          'interjectionGapSeconds': 0,
        })).status,
        200,
      );
      expect((await configure({'dailyCap': 0})).status, 200);
      expect((await send('GET', Routes.groupAiSettings)).json, {
        'dailyCap': 0,
        'minIntervalSeconds': 30,
        'maxPerRound': 1,
        'autonomousInterjection': false,
        'interjectionGapSeconds': 600,
        'hosting': false,
      });
    },
  );

  test(
    'strict bodies reject unknown keys wrong types and negative values without writes',
    () async {
      for (final body in <Object?>[
        null,
        [],
        'not json',
        {},
        {'dailyCap': null},
        {'dailyCap': -1},
        {'dailyCap': 1.0},
        {'dailyCap': true},
        {'dailyCap': '1'},
        {'dailyCap': 1, 'maxPerRound': 0},
        {'dailyCap': 1, 'maxPerRound': 1.5},
        {'dailyCap': 1, 'hosting': 1},
        {'dailyCap': 1, 'hosting': null},
        {'dailyCap': 1, 'autonomousInterjection': 'false'},
        {'dailyCap': 1, 'interjectionGapSeconds': -1},
        {'dailyCap': 1, 'interjectionGapSeconds': 1.5},
        {'dailyCap': 1, 'minInterval': 0},
        {'dailyCap': 1, 'minIntervalSeconds': 30},
        {'dailyCap': 1, 'actorId': 'owner'},
      ]) {
        expect(
          (await send('PUT', Routes.groupAiSettings, body: body)).status,
          400,
          reason: '$body',
        );
      }
      expect(await db.query('SELECT * FROM group_ai_settings'), isEmpty);
      expect(audit.entries, isEmpty);
      expect((await configure()).status, 200);
      for (final body in <Object?>[
        null,
        [],
        {},
        {'seconds': -1},
        {'seconds': 1.5},
        {'seconds': '0'},
        {'seconds': null},
        {'seconds': 0, 'actorId': 'operator'},
      ]) {
        expect(
          (await send(
            'PUT',
            Routes.groupAiInterval,
            actor: 'operator',
            body: body,
          )).status,
          400,
          reason: '$body',
        );
      }
      for (final body in <Object?>[
        null,
        [],
        {},
        {'muted': 1},
        {'muted': 'true'},
        {'muted': null},
        {'muted': true, 'actorId': 'owner'},
      ]) {
        expect(
          (await send('PUT', Routes.groupAiMute, body: body)).status,
          400,
          reason: '$body',
        );
      }
      expect((await send('GET', Routes.groupAiSettings, body: {})).status, 400);
      expect(
        (await send('GET', Routes.groupAiSettings, group: 'bad id')).status,
        400,
      );
      expect(
        (await send(
          'PUT',
          Routes.groupAiMute,
          target: 'bad id',
          body: {'muted': true},
        )).status,
        400,
      );
      expect(
        (await send(
          'PUT',
          Routes.groupAiInterval,
          target: 'bad id',
          actor: 'operator',
          body: {'seconds': 0},
        )).status,
        400,
      );
      expect(await db.query('SELECT * FROM group_ai_intervals'), isEmpty);
      expect(await db.query('SELECT * FROM group_ai_mutes'), isEmpty);
      expect(audit.entries.length, 1);
    },
  );

  for (final seconds in [
    288230376151711744, // 2^58 wraps Duration microseconds to zero.
    -288230376151711744,
    9223372036855,
    -9223372036854,
    -9223372036855,
  ]) {
    test(
      'settings rejects unsafe duration seconds $seconds before writes',
      () async {
        expect(
          (await configure({
            'dailyCap': 10,
            'interjectionGapSeconds': seconds,
          })).status,
          400,
        );
        expect(await db.query('SELECT * FROM group_ai_settings'), isEmpty);
        expect(audit.entries, isEmpty);
      },
    );

    test(
      'interval rejects unsafe duration seconds $seconds before writes',
      () async {
        expect((await configure()).status, 200);
        expect(
          (await send(
            'PUT',
            Routes.groupAiInterval,
            actor: 'operator',
            body: {'seconds': seconds},
          )).status,
          400,
        );
        expect(await db.query('SELECT * FROM group_ai_intervals'), isEmpty);
        expect(audit.entries.length, 1);
      },
    );
  }

  test(
    'duration endpoints preserve zero and maximum safe seconds exactly',
    () async {
      for (final (seconds, milliseconds) in [
        (0, 0),
        (9223372036854, 9223372036854000),
      ]) {
        expect(
          (await configure({
            'dailyCap': 10,
            'interjectionGapSeconds': seconds,
          })).status,
          200,
        );
        expect(
          (await db.query(
            'SELECT interjection_gap_ms FROM group_ai_settings',
          )).single['interjection_gap_ms'],
          milliseconds,
        );
        expect(
          ((await send('GET', Routes.groupAiSettings)).json
              as Map<String, Object?>)['interjectionGapSeconds'],
          seconds,
        );
        expect(
          (await send(
            'PUT',
            Routes.groupAiInterval,
            actor: 'operator',
            body: {'seconds': seconds},
          )).status,
          200,
        );
        expect(
          (await db.query(
            'SELECT min_interval_ms FROM group_ai_intervals',
          )).single['min_interval_ms'],
          milliseconds,
        );
      }
      expect(await db.query('SELECT * FROM group_ai_admissions'), isEmpty);
    },
  );

  test(
    'every route revalidates bearer against exact principal account and device',
    () async {
      final ownerPrincipal = (await accounts.authenticate(tokens['owner']!))!;
      final stale = mounted((_) async => ownerPrincipal);
      final second = (await accounts.login(
        ids['owner']!,
        password,
        deviceName: 'second',
      )).value;
      final cases = [
        ('GET', Routes.groupAiSettings, null),
        ('PUT', Routes.groupAiSettings, <String, Object?>{'dailyCap': 1}),
        ('PUT', Routes.groupAiInterval, <String, Object?>{'seconds': 0}),
        ('PUT', Routes.groupAiMute, <String, Object?>{'muted': true}),
      ];
      for (final bearer in [tokens['admin']!, second.accessToken, 'invalid']) {
        for (final (method, route, body) in cases) {
          expect(
            (await send(
              method,
              route,
              body: body,
              bearer: bearer,
              through: stale,
            )).status,
            401,
          );
        }
      }
      final current = (await accounts.scope(tokens['owner']!)).value;
      expect(
        (await current.devices.revoke(
          ids['owner']!,
          DeviceId.parse(ownerPrincipal.deviceId),
        )).isOk,
        isTrue,
      );
      for (final (method, route, body) in cases) {
        expect(
          (await send(method, route, body: body, through: stale)).status,
          401,
        );
      }
      expect(await db.query('SELECT * FROM group_ai_settings'), isEmpty);
      expect(audit.entries, isEmpty);
    },
  );

  test(
    'audit includes only safe settings and target AI metadata on success',
    () async {
      expect((await configure()).status, 200);
      expect(
        (await send(
          'PUT',
          Routes.groupAiInterval,
          actor: 'operator',
          body: {'seconds': 7},
        )).status,
        200,
      );
      expect(
        (await send('PUT', Routes.groupAiMute, body: {'muted': true})).status,
        200,
      );
      final entries = await audit.forTarget('conversation', 'g');
      expect(entries.map((e) => e.action), [
        'group.ai.settings.update',
        'group.ai.interval.update',
        'group.ai.mute.update',
      ]);
      expect(entries.map((e) => e.actorId), [
        ids['owner']!.value,
        ids['operator']!.value,
        ids['owner']!.value,
      ]);
      expect(entries[0].meta, {
        'dailyCap': 10,
        'maxPerRound': 1,
        'autonomousInterjection': false,
        'interjectionGapSeconds': 600,
        'hosting': false,
      });
      expect(entries[1].meta, {
        'targetAccountId': ids['ai']!.value,
        'seconds': 7,
      });
      expect(entries[2].meta, {
        'targetAccountId': ids['ai']!.value,
        'muted': true,
      });
      expect((await send('GET', Routes.groupAiSettings)).status, 200);
      expect(audit.entries.length, 3);
      expect(await db.query('SELECT * FROM group_ai_admissions'), isEmpty);
      expect(
        (await send(
          'POST',
          Routes.groupAiSettings,
          body: {'dailyCap': 5},
        )).status,
        404,
      );
    },
  );
}
