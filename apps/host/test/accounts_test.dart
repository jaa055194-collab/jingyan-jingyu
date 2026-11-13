import 'dart:async';
import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/account_service.dart';
import 'package:jingyu_host/src/accounts/accounts_store.dart';
import 'package:jingyu_host/src/accounts/device_service.dart';
import 'package:jingyu_host/src/accounts/invite_service.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:test/test.dart';

// Password work is deliberately replaced only in domain tests. The real KDF
// has its own real 600000-round salt and verification test below.
class FastPasswords implements PasswordHasher {
  @override
  Future<String> hash(String password) async => 'test-hash:$password';
  @override
  Future<bool> verify(String password, String encoded) async =>
      encoded == await hash(password);
}

class DelayedPasswords implements PasswordHasher {
  final Completer<void> started = Completer<void>();
  final Completer<bool> release = Completer<bool>();

  @override
  Future<String> hash(String password) async => 'test-hash:$password';
  @override
  Future<bool> verify(String password, String encoded) {
    if (!started.isCompleted) started.complete();
    return release.future;
  }
}

void main() {
  late InMemoryAccountsStore store;
  late FakeClock clock;
  late DefaultAccountService accounts;
  late AccountId admin;
  late DefaultInviteService invites;
  late DefaultDeviceService devices;

  setUp(() async {
    store = InMemoryAccountsStore();
    clock = FakeClock(DateTime.utc(2026, 11, 13));
    accounts = DefaultAccountService(
      store: store,
      clock: clock,
      passwords: FastPasswords(),
    );
    admin = (await accounts.bootstrapAdmin(
      displayName: 'admin',
      password: 'secret',
    )).value;
    accounts = accounts.forActor(admin);
    invites = DefaultInviteService(
      store: store,
      clock: clock,
      passwords: FastPasswords(),
    );
    devices = DefaultDeviceService(store: store, clock: clock);
  });

  Future<AccountId> human(String name) async =>
      (await accounts.createHuman(displayName: name, password: 'secret')).value;

  test(
    'bootstrap has one administrator even under concurrent attempts',
    () async {
      final results = await Future.wait(
        List.generate(
          20,
          (_) =>
              accounts.bootstrapAdmin(displayName: 'other', password: 'secret'),
        ),
      );
      expect(results.where((r) => r.isOk), isEmpty);
      expect(
        (await accounts.metadata()).value.where((a) => a.isAdmin),
        hasLength(1),
      );
    },
  );

  test(
    'AI requires an enabled human operator and outsiders cannot manage it',
    () async {
      final owner = await human('owner');
      final other = await human('other');
      final ai =
          (await accounts
                  .forActor(owner)
                  .createAi(operator: owner, displayName: 'AI'))
              .value;
      expect(await accounts.isOperatorOf(owner, ai), isTrue);
      expect(
        (await accounts.forActor(other).disable(ai)).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await accounts
                .forActor(owner)
                .createAi(operator: ai, displayName: 'nested'))
            .isErr,
        isTrue,
      );
      expect((await accounts.forActor(owner).disable(ai)).isOk, isTrue);
      expect((await devices.register(ai, deviceName: 'AI')).isErr, isTrue);
    },
  );

  test('only administrator creates humans or resets passwords', () async {
    final user = await human('user');
    final unprivileged = accounts.forActor(user);
    expect(
      (await unprivileged.createHuman(displayName: 'bad', password: 'x')).isErr,
      isTrue,
    );
    expect((await unprivileged.resetPassword(user, 'new')).isErr, isTrue);
    expect((await accounts.resetPassword(user, 'new')).isOk, isTrue);
    expect((await accounts.login(user, 'secret')).isErr, isTrue);
    expect((await accounts.login(user, 'new')).isOk, isTrue);
  });

  test(
    'fifth consecutive failure locks correct passwords for fifteen minutes',
    () async {
      final user = await human('user');
      for (var i = 0; i < 5; i++) {
        expect((await accounts.login(user, 'wrong')).isErr, isTrue);
      }
      expect(
        (await accounts.login(user, 'secret')).failureOrNull?.code,
        FailureCode.rateLimited,
      );
      clock.advance(const Duration(minutes: 15));
      expect((await accounts.login(user, 'secret')).isOk, isTrue);
      for (var i = 0; i < 4; i++) {
        await accounts.login(user, 'wrong');
      }
      expect((await accounts.login(user, 'secret')).isOk, isTrue);
      expect(
        (await accounts.login(user, 'wrong')).failureOrNull?.code,
        FailureCode.unauthenticated,
      );
    },
  );

  test(
    'failed login after lock expiry starts a fresh failure window',
    () async {
      final user = await human('user');
      for (var i = 0; i < 5; i++) {
        await accounts.login(user, 'wrong');
      }
      clock.advance(const Duration(minutes: 15));
      await accounts.login(user, 'wrong');
      expect((await accounts.login(user, 'secret')).isOk, isTrue);
    },
  );

  test(
    'disabled administrators and operators lose management access',
    () async {
      final user = await human('user');
      final ai =
          (await accounts
                  .forActor(user)
                  .createAi(operator: user, displayName: 'AI'))
              .value;
      await accounts.disable(user);
      expect((await accounts.forActor(user).disable(ai)).isErr, isTrue);
      await accounts.disable(admin);
      expect(
        (await accounts.createHuman(displayName: 'bad', password: 'x')).isErr,
        isTrue,
      );
    },
  );

  test(
    'twenty concurrent invite redemptions consume exactly maxUses',
    () async {
      final code = (await invites.issue(
        expiresAt: clock.now().add(const Duration(hours: 1)),
        maxUses: 3,
      )).value;
      expect(base64Url.decode(base64Url.normalize(code)), hasLength(16));
      final results = await Future.wait(
        List.generate(
          20,
          (i) => invites.redeem(code, displayName: 'u$i', password: 'secret'),
        ),
      );
      expect(results.where((r) => r.isOk), hasLength(3));
      final rows = await store.serialized(
        (state) => state.invites.values.toList(),
      );
      expect(rows.single.usedCount, 3);
      expect(rows.single.codeHash, isNot(code));
    },
  );

  test(
    'expired revoked exhausted and invalid invites fail without consumption',
    () async {
      expect(
        (await invites.issue(expiresAt: clock.now(), maxUses: 1)).isErr,
        isTrue,
      );
      expect(
        (await invites.issue(
          expiresAt: clock.now().add(const Duration(hours: 1)),
          maxUses: 0,
        )).isErr,
        isTrue,
      );
      final code = (await invites.issue(
        expiresAt: clock.now().add(const Duration(hours: 1)),
      )).value;
      expect(
        (await invites.redeem(code, displayName: '', password: 'p')).isErr,
        isTrue,
      );
      final id = await store.serialized(
        (state) => state.invites.values.single.id,
      );
      await invites.revoke(id);
      expect(
        (await invites.redeem(code, displayName: 'u', password: 'p')).isErr,
        isTrue,
      );
      final expiring = (await invites.issue(
        expiresAt: clock.now().add(const Duration(seconds: 1)),
      )).value;
      clock.advance(const Duration(seconds: 1));
      expect(
        (await invites.redeem(expiring, displayName: 'u', password: 'p')).isErr,
        isTrue,
      );
    },
  );

  test(
    'third device evicts least recently used and revoke invalidates both tokens',
    () async {
      final user = await human('user');
      final first = (await devices.register(user, deviceName: 'first')).value;
      clock.advance(const Duration(seconds: 1));
      final second = (await devices.register(user, deviceName: 'second')).value;
      clock.advance(const Duration(seconds: 1));
      expect(await devices.authenticate(first.accessToken), isNotNull);
      clock.advance(const Duration(seconds: 1));
      final third = (await devices.register(user, deviceName: 'third')).value;
      expect(await devices.authenticate(second.accessToken), isNull);
      expect((await devices.refresh(second.refreshToken)).isErr, isTrue);
      expect(await devices.list(user), hasLength(2));
      expect(
        (await devices.revoke(admin, third.deviceId)).failureOrNull?.code,
        FailureCode.notFound,
      );
      await devices.revoke(user, third.deviceId);
      expect(await devices.authenticate(third.accessToken), isNull);
      expect((await devices.refresh(third.refreshToken)).isErr, isTrue);
    },
  );

  test(
    'concurrent refresh rotates both tokens exactly once and stores hashes',
    () async {
      final user = await human('user');
      final original = (await devices.register(
        user,
        deviceName: 'phone',
      )).value;
      final refreshed = await Future.wait(
        List.generate(20, (_) => devices.refresh(original.refreshToken)),
      );
      expect(refreshed.where((r) => r.isOk), hasLength(1));
      expect(await devices.authenticate(original.accessToken), isNull);
      final next = refreshed.firstWhere((r) => r.isOk).value;
      expect(await devices.authenticate(next.accessToken), isNotNull);
      final row = await store.serialized(
        (state) => state.devices.values.single,
      );
      expect(row.accessHash, isNot(next.accessToken));
      expect(row.refreshHash, isNot(next.refreshToken));
      await accounts.disable(user);
      expect(await devices.authenticate(next.accessToken), isNull);
      expect((await devices.refresh(next.refreshToken)).isErr, isTrue);
    },
  );

  test('password verification cannot block token authentication', () async {
    final user = await human('user');
    final token = (await devices.register(user, deviceName: 'phone')).value;
    final delayed = DelayedPasswords();
    final loginService = DefaultAccountService(
      store: store,
      clock: clock,
      passwords: delayed,
    );
    final pending = loginService.login(user, 'wrong');
    await delayed.started.future;
    expect(
      await devices
          .authenticate(token.accessToken)
          .timeout(const Duration(seconds: 1)),
      isNotNull,
    );
    delayed.release.complete(false);
    expect((await pending).isErr, isTrue);
  });

  test('concurrent correct login cannot bypass fifth failure lock', () async {
    final user = await human('user');
    for (var i = 0; i < 4; i++) {
      await accounts.login(user, 'wrong');
    }
    final delayed = DelayedPasswords();
    final loginService = DefaultAccountService(
      store: store,
      clock: clock,
      passwords: delayed,
    );
    final correct = loginService.login(user, 'secret');
    await delayed.started.future;
    await accounts.login(user, 'wrong');
    delayed.release.complete(true);
    expect((await correct).failureOrNull?.code, FailureCode.rateLimited);
  });

  test('admin password reset immediately revokes existing sessions', () async {
    final user = await human('user');
    final token = (await devices.register(user, deviceName: 'phone')).value;
    await accounts.resetPassword(user, 'new');
    expect(await devices.authenticate(token.accessToken), isNull);
    expect((await devices.refresh(token.refreshToken)).isErr, isTrue);
  });

  test(
    'real PBKDF2 hashes are salted and verify without storing plaintext',
    () async {
      final hasher = Pbkdf2PasswordHasher();
      var ticked = false;
      final pending = hasher.hash('correct horse');
      Timer.run(() => ticked = true);
      final one = await pending;
      expect(ticked, isTrue);
      final two = await hasher.hash('correct horse');
      expect(one, isNot(two));
      expect(one, isNot(contains('correct horse')));
      expect(one.split('\$')[1], '600000');
      expect(await hasher.verify('correct horse', one), isTrue);
      expect(await hasher.verify('wrong', one), isFalse);
      final salt = base64Url.encode(List<int>.generate(16, (i) => i));
      final key = base64Url.encode([
        59,
        195,
        113,
        24,
        230,
        37,
        9,
        62,
        155,
        121,
        237,
        8,
        147,
        14,
        167,
        175,
        115,
        137,
        89,
        18,
        51,
        253,
        217,
        45,
        221,
        243,
        105,
        55,
        30,
        96,
        219,
        192,
      ]);
      expect(
        await hasher.verify('password', 'pbkdf2-sha256\$600000\$$salt\$$key'),
        isTrue,
      );
      expect(await hasher.verify('x', 'malformed'), isFalse);
      expect(
        () => Pbkdf2PasswordHasher(iterations: 599999),
        throwsArgumentError,
      );
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
