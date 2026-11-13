import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/accounts/sqlite_accounts.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

class TestPasswords implements PasswordHasher {
  @override
  Future<String> hash(String password) async => secretHash(password);
  @override
  Future<bool> verify(String password, String encoded) async =>
      secretHash(password) == encoded;
}

class PausedPasswords extends TestPasswords {
  final started = Completer<void>();
  final release = Completer<bool>();
  @override
  Future<bool> verify(String password, String encoded) {
    started.complete();
    return release.future;
  }
}

// Real SQL still executes; only a selected write fails to prove rollback.
class FailingDatabase implements Database {
  FailingDatabase(this.inner, this.sqlFragment);
  final Database inner;
  final String sqlFragment;
  @override
  Future<T> transaction<T>(Future<T> Function(Tx) body) =>
      inner.transaction((tx) => body(FailingTx(tx, sqlFragment)));
  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) => inner.query(sql, args);
  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) =>
      inner.execute(sql, args);
  @override
  Future<int> schemaVersion() => inner.schemaVersion();
  @override
  Future<String> integrityCheck() => inner.integrityCheck();
}

class FailingTx implements Tx {
  FailingTx(this.inner, this.fragment);
  final Tx inner;
  final String fragment;
  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) => inner.query(sql, args);
  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) {
    if (sql.contains(fragment)) throw StateError('injected write failure');
    return inner.execute(sql, args);
  }
}

class PausedHashPasswords extends TestPasswords {
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<String> hash(String password) async {
    started.complete();
    await release.future;
    return super.hash(password);
  }
}

void main() {
  late Directory temp;
  late SqliteDatabase db;
  late FakeClock clock;
  late SqliteAccountService accounts;
  late SqliteInviteService invites;
  late SqliteDeviceService devices;
  late AccountId admin;
  Future<void> open() async {
    db = await SqliteDatabase.open(
      '${temp.path}/accounts.db',
      migrations: [...allMigrations, ...accountsMigrations],
    );
    accounts = SqliteAccountService(
      database: db,
      clock: clock,
      passwords: TestPasswords(),
    );
    invites = SqliteInviteService(
      database: db,
      clock: clock,
      passwords: TestPasswords(),
    );
    devices = SqliteDeviceService(database: db, clock: clock);
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sql-accounts-');
    clock = FakeClock(DateTime.utc(2026, 11, 13));
    await open();
    admin = (await accounts.bootstrapAdmin(
      displayName: 'admin',
      password: 'secret',
    )).value;
    accounts = accounts.forActor(admin);
  });
  tearDown(() async {
    await db.close();
    await temp.delete(recursive: true);
  });
  Future<AccountId> human(String name) async =>
      (await accounts.createHuman(displayName: name, password: 'secret')).value;

  test(
    'restart retains credentials, lockouts, ownership and single administrator',
    () async {
      final user = await human("O'Reilly; DROP TABLE account; --");
      final ai =
          (await accounts
                  .forActor(user)
                  .createAi(operator: user, displayName: 'AI'))
              .value;
      final token = (await devices.register(user, deviceName: 'phone')).value;
      for (var i = 0; i < 5; i++) {
        await accounts.login(user, 'wrong');
      }
      await db.close();
      await open();
      accounts = accounts.forActor(admin);
      expect(
        (await accounts.bootstrapAdmin(
          displayName: 'second',
          password: 'x',
        )).failureOrNull?.code,
        FailureCode.conflict,
      );
      expect(
        (await accounts.login(user, 'secret')).failureOrNull?.code,
        FailureCode.rateLimited,
      );
      expect(await accounts.isOperatorOf(user, ai), isTrue);
      expect(await devices.authenticate(token.accessToken), isNotNull);
      clock.advance(const Duration(minutes: 15));
      expect((await accounts.login(user, 'secret')).isOk, isTrue);
      final row = (await db.query(
        'SELECT password_hash FROM account WHERE id = ?',
        [user.value],
      )).single;
      expect(row['password_hash'], isNot('secret'));
      final tokens = await db.query('SELECT token_hash FROM refresh_token');
      expect(tokens.single['token_hash'], isNot(token.refreshToken));
      expect((await accounts.metadata()).value, hasLength(3));
    },
  );

  test(
    'independent databases and owners isolate accounts and device revocation',
    () async {
      final user = await human('owner');
      final other = await human('other');
      final ai =
          (await accounts
                  .forActor(user)
                  .createAi(operator: user, displayName: 'AI'))
              .value;
      expect(
        (await accounts.forActor(other).disable(ai)).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await accounts
                .forActor(other)
                .createHuman(displayName: 'bad', password: 'x'))
            .isErr,
        isTrue,
      );
      expect(
        (await accounts.forActor(other).resetPassword(user, 'new')).isErr,
        isTrue,
      );
      final token = (await devices.register(user, deviceName: 'phone')).value;
      expect(
        (await devices.revoke(other, token.deviceId)).failureOrNull?.code,
        FailureCode.notFound,
      );
      final isolated = await SqliteDatabase.open(
        ':memory:',
        migrations: [...allMigrations, ...accountsMigrations],
      );
      try {
        final service = SqliteAccountService(
          database: isolated,
          clock: clock,
          passwords: TestPasswords(),
        );
        expect((await service.login(user, 'secret')).isErr, isTrue);
      } finally {
        await isolated.close();
      }
      expect((await accounts.forActor(user).disable(ai)).isOk, isTrue);
      await accounts.disable(user);
      expect(await devices.authenticate(token.accessToken), isNull);
      expect((await devices.refresh(token.refreshToken)).isErr, isTrue);
      expect((await accounts.forActor(user).disable(ai)).isErr, isTrue);
    },
  );

  test(
    'invite redemption is single use under contention and rollback preserves use',
    () async {
      final code = (await invites.issue(
        expiresAt: clock.now().add(const Duration(days: 1)),
      )).value;
      final failing = SqliteInviteService(
        database: FailingDatabase(db, 'INSERT INTO account'),
        clock: clock,
        passwords: TestPasswords(),
      );
      await expectLater(
        failing.redeem(code, displayName: 'fail', password: 'secret'),
        throwsStateError,
      );
      final results = await Future.wait(
        List.generate(
          12,
          (_) =>
              invites.redeem(code, displayName: 'member', password: 'secret'),
        ),
      );
      expect(results.where((r) => r.isOk), hasLength(1));
      expect((await accounts.metadata()).value, hasLength(2));
      final expired = (await invites.issue(
        expiresAt: clock.now().add(const Duration(seconds: 1)),
      )).value;
      clock.advance(const Duration(seconds: 1));
      expect(
        (await invites.redeem(
          expired,
          displayName: 'bad',
          password: 'x',
        )).isErr,
        isTrue,
      );
      final revoked = (await invites.issue(
        expiresAt: clock.now().add(const Duration(days: 1)),
      )).value;
      final id =
          (await db.query('SELECT id FROM invite WHERE code_hash = ?', [
                secretHash(revoked),
              ])).single['id']
              as String;
      await invites.revoke(id);
      expect(
        (await invites.redeem(
          revoked,
          displayName: 'bad',
          password: 'x',
        )).isErr,
        isTrue,
      );
    },
  );

  test(
    'refresh rotation has one winner and LRU keeps two recently used devices',
    () async {
      final first = (await devices.register(admin, deviceName: 'first')).value;
      clock.advance(const Duration(seconds: 1));
      final second = (await devices.register(
        admin,
        deviceName: 'second',
      )).value;
      clock.advance(const Duration(seconds: 1));
      await devices.authenticate(first.accessToken);
      clock.advance(const Duration(seconds: 1));
      await devices.register(admin, deviceName: 'third');
      expect(await devices.authenticate(second.accessToken), isNull);
      expect(await devices.list(admin), hasLength(2));
      final results = await Future.wait(
        List.generate(8, (_) => devices.refresh(first.refreshToken)),
      );
      expect(results.where((r) => r.isOk), hasLength(1));
      expect(await devices.authenticate(first.accessToken), isNull);
      expect(
        await devices.authenticate(
          results.singleWhere((r) => r.isOk).value.accessToken,
        ),
        isNotNull,
      );
    },
  );

  test(
    'failed revocation rolls back disable and failed rotation preserves old tokens',
    () async {
      final token = (await devices.register(admin, deviceName: 'phone')).value;
      final failingAccounts = SqliteAccountService(
        database: FailingDatabase(db, 'UPDATE device'),
        clock: clock,
        passwords: TestPasswords(),
      ).forActor(admin);
      await expectLater(failingAccounts.disable(admin), throwsStateError);
      expect((await accounts.login(admin, 'secret')).isOk, isTrue);
      final failingDevices = SqliteDeviceService(
        database: FailingDatabase(db, 'INSERT INTO refresh_token'),
        clock: clock,
      );
      await expectLater(
        failingDevices.refresh(token.refreshToken),
        throwsStateError,
      );
      expect(await devices.authenticate(token.accessToken), isNotNull);
      expect((await devices.refresh(token.refreshToken)).isOk, isTrue);
    },
  );

  test(
    'KDF runs outside transactions and reset invalidates pending verification',
    () async {
      final paused = PausedPasswords();
      final slow = SqliteAccountService(
        database: db,
        clock: clock,
        passwords: paused,
      );
      final login = slow.login(admin, 'secret');
      await paused.started.future;
      // This would deadlock if verify held the database transaction.
      expect((await accounts.resetPassword(admin, 'new')).isOk, isTrue);
      paused.release.complete(true);
      expect((await login).failureOrNull?.code, FailureCode.unauthenticated);
      expect((await accounts.login(admin, 'new')).isOk, isTrue);
    },
  );
}
