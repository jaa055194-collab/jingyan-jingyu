import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/device_service.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/audit/admin_audit_module.dart';
import 'package:jingyu_host/src/audit/admin_audit_reader.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

class _Hasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String value) async =>
      'fixture:${sha256.convert(utf8.encode(value))}';
  @override
  Future<bool> verifyAsync(String value, String hash) async =>
      hash == 'fixture:${sha256.convert(utf8.encode(value))}';
}

class _TxOnly implements Database {
  _TxOnly(this.inner, {this.revokeDevice});
  final Database inner;
  final String? revokeDevice;
  final queries = <String>[];
  @override
  Future<T> transaction<T>(Future<T> Function(Tx tx) body) =>
      inner.transaction((tx) async {
        if (revokeDevice != null) {
          await tx.execute('DELETE FROM refresh_token WHERE device_id=?', [
            revokeDevice,
          ]);
          await tx.execute('DELETE FROM device WHERE id=?', [revokeDevice]);
        }
        return body(_ReadTx(tx, queries));
      });
  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) => throw StateError('Outer query forbidden');
  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) =>
      throw StateError('Outer write forbidden');
  @override
  Future<int> schemaVersion() => throw StateError('Unexpected schema read');
  @override
  Future<String> integrityCheck() =>
      throw StateError('Unexpected integrity read');
}

class _ReadTx implements Tx {
  _ReadTx(this.inner, this.queries);
  final Tx inner;
  final List<String> queries;
  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) {
    queries.add(sql);
    return inner.query(sql, args);
  }

  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) =>
      throw StateError('Reader wrote data');
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late FakeClock clock;
  late AccountsDomain accounts;
  late Map<String, AccountId> ids;
  late Map<String, DeviceTokens> tokens;
  late Router router;
  late Pipeline pipeline;
  const password = 'audit-metadata-fixture';

  Future<void> open() async {
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [...allMigrations, ...accountsMigrations],
    );
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _Hasher(),
    );
    router = Router();
    AdminAuditModule(
      reader: AdminAuditReader(database: db, clock: clock),
    ).mount(router);
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(accounts).call,
    );
  }

  Future<void> audit(
    int id, {
    String at = '2026-11-15T00:00:00Z',
    String meta = '{}',
  }) async {
    await db.execute(
      'INSERT INTO audit_log(id,at,actor_id,action,target_kind,target_id,meta) VALUES(?,?,?,?,?,?,?)',
      [id, at, 'actor-$id', 'message.edit', 'message', 'target-$id', meta],
    );
  }

  Future<HostResponse> read({
    Map<String, String> query = const {},
    String actor = 'admin',
    bool anonymous = false,
    String? bearer,
    Pipeline? through,
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: 'GET',
      path: '/api/v1/admin/audit',
      query: query,
      headers: {
        if (!anonymous)
          'authorization': 'Bearer ${bearer ?? tokens[actor]!.accessToken}',
      },
    ),
  );
  Map<String, Object?> json(HostResponse response) {
    expect(response.status, 200, reason: response.encodeBody());
    return (response.json as Map).cast<String, Object?>();
  }

  List<Map<String, Object?>> entries(Map<String, Object?> value) =>
      (value['entries'] as List).cast<Map<String, Object?>>();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('admin-audit-read-');
    clock = FakeClock(DateTime.utc(2026, 11, 15));
    await open();
    ids = {};
    tokens = {};
    ids['admin'] = (await accounts.bootstrapAdmin(
      displayName: 'Admin',
      password: password,
    )).value;
    tokens['admin'] = (await accounts.login(
      ids['admin']!,
      password,
      deviceName: 'admin',
    )).value;
    final session = (await accounts.scope(tokens['admin']!.accessToken)).value;
    ids['human'] = (await session.accounts.createHuman(
      displayName: 'Human',
      password: password,
    )).value;
    tokens['human'] = (await accounts.login(
      ids['human']!,
      password,
      deviceName: 'human',
    )).value;
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'empty page and sparse pagination use last returned id not lookahead',
    () async {
      expect(json(await read()), {
        'entries': [],
        'nextAfterId': '0',
        'hasMore': false,
      });
      await audit(2, at: '2026-11-15T10:00:00Z');
      await audit(9, at: '2020-01-01T00:00:00Z');
      await audit(12);
      final first = json(await read(query: {'limit': '2'}));
      expect(entries(first).map((r) => r['id']), ['2', '9']);
      expect(first['nextAfterId'], '9');
      expect(first['hasMore'], true);
      final second = json(await read(query: {'afterId': '9', 'limit': '2'}));
      expect(entries(second).map((r) => r['id']), ['12']);
      expect(second['nextAfterId'], '12');
      expect(second['hasMore'], false);
      expect(json(await read(query: {'afterId': '12'})), {
        'entries': [],
        'nextAfterId': '12',
        'hasMore': false,
      });
    },
  );

  test(
    'envelope allowlist never selects or decodes meta including malformed private data',
    () async {
      await audit(1, meta: 'NOT JSON private-message api-key password');
      final result = json(await read());
      final entry = entries(result).single;
      expect(entry.keys.toSet(), {
        'id',
        'at',
        'actorId',
        'action',
        'targetKind',
        'targetId',
      });
      expect(entry['actorId'], 'actor-1');
      expect(entry['targetId'], 'target-1');
      final encoded = jsonEncode(result);
      for (final secret in [
        'private-message',
        'api-key',
        'password',
        'NOT JSON',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
      final before = jsonEncode(await db.query('SELECT * FROM audit_log'));
      await read();
      expect(jsonEncode(await db.query('SELECT * FROM audit_log')), before);
    },
  );

  test(
    'IDs above browser precision and SQLite max remain exact strings',
    () async {
      await audit(9007199254740993);
      await audit(9223372036854775807);
      final result = json(await read(query: {'afterId': '9007199254740992'}));
      expect(entries(result).map((r) => r['id']), [
        '9007199254740993',
        '9223372036854775807',
      ]);
      expect(result['nextAfterId'], '9223372036854775807');
      expect(
        entries(json(await read(query: {'afterId': '9223372036854775807'}))),
        isEmpty,
      );
    },
  );

  test(
    'invalid cursor limit and query controls fail without reading or modifying audit',
    () async {
      await audit(1);
      final before = jsonEncode(await db.query('SELECT * FROM audit_log'));
      for (final value in [
        '-1',
        '+1',
        '01',
        ' 1',
        '1.0',
        '1e2',
        '0x10',
        '9223372036854775808',
        '1 OR 1=1',
        '9' * 200,
      ]) {
        expect(
          (await read(query: {'afterId': value})).status,
          400,
          reason: value,
        );
      }
      for (final value in [
        '0',
        '101',
        '-1',
        '01',
        '1.0',
        'many',
        '999999999999999999999',
      ]) {
        expect(
          (await read(query: {'limit': value})).status,
          400,
          reason: value,
        );
      }
      expect((await read(query: {'targetId': 'x'})).status, 400);
      expect(jsonEncode(await db.query('SELECT * FROM audit_log')), before);
    },
  );

  test(
    'defaults and hard cap bound returned rows with one lookahead',
    () async {
      for (var i = 1; i <= 101; i++) {
        await audit(i);
      }
      final defaults = json(await read());
      expect(entries(defaults), hasLength(50));
      expect(defaults['nextAfterId'], '50');
      expect(defaults['hasMore'], true);
      final maximum = json(await read(query: {'limit': '100'}));
      expect(entries(maximum), hasLength(100));
      expect(maximum['nextAfterId'], '100');
      expect(maximum['hasMore'], true);
    },
  );

  test(
    'anonymous nonadmin and forged cached principal fail canonical authorization',
    () async {
      await audit(1);
      expect((await read(anonymous: true)).status, 401);
      expect((await read(actor: 'human')).status, 403);
      final principal = (await accounts.authenticate(
        tokens['admin']!.accessToken,
      ))!;
      final forged = Pipeline(
        router: router,
        authenticate: (_) async => principal,
      );
      expect((await read(actor: 'human', through: forged)).status, 401);
      final wrong = Pipeline(
        router: router,
        authenticate: (_) async => Principal(
          accountId: principal.accountId,
          deviceId: 'wrong',
          isAdmin: true,
        ),
      );
      expect((await read(through: wrong)).status, 401);
      final user = (await accounts.authenticate(tokens['human']!.accessToken))!;
      final elevated = Pipeline(
        router: router,
        authenticate: (_) async => Principal(
          accountId: user.accountId,
          deviceId: user.deviceId,
          isAdmin: true,
        ),
      );
      expect((await read(actor: 'human', through: elevated)).status, 403);
    },
  );

  test(
    'revoked rotated expired and disabled canonical administrator cannot read',
    () async {
      final principal = (await accounts.authenticate(
        tokens['admin']!.accessToken,
      ))!;
      final cached = Pipeline(
        router: router,
        authenticate: (_) async => principal,
      );
      final fresh = (await accounts.refresh(
        tokens['admin']!.refreshToken,
      )).value;
      expect((await read(through: cached)).status, 401);
      final session = (await accounts.scope(fresh.accessToken)).value;
      await session.devices.revoke(ids['admin']!, fresh.deviceId);
      expect(
        (await read(bearer: fresh.accessToken, through: cached)).status,
        401,
      );
      final current = (await accounts.login(
        ids['admin']!,
        password,
        deviceName: 'new',
      )).value;
      clock.advance(const Duration(hours: 1));
      expect((await read(bearer: current.accessToken)).status, 401);
    },
  );

  test(
    'cached principal cannot override disabled demoted or missing-refresh canonical state',
    () async {
      await audit(1);
      final principal = (await accounts.authenticate(
        tokens['admin']!.accessToken,
      ))!;
      final cached = Pipeline(
        router: router,
        authenticate: (_) async => principal,
      );
      await db.execute('UPDATE account SET disabled=1 WHERE id=?', [
        ids['admin']!.value,
      ]);
      expect((await read(through: cached)).status, 401);
      await db.execute('UPDATE account SET disabled=0,is_admin=0 WHERE id=?', [
        ids['admin']!.value,
      ]);
      expect((await read(through: cached)).status, 403);
      await db.execute('UPDATE account SET is_admin=1 WHERE id=?', [
        ids['admin']!.value,
      ]);
      await db.execute('DELETE FROM refresh_token WHERE device_id=?', [
        tokens['admin']!.deviceId.value,
      ]);
      expect((await read(through: cached)).status, 401);
    },
  );

  test(
    'expired refresh row does not invalidate still-live access token',
    () async {
      await audit(1);
      await db.execute(
        'UPDATE refresh_token SET expires_at=0 WHERE device_id=?',
        [tokens['admin']!.deviceId.value],
      );
      expect(entries(json(await read())), hasLength(1));
    },
  );

  test(
    'same transaction verifies revocation before the envelope query and uses only bounded SELECT',
    () async {
      await audit(1);
      final scoped = _TxOnly(db);
      final reader = AdminAuditReader(database: scoped, clock: clock);
      final result = await reader.page(
        bearer: tokens['admin']!.accessToken,
        accountId: ids['admin']!.value,
        deviceId: tokens['admin']!.deviceId.value,
        afterId: 0,
        limit: 1,
      );
      expect(result.isOk, true);
      expect(scoped.queries, hasLength(2));
      final auditSql = scoped.queries.last.toLowerCase();
      expect(auditSql, contains('limit ?'));
      expect(auditSql, isNot(contains('meta')));
      expect(auditSql, isNot(contains('select *')));
      final revoked = _TxOnly(
        db,
        revokeDevice: tokens['admin']!.deviceId.value,
      );
      final denial = await AdminAuditReader(database: revoked, clock: clock)
          .page(
            bearer: tokens['admin']!.accessToken,
            accountId: ids['admin']!.value,
            deviceId: tokens['admin']!.deviceId.value,
            afterId: 0,
            limit: 1,
          );
      expect(denial.failureOrNull?.code, FailureCode.unauthenticated);
      expect(revoked.queries, hasLength(1));
    },
  );

  test('metadata survives restart and read performs no audit writes', () async {
    await audit(1);
    final first = json(await read());
    await db.close();
    await open();
    expect(json(await read()), first);
    expect(await db.query('SELECT * FROM audit_log'), hasLength(1));
  });
}
