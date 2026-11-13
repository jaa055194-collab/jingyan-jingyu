import 'package:jingyu_core/jingyu_core.dart';

import 'accounts_store.dart';
import 'password_hasher.dart';

enum AccountKind { human, ai }

class AccountMetadata {
  const AccountMetadata({
    required this.id,
    required this.kind,
    required this.displayName,
    required this.enabled,
    required this.isAdmin,
    required this.deviceCount,
  });
  final AccountId id;
  final AccountKind kind;
  final String displayName;
  final bool enabled;
  final bool isAdmin;
  final int deviceCount;
}

abstract class AccountService {
  Future<Result<AccountId>> createHuman({
    required String displayName,
    required String password,
  });
  Future<Result<AccountId>> createAi({
    required AccountId operator,
    required String displayName,
  });
  Future<Result<void>> disable(AccountId id);
  Future<Result<void>> resetPassword(AccountId id, String newPassword);
  Future<bool> isOperatorOf(AccountId human, AccountId ai);
}

class DefaultAccountService implements AccountService {
  DefaultAccountService({
    required this.store,
    required this.clock,
    required this.passwords,
    RandomString? newAccountId,
  }) : _newAccountId = newAccountId;
  final AccountsStore store;
  final Clock clock;
  final PasswordHasher passwords;
  final RandomString? _newAccountId;
  AccountId? _actor;
  DefaultAccountService forActor(AccountId id) => DefaultAccountService(
    store: store,
    clock: clock,
    passwords: passwords,
    newAccountId: _newAccountId,
  ).._actor = id;
  bool _admin(AccountsState s) =>
      s.accounts[_actor?.value]?.isAdmin == true &&
      s.accounts[_actor?.value]?.enabled == true;
  AccountId _id(AccountsState s) =>
      AccountId.parse(_newAccountId?.call() ?? s.nextId('a'));

  Future<Result<AccountId>> bootstrapAdmin({
    required String displayName,
    required String password,
  }) async {
    if (displayName.trim().isEmpty || password.isEmpty) {
      return err(FailureCode.invalidArgument, 'invalid account');
    }
    final passwordHash = await passwords.hash(password);
    return store.serialized((s) {
      if (s.accounts.values.any((a) => a.isAdmin)) {
        return err(FailureCode.conflict, 'admin already initialized');
      }
      if (displayName.trim().isEmpty || password.isEmpty) {
        return err(FailureCode.invalidArgument, 'invalid account');
      }
      final id = _id(s);
      s.accounts[id.value] = AccountRecord(
        id: id,
        kind: AccountKind.human,
        displayName: displayName,
        passwordHash: passwordHash,
        isAdmin: true,
      );
      return Ok(id);
    });
  }

  @override
  Future<Result<AccountId>> createHuman({
    required String displayName,
    required String password,
  }) async {
    if (displayName.trim().isEmpty || password.isEmpty) {
      return err(FailureCode.invalidArgument, 'invalid account');
    }
    if (!await store.serialized(_admin)) {
      return err(FailureCode.forbidden, 'admin required');
    }
    final passwordHash = await passwords.hash(password);
    return store.serialized((s) {
      if (!_admin(s)) return err(FailureCode.forbidden, 'admin required');
      if (displayName.trim().isEmpty || password.isEmpty) {
        return err(FailureCode.invalidArgument, 'invalid account');
      }
      final id = _id(s);
      s.accounts[id.value] = AccountRecord(
        id: id,
        kind: AccountKind.human,
        displayName: displayName,
        passwordHash: passwordHash,
      );
      return Ok(id);
    });
  }

  @override
  Future<Result<AccountId>> createAi({
    required AccountId operator,
    required String displayName,
  }) => store.serialized((s) async {
    final owner = s.accounts[operator.value];
    if (_actor != operator ||
        owner == null ||
        owner.kind != AccountKind.human ||
        !owner.enabled ||
        displayName.trim().isEmpty) {
      return err(FailureCode.forbidden, 'human operator required');
    }
    final id = _id(s);
    s.accounts[id.value] = AccountRecord(
      id: id,
      kind: AccountKind.ai,
      displayName: displayName,
      passwordHash: '',
    );
    s.operators[id.value] = operator;
    return Ok(id);
  });

  @override
  Future<Result<void>> disable(AccountId id) => store.serialized((s) async {
    final account = s.accounts[id.value];
    if (account == null) return err(FailureCode.notFound, 'account not found');
    if (!_admin(s) &&
        (s.operators[id.value] != _actor ||
            s.accounts[_actor?.value]?.enabled != true)) {
      return err(FailureCode.notFound, 'account not found');
    }
    account.enabled = false;
    for (final d in s.devices.values.where((d) => d.account == id)) {
      d.revokedAt = clock.now();
    }
    return const Ok(null);
  });

  @override
  Future<Result<void>> resetPassword(AccountId id, String newPassword) async {
    if (newPassword.isEmpty) {
      return err(FailureCode.invalidArgument, 'invalid password');
    }
    if (!await store.serialized(_admin)) {
      return err(FailureCode.forbidden, 'admin required');
    }
    final passwordHash = await passwords.hash(newPassword);
    return store.serialized((s) {
      if (!_admin(s)) return err(FailureCode.forbidden, 'admin required');
      final account = s.accounts[id.value];
      if (account == null || account.kind != AccountKind.human) {
        return err(FailureCode.notFound, 'account not found');
      }
      if (newPassword.isEmpty) {
        return err(FailureCode.invalidArgument, 'invalid password');
      }
      account.passwordHash = passwordHash;
      for (final d in s.devices.values.where((d) => d.account == id)) {
        d.revokedAt = clock.now();
      }
      account.failedLogins = 0;
      account.lockedUntil = null;
      return const Ok(null);
    });
  }

  @override
  Future<bool> isOperatorOf(AccountId human, AccountId ai) async =>
      store.serialized((s) => s.operators[ai.value] == human);

  Future<Result<AccountId>> login(AccountId id, String password) async {
    final snapshot = await store.serialized((s) {
      final account = s.accounts[id.value];
      if (account == null ||
          account.kind != AccountKind.human ||
          !account.enabled) {
        return err<String>(FailureCode.unauthenticated, 'invalid credentials');
      }
      if (account.lockedUntil != null &&
          clock.now().isBefore(account.lockedUntil!)) {
        return err<String>(FailureCode.rateLimited, 'account locked');
      }
      return Ok(account.passwordHash);
    });
    if (snapshot.isErr) return Err(snapshot.failureOrNull!);
    final hash = snapshot.value;
    final valid = await passwords.verify(password, hash);
    return store.serialized((s) {
      final account = s.accounts[id.value];
      if (account == null || !account.enabled || account.passwordHash != hash) {
        return err(FailureCode.unauthenticated, 'credentials changed');
      }
      final now = clock.now();
      if (account.lockedUntil != null && now.isBefore(account.lockedUntil!)) {
        return err(FailureCode.rateLimited, 'account locked');
      }
      if (account.lockedUntil != null) {
        account.failedLogins = 0;
        account.lockedUntil = null;
      }
      if (!valid) {
        account.failedLogins++;
        if (account.failedLogins >= 5) {
          account.lockedUntil = now.add(const Duration(minutes: 15));
        }
        return err(FailureCode.unauthenticated, 'invalid credentials');
      }
      account.failedLogins = 0;
      account.lockedUntil = null;
      return Ok(id);
    });
  }

  Future<Result<List<AccountMetadata>>> metadata() => store.serialized((s) {
    if (!_admin(s)) return err(FailureCode.forbidden, 'admin required');
    return Ok(
      s.accounts.values
          .map(
            (a) => AccountMetadata(
              id: a.id,
              kind: a.kind,
              displayName: a.displayName,
              enabled: a.enabled,
              isAdmin: a.isAdmin,
              deviceCount: s.devices.values
                  .where((d) => d.account == a.id && d.revokedAt == null)
                  .length,
            ),
          )
          .toList(),
    );
  });
}

typedef RandomString = String Function();
