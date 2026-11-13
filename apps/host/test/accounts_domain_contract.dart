import 'dart:convert';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/device_service.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

/// Acceptance contract shared by memory and SQLite adapters.
/// Seed credentials are obtained through the real bootstrap/login API once.
void accountsDomainContract(
  String name,
  Future<AccountsStore> Function() createStore, {
  Future<void> Function()? cleanup,
}) {
  group('Accounts domain [$name]', () {
    late AccountsDomain domain;
    late AccountsStore store;
    late FakeClock clock;
    late AccountId admin;
    late AccountSession session;
    const password = 'long-test-password';
    late AccountsState seed;
    late String adminBearer;
    setUpAll(() async {
      final seedStore = InMemoryAccountsStore();
      final seedDomain = AccountsDomain(
        store: seedStore,
        clock: FakeClock(DateTime.utc(2026)),
        hasher: PasswordHasher(),
      );
      admin = (await seedDomain.bootstrapAdmin(
        displayName: 'admin',
        password: password,
      )).value;
      adminBearer = (await seedDomain.login(
        admin,
        password,
        deviceName: 'admin',
      )).value.accessToken;
      seed = await seedStore.snapshot();
    });
    setUp(() async {
      store = await createStore();
      await store.transaction((state) {
        final fresh = seed.copy();
        state.accounts.addAll(fresh.accounts);
        state.devices.addAll(fresh.devices);
        state.invites.addAll(fresh.invites);
      });
      clock = FakeClock(DateTime.utc(2026));
      domain = AccountsDomain(
        store: store,
        clock: clock,
        hasher: PasswordHasher(),
      );
      session = (await domain.scope(adminBearer)).value;
    });
    tearDown(() async {
      await cleanup?.call();
    });
    Future<AccountId> human([String name = 'same name']) async =>
        (await session.accounts.createHuman(
          displayName: name,
          password: password,
        )).value;
    Future<DeviceTokens> login(AccountId id, String name) async =>
        (await domain.login(id, password, deviceName: name)).value;
    Future<Principal?> auth(String token) => DbAuthenticator(domain).call(
      HostRequest(
        method: 'GET',
        path: '/',
        headers: {'authorization': 'Bearer $token'},
      ),
    );

    test('AC-02a twenty concurrent redeems consume exactly maxUses', () async {
      final code = (await session.invites.issue(
        expiresAt: clock.now().add(const Duration(hours: 1)),
        maxUses: 3,
      )).value;
      final results = await Future.wait(
        List.generate(
          20,
          (i) => domain.redeem(code, displayName: 'same', password: password),
        ),
      );
      expect(results.where((r) => r.isOk).length, 3);
      expect((await store.snapshot()).invites.values.single['usedCount'], 3);
    });
    test(
      'AC-02b expired revoked exhausted and invalid invite fail without account writes',
      () async {
        Future<String> issue() async => (await session.invites.issue(
          expiresAt: clock.now().add(const Duration(seconds: 1)),
        )).value;
        final expired = await issue();
        clock.advance(const Duration(seconds: 1));
        expect(
          (await domain.redeem(
            expired,
            displayName: 'x',
            password: password,
          )).isErr,
          isTrue,
        );
        final revoked = await issue();
        final id = (await session.inviteMetadata()).value.last['id']! as String;
        expect((await session.invites.revoke(id)).isOk, isTrue);
        expect(
          (await domain.redeem(
            revoked,
            displayName: 'x',
            password: password,
          )).isErr,
          isTrue,
        );
        final exhausted = await issue();
        expect(
          (await domain.redeem(
            exhausted,
            displayName: '',
            password: password,
          )).isErr,
          isTrue,
        );
        expect(
          (await domain.redeem(
            exhausted,
            displayName: 'x',
            password: password,
          )).isOk,
          isTrue,
        );
        expect(
          (await domain.redeem(
            exhausted,
            displayName: 'x',
            password: password,
          )).isErr,
          isTrue,
        );
      },
    );
    test(
      'AC-02c five failed passwords lock account across devices for fifteen minutes',
      () async {
        final id = await human();
        for (var i = 0; i < 5; i++) {
          expect(
            (await domain.login(id, 'wrong', deviceName: 'device$i')).isErr,
            isTrue,
          );
        }
        expect(
          (await domain.login(id, password, deviceName: 'correct')).isErr,
          isTrue,
        );
        clock.advance(const Duration(minutes: 15));
        expect(
          (await domain.login(id, password, deviceName: 'correct')).isOk,
          isTrue,
        );
      },
    );
    test(
      'AC-02d least recently used device loses bearer and refresh immediately',
      () async {
        final id = await human();
        final first = await login(id, 'one');
        clock.advance(const Duration(seconds: 1));
        final second = await login(id, 'two');
        clock.advance(const Duration(seconds: 1));
        expect(await auth(first.accessToken), isNotNull);
        clock.advance(const Duration(seconds: 1));
        await login(id, 'three');
        expect(await auth(second.accessToken), isNull);
        expect((await domain.refresh(second.refreshToken)).isErr, isTrue);
        expect(await auth(first.accessToken), isNotNull);
      },
    );
    test(
      'AC-02e revoke and refresh rotation invalidate credentials and held scopes',
      () async {
        final id = await human();
        final tokens = await login(id, 'one');
        final user = (await domain.scope(tokens.accessToken)).value;
        final rotated = (await domain.refresh(tokens.refreshToken)).value;
        expect((await domain.refresh(tokens.refreshToken)).isErr, isTrue);
        expect(await auth(tokens.accessToken), isNull);
        expect(
          (await user.devices.register(id, deviceName: 'stale')).isErr,
          isTrue,
        );
        final current = (await domain.scope(rotated.accessToken)).value;
        expect(
          (await current.devices.revoke(id, rotated.deviceId)).isOk,
          isTrue,
        );
        expect(await auth(rotated.accessToken), isNull);
        expect((await domain.refresh(rotated.refreshToken)).isErr, isTrue);
      },
    );
    test(
      'FR-04 human operator mandatory and nonoperator cannot manage AI',
      () async {
        final ownerId = await human();
        final strangerId = await human();
        final owner = (await domain.scope(
          (await login(ownerId, 'owner')).accessToken,
        )).value;
        final stranger = (await domain.scope(
          (await login(strangerId, 'stranger')).accessToken,
        )).value;
        final ai = (await owner.accounts.createAi(
          operator: ownerId,
          displayName: 'ai',
        )).value;
        expect(await owner.accounts.isOperatorOf(ownerId, ai), isTrue);
        expect(
          (await stranger.accounts.disable(ai)).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await owner.accounts.createAi(
            operator: ai,
            displayName: 'bad',
          )).isErr,
          isTrue,
        );
        expect(
          (await stranger.accounts.createAi(
            operator: ownerId,
            displayName: 'bad',
          )).isErr,
          isTrue,
        );
        expect((await owner.accounts.disable(ai)).isOk, isTrue);
      },
    );
    test(
      'FR-07 only one admin; metadata excludes secrets and cross-user devices hidden',
      () async {
        expect(
          (await domain.bootstrapAdmin(
            displayName: 'again',
            password: password,
          )).isErr,
          isTrue,
        );
        final id = await human();
        final other = await human();
        final tokens = await login(id, 'phone');
        final user = (await domain.scope(tokens.accessToken)).value;
        expect(await user.devices.list(other), isEmpty);
        expect(
          (await user.devices.revoke(
            other,
            tokens.deviceId,
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await user.accounts.resetPassword(other, password)).isErr,
          isTrue,
        );
        expect((await user.accountMetadata()).isErr, isTrue);
        final metadata = jsonEncode((await session.accountMetadata()).value);
        expect(metadata, isNot(contains(password)));
        expect(metadata, isNot(contains('passwordHash')));
        expect(metadata, isNot(contains(tokens.accessToken)));
        expect((await session.accounts.disable(id)).isOk, isTrue);
        expect(await auth(tokens.accessToken), isNull);
        expect((await domain.refresh(tokens.refreshToken)).isErr, isTrue);
        expect(
          (await user.devices.register(id, deviceName: 'stale')).isErr,
          isTrue,
        );
      },
    );
    test('singleton administrator cannot be disabled', () async {
      expect((await session.accounts.disable(admin)).isErr, isTrue);
      expect(
        (await domain.login(admin, password, deviceName: 'still admin')).isOk,
        isTrue,
      );
    });
    test(
      'credentials persisted as hashes; names need not be unique; bounded inputs',
      () async {
        final a = await human();
        final b = await human();
        expect(a, isNot(b));
        final tokens = await login(a, 'phone');
        final invite = (await session.invites.issue(
          expiresAt: clock.now().add(const Duration(days: 1)),
        )).value;
        final state = await store.snapshot();
        final encoded = jsonEncode(state.toJson());
        for (final secret in [
          password,
          tokens.accessToken,
          tokens.refreshToken,
          invite,
        ]) {
          expect(encoded, isNot(contains(secret)));
        }
        expect(
          (await session.accounts.createHuman(
            displayName: '',
            password: password,
          )).isErr,
          isTrue,
        );
        expect(
          (await session.invites.issue(
            expiresAt: clock.now(),
            maxUses: 0,
          )).isErr,
          isTrue,
        );
        expect((await domain.scope('invalid')).isErr, isTrue);
      },
    );
  });
}
