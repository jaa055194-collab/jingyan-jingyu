/// Memory-first accounts domain. Storage and bootstrap are trusted host APIs;
/// callers obtain service authority only by presenting a currently valid bearer.
library;

import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'account_service.dart';
import 'accounts_store.dart';
import 'device_service.dart';
import 'invite_service.dart';
import 'password_hasher.dart';

typedef _Row = Map<String, Object?>;

class AccountsDomain {
  AccountsDomain({
    required this.store,
    required this.clock,
    required this.hasher,
  });
  final AccountsStore store;
  final Clock clock;
  final PasswordHasher hasher;
  final Random _random = Random.secure();
  String _secret() => base64Url
      .encode(List.generate(16, (_) => _random.nextInt(256)))
      .replaceAll('=', '');
  String _hash(String text) => sha256.convert(utf8.encode(text)).toString();
  int get _now => clock.now().toUtc().millisecondsSinceEpoch;
  bool _name(String name) => name.trim().isNotEmpty && name.length <= 100;
  bool _password(String password) =>
      password.length >= 12 && password.length <= 1024;
  Result<T> _missing<T>() => err(FailureCode.notFound, 'Not found');
  Result<T> _invalid<T>() => err(FailureCode.invalidArgument, 'Invalid input');
  Result<T> _unauth<T>() =>
      err(FailureCode.unauthenticated, 'Invalid credentials');
  bool _active(_Row? row) => row != null && row['disabled'] == false;

  Result<AccountId> _create(
    AccountsState s,
    String name,
    String? passwordHash, {
    bool admin = false,
    AccountId? operator,
  }) {
    if (!_name(name)) {
      return _invalid();
    }
    final id = AccountId.parse(_secret());
    s.accounts[id.value] = {
      'id': id.value,
      'displayName': name.trim(),
      'kind': operator == null ? 'human' : 'ai',
      'operator': operator?.value,
      'isAdmin': admin,
      'disabled': false,
      'passwordHash': passwordHash,
      'failedPasswords': 0,
      'lockedUntil': 0,
    };
    return Ok(id);
  }

  /// Explicit trusted initialization; no other path accepts an admin flag.
  Future<Result<AccountId>> bootstrapAdmin({
    required String displayName,
    required String password,
  }) async {
    if (!_name(displayName) || !_password(password)) return _invalid();
    final initialized = await store.transaction(
      (s) => s.accounts.values.any((a) => a['isAdmin'] == true),
    );
    if (initialized) return err(FailureCode.conflict, 'Already initialized');
    final hash = await hasher.hashAsync(password);
    return store.transaction((s) {
      if (s.accounts.values.any((a) => a['isAdmin'] == true)) {
        return err(FailureCode.conflict, 'Already initialized');
      }
      return _create(s, displayName, hash, admin: true);
    });
  }

  Future<Result<DeviceTokens>> login(
    AccountId id,
    String password, {
    required String deviceName,
  }) async {
    if (!_name(deviceName) || password.length > 1024) return _invalid();
    final hash = await store.transaction<String?>((s) {
      final a = s.accounts[id.value];
      if (!_active(a) ||
          a!['kind'] != 'human' ||
          (a['lockedUntil'] as int) > _now) {
        return null;
      }
      return a['passwordHash'] as String;
    });
    if (hash == null) return _unauth();
    final verified = await hasher.verifyAsync(password, hash);
    return store.transaction((s) {
      final a = s.accounts[id.value];
      // Password reset, disable and lockout may occur while the worker runs.
      // Commit against current state; never overwrite counters from a snapshot.
      if (!_active(a) ||
          a!['kind'] != 'human' ||
          a['passwordHash'] != hash ||
          (a['lockedUntil'] as int) > _now) {
        return _unauth();
      }
      if ((a['lockedUntil'] as int) != 0) {
        a['lockedUntil'] = 0;
        a['failedPasswords'] = 0;
      }
      if (!verified) {
        final failures = (a['failedPasswords'] as int) + 1;
        a['failedPasswords'] = failures;
        if (failures >= 5) {
          a['lockedUntil'] = _now + const Duration(minutes: 15).inMilliseconds;
        }
        return _unauth();
      }
      a['failedPasswords'] = 0;
      return Ok(_register(s, id, deviceName));
    });
  }

  _Row? _bearer(AccountsState s, String token, {bool touch = false}) {
    if (token.length != 22) return null;
    final digest = _hash(token);
    for (final d in s.devices.values) {
      if (d['accessHash'] == digest && _active(s.accounts[d['account']])) {
        if ((d['accessExpires'] as int) <= _now) return null;
        if (touch) d['lastUsedAt'] = _now;
        return d;
      }
    }
    return null;
  }

  DeviceTokens _tokens(_Row d) {
    final access = _secret();
    final refresh = _secret();
    d['accessHash'] = _hash(access);
    d['refreshHash'] = _hash(refresh);
    d['accessExpires'] = _now + const Duration(hours: 1).inMilliseconds;
    d['refreshExpires'] = _now + const Duration(days: 30).inMilliseconds;
    d['lastUsedAt'] = _now;
    return DeviceTokens(
      deviceId: DeviceId.parse(d['id'] as String),
      accessToken: access,
      refreshToken: refresh,
    );
  }

  DeviceTokens _register(AccountsState s, AccountId id, String name) {
    final devices =
        s.devices.values.where((d) => d['account'] == id.value).toList()..sort(
          (a, b) => (a['lastUsedAt'] as int).compareTo(b['lastUsedAt'] as int),
        );
    while (devices.length >= 2) {
      s.devices.remove(devices.removeAt(0)['id']);
    }
    final deviceId = _secret();
    final d = <String, Object?>{
      'id': deviceId,
      'account': id.value,
      'deviceName': name.trim(),
    };
    s.devices[deviceId] = d;
    return _tokens(d);
  }

  Result<DeviceTokens> _refresh(
    AccountsState s,
    String refresh, [
    String? account,
  ]) {
    if (refresh.length != 22) return _unauth();
    final hash = _hash(refresh);
    for (final d in s.devices.values) {
      if (d['refreshHash'] == hash &&
          (account == null || d['account'] == account) &&
          _active(s.accounts[d['account']]) &&
          (d['refreshExpires'] as int) > _now) {
        return Ok(_tokens(d));
      }
    }
    return _unauth();
  }

  Future<Result<DeviceTokens>> refresh(String token) =>
      store.transaction((s) => _refresh(s, token));
  Future<Result<AccountSession>> scope(String bearer) => store.transaction(
    (s) => _bearer(s, bearer) == null
        ? _unauth()
        : Ok(AccountSession._(this, bearer)),
  );
  Future<Principal?> authenticate(String bearer) => store.transaction((s) {
    final d = _bearer(s, bearer, touch: true);
    if (d == null) return null;
    final a = s.accounts[d['account']]!;
    return Principal(
      accountId: a['id'] as String,
      deviceId: d['id'] as String,
      isAdmin: a['isAdmin'] == true,
    );
  });

  Future<Result<AccountId>> redeem(
    String code, {
    required String displayName,
    required String password,
  }) async {
    if (code.length != 22 || !_name(displayName) || !_password(password)) {
      return _invalid();
    }
    if (!await store.transaction((s) => _usableInvite(s, code) != null)) {
      return _missing();
    }
    final hash = await hasher.hashAsync(password);
    return store.transaction((s) => _redeem(s, code, displayName, hash));
  }

  _Row? _usableInvite(AccountsState s, String code) {
    final digest = _hash(code);
    for (final invite in s.invites.values) {
      if (invite['codeHash'] == digest &&
          invite['revokedAt'] == null &&
          (invite['expiresAt'] as int) > _now &&
          (invite['usedCount'] as int) < (invite['maxUses'] as int)) {
        return invite;
      }
    }
    return null;
  }

  Result<AccountId> _redeem(
    AccountsState s,
    String code,
    String name,
    String passwordHash,
  ) {
    final invite = _usableInvite(s, code);
    if (invite == null) return _missing();
    final result = _create(s, name, passwordHash);
    if (result.isOk) invite['usedCount'] = (invite['usedCount'] as int) + 1;
    return result;
  }
}

/// Capability tied to a live access credential. Every operation revalidates it.
class AccountSession {
  AccountSession._(this._domain, this._bearer);
  final AccountsDomain _domain;
  final String _bearer;
  AccountService get accounts => _Accounts(this);
  DeviceService get devices => _Devices(this);
  InviteService get invites => _Invites(this);
  Future<Result<T>> _run<T>(Result<T> Function(AccountsState, _Row) action) =>
      _domain.store.transaction((s) {
        final d = _domain._bearer(s, _bearer);
        if (d == null) return _domain._unauth();
        return action(s, s.accounts[d['account']]!);
      });
  bool _admin(_Row a) => a['isAdmin'] == true;
  Future<Result<List<Map<String, Object?>>>> accountMetadata() => _run((s, a) {
    if (!_admin(a)) return _domain._missing();
    return Ok(
      s.accounts.values
          .map(
            (row) => <String, Object?>{
              'id': row['id'],
              'displayName': row['displayName'],
              'kind': row['kind'],
              'disabled': row['disabled'],
              'deviceCount': s.devices.values
                  .where((d) => d['account'] == row['id'])
                  .length,
            },
          )
          .toList(),
    );
  });
  Future<Result<List<Map<String, Object?>>>> inviteMetadata() => _run((s, a) {
    if (!_admin(a)) return _domain._missing();
    return Ok(
      s.invites.values
          .map(
            (i) => <String, Object?>{
              'id': i['id'],
              'expiresAt': i['expiresAt'],
              'maxUses': i['maxUses'],
              'usedCount': i['usedCount'],
              'revokedAt': i['revokedAt'],
            },
          )
          .toList(),
    );
  });
}

class _Accounts implements AccountService {
  _Accounts(this.session);
  final AccountSession session;
  AccountsDomain get d => session._domain;
  @override
  Future<Result<AccountId>> createHuman({
    required String displayName,
    required String password,
  }) async {
    final allowed = await session._run<void>(
      (s, a) => session._admin(a) ? const Ok(null) : d._missing(),
    );
    if (allowed.isErr) return Err(allowed.failureOrNull!);
    if (!d._name(displayName) || !d._password(password)) return d._invalid();
    final hash = await d.hasher.hashAsync(password);
    return session._run(
      (s, a) =>
          session._admin(a) ? d._create(s, displayName, hash) : d._missing(),
    );
  }

  @override
  Future<Result<AccountId>> createAi({
    required AccountId operator,
    required String displayName,
  }) => session._run((s, a) {
    final human = s.accounts[operator.value];
    if (!_canOperate(a, operator) ||
        !d._active(human) ||
        human!['kind'] != 'human') {
      return d._missing();
    }
    return d._create(s, displayName, null, operator: operator);
  });
  bool _canOperate(_Row actor, AccountId operator) =>
      actor['kind'] == 'human' && actor['id'] == operator.value;
  @override
  Future<Result<void>> disable(AccountId id) => session._run((s, a) {
    final target = s.accounts[id.value];
    if (target == null ||
        !(session._admin(a) ||
            (target['kind'] == 'ai' && target['operator'] == a['id']))) {
      return d._missing();
    }
    if (target['isAdmin'] == true) {
      return err(FailureCode.conflict, 'Administrator must remain enabled');
    }
    target['disabled'] = true;
    s.devices.removeWhere((_, device) => device['account'] == id.value);
    return const Ok(null);
  });
  @override
  Future<Result<void>> resetPassword(AccountId id, String newPassword) async {
    final allowed = await session._run<void>((s, a) {
      final target = s.accounts[id.value];
      return session._admin(a) && target != null && target['kind'] == 'human'
          ? const Ok(null)
          : d._missing();
    });
    if (allowed.isErr) return allowed;
    if (!d._password(newPassword)) return d._invalid();
    final hash = await d.hasher.hashAsync(newPassword);
    return session._run((s, a) {
      final target = s.accounts[id.value];
      if (!session._admin(a) || target == null || target['kind'] != 'human') {
        return d._missing();
      }
      target['passwordHash'] = hash;
      target['failedPasswords'] = 0;
      target['lockedUntil'] = 0;
      s.devices.removeWhere((_, device) => device['account'] == id.value);
      return const Ok(null);
    });
  }

  @override
  Future<bool> isOperatorOf(AccountId human, AccountId ai) async {
    final result = await session._run((s, actor) {
      final target = s.accounts[ai.value];
      return Ok(
        actor['id'] == human.value &&
            target?['kind'] == 'ai' &&
            target?['operator'] == human.value &&
            d._active(s.accounts[human.value]),
      );
    });
    return result.valueOrNull ?? false;
  }
}

class _Devices implements DeviceService {
  _Devices(this.session);
  final AccountSession session;
  AccountsDomain get d => session._domain;
  @override
  Future<Result<DeviceTokens>> register(
    AccountId account, {
    required String deviceName,
  }) => session._run((s, a) {
    if (a['id'] != account.value) return d._missing();
    if (!d._name(deviceName)) return d._invalid();
    return Ok(d._register(s, account, deviceName));
  });
  @override
  Future<Result<DeviceTokens>> refresh(String refreshToken) =>
      session._run((s, a) => d._refresh(s, refreshToken, a['id'] as String));
  @override
  Future<List<DeviceInfo>> list(AccountId account) async {
    final result = await session._run((s, a) {
      if (a['id'] != account.value) return d._missing<List<DeviceInfo>>();
      return Ok(
        s.devices.values
            .where((device) => device['account'] == account.value)
            .map(
              (device) => DeviceInfo(
                id: DeviceId.parse(device['id'] as String),
                deviceName: device['deviceName'] as String,
                lastUsedAt: DateTime.fromMillisecondsSinceEpoch(
                  device['lastUsedAt'] as int,
                  isUtc: true,
                ),
              ),
            )
            .toList(),
      );
    });
    return result.valueOrNull ?? [];
  }

  @override
  Future<Result<void>> revoke(AccountId account, DeviceId device) =>
      session._run((s, a) {
        if (a['id'] != account.value ||
            s.devices[device.value]?['account'] != account.value) {
          return d._missing();
        }
        s.devices.remove(device.value);
        return const Ok(null);
      });
}

class _Invites implements InviteService {
  _Invites(this.session);
  final AccountSession session;
  AccountsDomain get d => session._domain;
  @override
  Future<Result<String>> issue({
    required DateTime expiresAt,
    int maxUses = 1,
  }) => session._run((s, a) {
    if (!session._admin(a)) return d._missing();
    if (!expiresAt.isAfter(d.clock.now()) || maxUses < 1 || maxUses > 1000) {
      return d._invalid();
    }
    final code = d._secret();
    final id = d._secret();
    s.invites[id] = {
      'id': id,
      'codeHash': d._hash(code),
      'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch,
      'maxUses': maxUses,
      'usedCount': 0,
      'revokedAt': null,
    };
    return Ok(code);
  });
  @override
  Future<Result<AccountId>> redeem(
    String code, {
    required String displayName,
    required String password,
  }) async {
    final allowed = await session._run<void>((s, a) => const Ok(null));
    if (allowed.isErr) return Err(allowed.failureOrNull!);
    if (code.length != 22 || !d._name(displayName) || !d._password(password)) {
      return d._invalid();
    }
    final usable = await session._run<bool>(
      (s, a) => Ok(d._usableInvite(s, code) != null),
    );
    if (usable.isErr) return Err(usable.failureOrNull!);
    if (!usable.value) return d._missing();
    final hash = await d.hasher.hashAsync(password);
    return session._run((s, a) => d._redeem(s, code, displayName, hash));
  }

  @override
  Future<Result<void>> revoke(String inviteId) => session._run((s, a) {
    if (!session._admin(a) || !s.invites.containsKey(inviteId)) {
      return d._missing();
    }
    s.invites[inviteId]!['revokedAt'] = d._now;
    return const Ok(null);
  });
}

class DbAuthenticator {
  DbAuthenticator(this.domain);
  final AccountsDomain domain;
  Future<Principal?> call(HostRequest request) async {
    final header = request.headers['authorization'];
    if (header == null || !header.startsWith('Bearer ')) return null;
    return domain.authenticate(header.substring(7).trim());
  }
}
