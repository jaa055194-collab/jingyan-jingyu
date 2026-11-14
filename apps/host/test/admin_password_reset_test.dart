@Timeout(Duration(minutes: 10))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_module.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/device_service.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

class _TestHasher extends PasswordHasher {
  int hashes = 0;
  bool block = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<String> hashAsync(String value) async {
    hashes++;
    if (block) {
      entered.complete();
      await release.future;
    }
    return 'fixture:${sha256.convert(utf8.encode(value))}';
  }

  @override
  Future<bool> verifyAsync(String value, String encodedHash) async =>
      encodedHash == 'fixture:${sha256.convert(utf8.encode(value))}';
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AccountsDomain domain;
  late _TestHasher hasher;
  late FakeClock clock;
  late Pipeline pipeline;
  late Router router;
  late Map<String, AccountId> ids;
  late Map<String, DeviceTokens> tokens;
  const original = 'original-password-123';
  const replacement = 'replacement-password-456';

  void mount() {
    router = Router();
    AccountsModule(domain: domain).mount(router);
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(domain).call,
    );
  }

  Future<void> open() async {
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [...allMigrations, ...accountsMigrations],
    );
    domain = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: hasher,
    );
    mount();
  }

  Future<HostResponse> reset({
    String? actor = 'admin',
    String? target,
    Object? body = const {'newPassword': replacement},
    String? bearer,
    Pipeline? through,
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: 'POST',
      // Literal desired route permits a meaningful HTTP-404 RED before mounting.
      path:
          '/api/v1/admin/accounts/${target ?? ids['victim']!.value}/reset-password',
      headers: {
        if (actor != null || bearer != null)
          'authorization': 'Bearer ${bearer ?? tokens[actor]!.accessToken}',
      },
      body: body,
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('admin-reset-http-');
    clock = FakeClock(DateTime.utc(2026, 11, 15));
    hasher = _TestHasher();
    await open();
    ids = {};
    tokens = {};
    ids['admin'] = (await domain.bootstrapAdmin(
      displayName: 'Admin',
      password: original,
    )).value;
    tokens['admin'] = (await domain.login(
      ids['admin']!,
      original,
      deviceName: 'admin',
    )).value;
    final admin = (await domain.scope(tokens['admin']!.accessToken)).value;
    for (final name in ['victim', 'other']) {
      ids[name] = (await admin.accounts.createHuman(
        displayName: name,
        password: original,
      )).value;
      tokens[name] = (await domain.login(
        ids[name]!,
        original,
        deviceName: name,
      )).value;
    }
    ids['ai'] = (await admin.accounts.createAi(
      operator: ids['admin']!,
      displayName: 'AI',
    )).value;
  });

  tearDown(() async {
    if (hasher.block && !hasher.release.isCompleted) hasher.release.complete();
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'HTTP reset clears lockout revokes target devices and persists new password',
    () async {
      final second = (await domain.login(
        ids['victim']!,
        original,
        deviceName: 'victim second',
      )).value;
      for (var i = 0; i < 5; i++) {
        expect(
          (await domain.login(
            ids['victim']!,
            'wrong',
            deviceName: 'bad',
          )).isErr,
          isTrue,
        );
      }
      expect(
        (await domain.login(
          ids['victim']!,
          original,
          deviceName: 'locked',
        )).isErr,
        isTrue,
      );
      final response = await reset();
      expect(response.status, 200);
      expect(response.json, {'reset': true});
      for (final device in [tokens['victim']!, second]) {
        expect(await domain.authenticate(device.accessToken), isNull);
        expect((await domain.refresh(device.refreshToken)).isErr, isTrue);
      }
      expect(
        await domain.authenticate(tokens['admin']!.accessToken),
        isNotNull,
      );
      expect(
        await domain.authenticate(tokens['other']!.accessToken),
        isNotNull,
      );
      final row = (await db.query(
        'SELECT password_hash, failed_passwords, locked_until FROM account WHERE id = ?',
        [ids['victim']!.value],
      )).single;
      expect(row['failed_passwords'], 0);
      expect(row['locked_until'], 0);
      expect(row['password_hash'], isNot(contains(replacement)));
      expect(
        (await domain.login(ids['victim']!, original, deviceName: 'old')).isErr,
        isTrue,
      );
      expect(
        (await domain.login(
          ids['victim']!,
          replacement,
          deviceName: 'new',
        )).isOk,
        isTrue,
      );
      expect(response.encodeBody(), isNot(contains(replacement)));
      await db.close();
      await open();
      expect(
        (await domain.login(
          ids['victim']!,
          replacement,
          deviceName: 'restart',
        )).isOk,
        isTrue,
      );
    },
  );

  test(
    'anonymous and ordinary users cannot reach reset or hash a password',
    () async {
      final before = await domain.store.snapshot();
      final hashes = hasher.hashes;
      expect((await reset(actor: null)).status, 401);
      expect((await reset(actor: 'victim')).status, 403);
      expect(
        jsonEncode((await domain.store.snapshot()).toJson()),
        jsonEncode(before.toJson()),
      );
      expect(hasher.hashes, hashes);
    },
  );

  test(
    'strict body IDs and password policy reject without writes or hashes',
    () async {
      final before = await domain.store.snapshot();
      final hashes = hasher.hashes;
      for (final body in <Object?>[
        null,
        [],
        {},
        {'newPassword': 5},
        {'newPassword': ''},
        {'newPassword': 'short'},
        {'newPassword': 'x' * 1025},
        {'newPassword': replacement, 'accountId': ids['other']!.value},
        {'newPassword': replacement, 'actorId': ids['admin']!.value},
      ]) {
        expect((await reset(body: body)).status, 400);
      }
      expect((await reset(target: 'bad id')).status, 400);
      expect(hasher.hashes, hashes);
      expect(
        jsonEncode((await domain.store.snapshot()).toJson()),
        jsonEncode(before.toJson()),
      );
    },
  );

  test('unknown and AI targets cannot be assigned a password', () async {
    final hashes = hasher.hashes;
    expect((await reset(target: 'missing-account')).status, 404);
    expect((await reset(target: ids['ai']!.value)).status, 404);
    expect(hasher.hashes, hashes);
    expect(
      (await db.query('SELECT password_hash FROM account WHERE id = ?', [
        ids['ai']!.value,
      ])).single['password_hash'],
      isNull,
    );
  });

  test('revoked rotated and expired admin credentials fail closed', () async {
    final old = tokens['admin']!;
    final fresh = (await domain.refresh(old.refreshToken)).value;
    expect((await reset(bearer: old.accessToken)).status, 401);
    final scoped = (await domain.scope(fresh.accessToken)).value;
    await scoped.devices.revoke(ids['admin']!, fresh.deviceId);
    expect((await reset(bearer: fresh.accessToken)).status, 401);
    final relogged = (await domain.login(
      ids['admin']!,
      original,
      deviceName: 'new admin',
    )).value;
    clock.advance(const Duration(days: 366));
    expect((await reset(bearer: relogged.accessToken)).status, 401);
  });

  test(
    'cached admin principal cannot substitute a different bearer or device',
    () async {
      final admin = (await domain.authenticate(tokens['admin']!.accessToken))!;
      final spoofed = Pipeline(
        router: router,
        authenticate: (_) async => admin,
      );
      expect((await reset(actor: 'victim', through: spoofed)).status, 401);
      final wrongDevice = Pipeline(
        router: router,
        authenticate: (_) async => Principal(
          accountId: admin.accountId,
          deviceId: 'wrong-device',
          isAdmin: true,
        ),
      );
      expect((await reset(through: wrongDevice)).status, 401);
    },
  );

  test(
    'admin revocation while hashing prevents the password mutation',
    () async {
      final scoped = (await domain.scope(tokens['admin']!.accessToken)).value;
      final before = (await db.query(
        'SELECT password_hash FROM account WHERE id = ?',
        [ids['victim']!.value],
      )).single['password_hash'];
      hasher.block = true;
      final pending = reset();
      await hasher.entered.future;
      await scoped.devices.revoke(ids['admin']!, tokens['admin']!.deviceId);
      hasher.release.complete();
      expect((await pending).status, 401);
      expect(
        (await db.query('SELECT password_hash FROM account WHERE id = ?', [
          ids['victim']!.value,
        ])).single['password_hash'],
        before,
      );
      expect(
        await domain.authenticate(tokens['victim']!.accessToken),
        isNotNull,
      );
    },
  );

  test('existing password bounds accept 12 and 1024 characters', () async {
    for (final password in ['p' * 12, 'p' * 1024]) {
      final response = await reset(body: {'newPassword': password});
      expect(response.status, 200);
      final hash =
          (await db.query('SELECT password_hash FROM account WHERE id = ?', [
                ids['victim']!.value,
              ])).single['password_hash']
              as String;
      expect(await hasher.verifyAsync(password, hash), isTrue);
    }
  });

  test('resetting a disabled human does not enable it', () async {
    final admin = (await domain.scope(tokens['admin']!.accessToken)).value;
    await admin.accounts.disable(ids['victim']!);
    expect((await reset()).status, 200);
    final row = (await db.query('SELECT disabled FROM account WHERE id = ?', [
      ids['victim']!.value,
    ])).single;
    expect(row['disabled'], 1);
    expect(
      (await domain.login(
        ids['victim']!,
        replacement,
        deviceName: 'still-disabled',
      )).isErr,
      isTrue,
    );
  });

  test(
    'HTTP adapter uses real salted hashing and leaves no plaintext on disk',
    () async {
      final realHasher = PasswordHasher();
      domain = AccountsDomain(
        store: SqlAccountsStore(db),
        clock: clock,
        hasher: realHasher,
      );
      mount();
      final response = await reset();
      expect(response.status, 200);
      expect(response.json, {'reset': true});
      final hash =
          (await db.query('SELECT password_hash FROM account WHERE id = ?', [
                ids['victim']!.value,
              ])).single['password_hash']
              as String;
      expect(hash, startsWith(r'$v1$pbkdf2-sha256$600000$'));
      expect(await realHasher.verifyAsync(replacement, hash), isTrue);
      expect(response.encodeBody(), isNot(contains(hash)));
      for (final suffix in ['', '-wal', '-shm']) {
        final file = File('${directory.path}/host.sqlite$suffix');
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          expect(latin1.decode(bytes), isNot(contains(replacement)));
        }
      }
      expect(
        jsonEncode((await domain.store.snapshot()).toJson()),
        isNot(contains(replacement)),
      );
    },
  );

  test(
    'resetting admin itself retains admin role but requires a new login',
    () async {
      final response = await reset(target: ids['admin']!.value);
      expect(response.status, 200);
      expect(await domain.authenticate(tokens['admin']!.accessToken), isNull);
      final login = await domain.login(
        ids['admin']!,
        replacement,
        deviceName: 'admin new',
      );
      expect(login.isOk, isTrue);
      expect(
        (await domain.authenticate(login.value.accessToken))!.isAdmin,
        isTrue,
      );
    },
  );
}
