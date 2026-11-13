import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';

import '../storage/database.dart';
import 'account_service.dart';
import 'device_service.dart';
import 'invite_service.dart';
import 'password_hasher.dart';

String _id(String prefix) => '$prefix${randomSecret(18)}';
int _at(DateTime time) => time.microsecondsSinceEpoch;
DateTime _time(Object? value) =>
    DateTime.fromMicrosecondsSinceEpoch(value as int, isUtc: true);
Future<Map<String, Object?>?> _account(Tx tx, AccountId id) async {
  final rows = await tx.query('SELECT * FROM account WHERE id = ?', [id.value]);
  return rows.isEmpty ? null : rows.single;
}

Future<void> _revokeDevices(Tx tx, AccountId id, int now) async {
  await tx.execute('UPDATE device SET revoked_at = ? WHERE account_id = ?', [
    now,
    id.value,
  ]);
  await tx.execute(
    'DELETE FROM refresh_token WHERE device_id IN (SELECT id FROM device WHERE account_id = ?)',
    [id.value],
  );
}

Future<void> _insertHuman(
  Tx tx,
  AccountId id,
  String name,
  String hash, {
  bool admin = false,
}) async {
  await tx.execute(
    'INSERT INTO account (id, kind, display_name, password_hash, is_admin) VALUES (?, ?, ?, ?, ?)',
    [id.value, 'human', name, hash, admin ? 1 : 0],
  );
}

/// SQL operations own short transactions. Password work runs between the
/// snapshot and commit transactions; authorization and credentials are re-read.
class SqliteAccountService implements AccountService {
  SqliteAccountService({
    required this.database,
    required this.clock,
    required this.passwords,
  });
  final Database database;
  final Clock clock;
  final PasswordHasher passwords;
  AccountId? _actor;
  SqliteAccountService forActor(AccountId id) => SqliteAccountService(
    database: database,
    clock: clock,
    passwords: passwords,
  ).._actor = id;
  Future<bool> _admin(Tx tx) async {
    if (_actor == null) return false;
    final row = await _account(tx, _actor!);
    return row?['is_admin'] == 1 && row?['enabled'] == 1;
  }

  Future<Result<AccountId>> bootstrapAdmin({
    required String displayName,
    required String password,
  }) async {
    if (displayName.trim().isEmpty || password.isEmpty) {
      return err(FailureCode.invalidArgument, 'invalid account');
    }
    final hash = await passwords.hash(password);
    return database.transaction((tx) async {
      if ((await tx.query(
        'SELECT id FROM account WHERE is_admin = 1',
      )).isNotEmpty) {
        return err(FailureCode.conflict, 'admin already initialized');
      }
      final id = AccountId.parse(_id('a'));
      await _insertHuman(tx, id, displayName, hash, admin: true);
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
    if (!await database.transaction(_admin)) {
      return err(FailureCode.forbidden, 'admin required');
    }
    final hash = await passwords.hash(password);
    return database.transaction((tx) async {
      if (!await _admin(tx)) {
        return err(FailureCode.forbidden, 'admin required');
      }
      final id = AccountId.parse(_id('a'));
      await _insertHuman(tx, id, displayName, hash);
      return Ok(id);
    });
  }

  @override
  Future<Result<AccountId>> createAi({
    required AccountId operator,
    required String displayName,
  }) => database.transaction((tx) async {
    final owner = await _account(tx, operator);
    if (_actor != operator ||
        owner?['kind'] != 'human' ||
        owner?['enabled'] != 1 ||
        displayName.trim().isEmpty) {
      return err(FailureCode.forbidden, 'human operator required');
    }
    final id = AccountId.parse(_id('a'));
    await tx.execute(
      'INSERT INTO account (id, kind, display_name, password_hash) VALUES (?, ?, ?, ?)',
      [id.value, 'ai', displayName, ''],
    );
    await tx.execute(
      'INSERT INTO ai_operator (ai_id, human_id) VALUES (?, ?)',
      [id.value, operator.value],
    );
    return Ok(id);
  });

  @override
  Future<Result<void>> disable(AccountId id) => database.transaction((
    tx,
  ) async {
    final row = await _account(tx, id);
    if (row == null) return err(FailureCode.notFound, 'account not found');
    if (!await _admin(tx)) {
      final owner = _actor == null ? null : await _account(tx, _actor!);
      final links = await tx.query(
        'SELECT ai_id FROM ai_operator WHERE ai_id = ? AND human_id = ?',
        [id.value, _actor?.value],
      );
      if (owner?['enabled'] != 1 || links.isEmpty) {
        return err(FailureCode.notFound, 'account not found');
      }
    }
    await tx.execute('UPDATE account SET enabled = 0 WHERE id = ?', [id.value]);
    await _revokeDevices(tx, id, _at(clock.now()));
    return const Ok(null);
  });

  @override
  Future<Result<void>> resetPassword(AccountId id, String newPassword) async {
    if (newPassword.isEmpty) {
      return err(FailureCode.invalidArgument, 'invalid password');
    }
    if (!await database.transaction(_admin)) {
      return err(FailureCode.forbidden, 'admin required');
    }
    final hash = await passwords.hash(newPassword);
    return database.transaction((tx) async {
      if (!await _admin(tx)) {
        return err(FailureCode.forbidden, 'admin required');
      }
      final row = await _account(tx, id);
      if (row?['kind'] != 'human') {
        return err(FailureCode.notFound, 'account not found');
      }
      await tx.execute(
        'UPDATE account SET password_hash = ?, failed_logins = 0, locked_until = NULL WHERE id = ?',
        [hash, id.value],
      );
      await _revokeDevices(tx, id, _at(clock.now()));
      return const Ok(null);
    });
  }

  @override
  Future<bool> isOperatorOf(AccountId human, AccountId ai) =>
      database.transaction(
        (tx) async => (await tx.query(
          'SELECT ai_id FROM ai_operator WHERE human_id = ? AND ai_id = ?',
          [human.value, ai.value],
        )).isNotEmpty,
      );

  Future<Result<AccountId>> login(AccountId id, String password) async {
    final snapshot = await database.transaction<Result<String>>((tx) async {
      final row = await _account(tx, id);
      if (row?['kind'] != 'human' || row?['enabled'] != 1) {
        return err(FailureCode.unauthenticated, 'invalid credentials');
      }
      if (row!['locked_until'] != null &&
          _at(clock.now()) < (row['locked_until'] as int)) {
        return err(FailureCode.rateLimited, 'account locked');
      }
      return Ok(row['password_hash'] as String);
    });
    if (snapshot.isErr) return Err(snapshot.failureOrNull!);
    final hash = snapshot.value;
    final valid = await passwords.verify(password, hash);
    return database.transaction((tx) async {
      final row = await _account(tx, id);
      if (row?['enabled'] != 1 || row?['password_hash'] != hash) {
        return err(FailureCode.unauthenticated, 'credentials changed');
      }
      final now = _at(clock.now());
      final locked = row!['locked_until'] as int?;
      if (locked != null && now < locked) {
        return err(FailureCode.rateLimited, 'account locked');
      }
      var failures = locked == null ? row['failed_logins'] as int : 0;
      if (!valid) {
        failures++;
        await tx.execute(
          'UPDATE account SET failed_logins = ?, locked_until = ? WHERE id = ?',
          [
            failures,
            failures >= 5
                ? _at(clock.now().add(const Duration(minutes: 15)))
                : null,
            id.value,
          ],
        );
        return err(FailureCode.unauthenticated, 'invalid credentials');
      }
      await tx.execute(
        'UPDATE account SET failed_logins = 0, locked_until = NULL WHERE id = ?',
        [id.value],
      );
      return Ok(id);
    });
  }

  Future<Result<List<AccountMetadata>>> metadata() => database.transaction((
    tx,
  ) async {
    if (!await _admin(tx)) return err(FailureCode.forbidden, 'admin required');
    final rows = await tx.query(
      'SELECT a.*, (SELECT count(*) FROM device d WHERE d.account_id = a.id AND d.revoked_at IS NULL) AS device_count FROM account a ORDER BY a.rowid',
    );
    return Ok(
      rows
          .map(
            (row) => AccountMetadata(
              id: AccountId.parse(row['id'] as String),
              kind: row['kind'] == 'human' ? AccountKind.human : AccountKind.ai,
              displayName: row['display_name'] as String,
              enabled: row['enabled'] == 1,
              isAdmin: row['is_admin'] == 1,
              deviceCount: row['device_count'] as int,
            ),
          )
          .toList(),
    );
  });
}

/// As in DefaultInviteService, the admin route authorizes issue and revoke.
class SqliteInviteService implements InviteService {
  SqliteInviteService({
    required this.database,
    required this.clock,
    required this.passwords,
  });
  final Database database;
  final Clock clock;
  final PasswordHasher passwords;

  @override
  Future<Result<String>> issue({
    required DateTime expiresAt,
    int maxUses = 1,
  }) => database.transaction((tx) async {
    if (!expiresAt.isAfter(clock.now()) || maxUses < 1) {
      return err(FailureCode.invalidArgument, 'invalid invite');
    }
    final code = randomSecret(16);
    await tx.execute(
      'INSERT INTO invite (id, code_hash, expires_at, max_uses) VALUES (?, ?, ?, ?)',
      [_id('i'), secretHash(code), _at(expiresAt), maxUses],
    );
    return Ok(code);
  });

  @override
  Future<Result<AccountId>> redeem(
    String code, {
    required String displayName,
    required String password,
  }) async {
    if (displayName.trim().isEmpty || password.isEmpty) {
      return err(FailureCode.invalidArgument, 'invalid account');
    }
    final hash = await passwords.hash(password);
    return database.transaction((tx) async {
      final rows = await tx.query(
        'SELECT id FROM invite WHERE code_hash = ? AND revoked_at IS NULL AND expires_at > ? AND used_count < max_uses',
        [secretHash(code), _at(clock.now())],
      );
      if (rows.isEmpty) return err(FailureCode.notFound, 'invite unavailable');
      await tx.execute(
        'UPDATE invite SET used_count = used_count + 1 WHERE id = ?',
        [rows.single['id']],
      );
      final id = AccountId.parse(_id('a'));
      await _insertHuman(tx, id, displayName, hash);
      return Ok(id);
    });
  }

  @override
  Future<Result<void>> revoke(String inviteId) =>
      database.transaction((tx) async {
        if ((await tx.query('SELECT id FROM invite WHERE id = ?', [
          inviteId,
        ])).isEmpty) {
          return err(FailureCode.notFound, 'invite unavailable');
        }
        await tx.execute(
          'UPDATE invite SET revoked_at = COALESCE(revoked_at, ?) WHERE id = ?',
          [_at(clock.now()), inviteId],
        );
        return const Ok(null);
      });
}

class SqliteDeviceService implements DeviceService {
  SqliteDeviceService({required this.database, required this.clock});
  final Database database;
  final Clock clock;

  Future<DeviceTokens> _rotate(Tx tx, DeviceId id) async {
    final access = randomSecret(32);
    final refresh = randomSecret(32);
    await tx.execute(
      'UPDATE device SET access_hash = ?, last_used_at = ? WHERE id = ?',
      [secretHash(access), _at(clock.now()), id.value],
    );
    await tx.execute('DELETE FROM refresh_token WHERE device_id = ?', [
      id.value,
    ]);
    await tx.execute(
      'INSERT INTO refresh_token (device_id, token_hash) VALUES (?, ?)',
      [id.value, secretHash(refresh)],
    );
    return DeviceTokens(
      deviceId: id,
      accessToken: access,
      refreshToken: refresh,
    );
  }

  @override
  Future<Result<DeviceTokens>> register(
    AccountId account, {
    required String deviceName,
  }) => database.transaction((tx) async {
    if ((await _account(tx, account))?['enabled'] != 1) {
      return err(FailureCode.unauthenticated, 'account unavailable');
    }
    if (deviceName.trim().isEmpty) {
      return err(FailureCode.invalidArgument, 'invalid device');
    }
    final online = await tx.query(
      'SELECT id FROM device WHERE account_id = ? AND revoked_at IS NULL ORDER BY last_used_at, rowid',
      [account.value],
    );
    final now = _at(clock.now());
    for (var i = 0; i <= online.length - 2; i++) {
      await tx.execute('UPDATE device SET revoked_at = ? WHERE id = ?', [
        now,
        online[i]['id'],
      ]);
      await tx.execute('DELETE FROM refresh_token WHERE device_id = ?', [
        online[i]['id'],
      ]);
    }
    final id = DeviceId.parse(_id('d'));
    await tx.execute(
      'INSERT INTO device (id, account_id, device_name, access_hash, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?)',
      [
        id.value,
        account.value,
        deviceName,
        secretHash(randomSecret(32)),
        now,
        now,
      ],
    );
    return Ok(await _rotate(tx, id));
  });

  @override
  Future<Result<DeviceTokens>> refresh(
    String refreshToken,
  ) => database.transaction((tx) async {
    final rows = await tx.query(
      'SELECT d.id FROM refresh_token r JOIN device d ON d.id = r.device_id JOIN account a ON a.id = d.account_id WHERE r.token_hash = ? AND d.revoked_at IS NULL AND a.enabled = 1',
      [secretHash(refreshToken)],
    );
    if (rows.isEmpty) {
      return err(FailureCode.unauthenticated, 'invalid refresh token');
    }
    return Ok(await _rotate(tx, DeviceId.parse(rows.single['id'] as String)));
  });

  Future<Principal?> authenticate(String accessToken) => database.transaction((
    tx,
  ) async {
    final rows = await tx.query(
      'SELECT d.id, d.account_id, a.is_admin FROM device d JOIN account a ON a.id = d.account_id WHERE d.access_hash = ? AND d.revoked_at IS NULL AND a.enabled = 1',
      [secretHash(accessToken)],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    await tx.execute('UPDATE device SET last_used_at = ? WHERE id = ?', [
      _at(clock.now()),
      row['id'],
    ]);
    return Principal(
      accountId: row['account_id'] as String,
      deviceId: row['id'] as String,
      isAdmin: row['is_admin'] == 1,
    );
  });

  @override
  Future<List<DeviceInfo>> list(AccountId account) => database.transaction((
    tx,
  ) async {
    final rows = await tx.query(
      'SELECT * FROM device WHERE account_id = ? AND revoked_at IS NULL ORDER BY rowid',
      [account.value],
    );
    return rows
        .map(
          (row) => DeviceInfo(
            id: DeviceId.parse(row['id'] as String),
            deviceName: row['device_name'] as String,
            createdAt: _time(row['created_at']),
            lastUsedAt: _time(row['last_used_at']),
          ),
        )
        .toList();
  });

  @override
  Future<Result<void>> revoke(AccountId account, DeviceId device) =>
      database.transaction((tx) async {
        final rows = await tx.query(
          'SELECT id FROM device WHERE id = ? AND account_id = ?',
          [device.value, account.value],
        );
        if (rows.isEmpty) {
          return err(FailureCode.notFound, 'device unavailable');
        }
        await tx.execute(
          'UPDATE device SET revoked_at = COALESCE(revoked_at, ?) WHERE id = ?',
          [_at(clock.now()), device.value],
        );
        await tx.execute('DELETE FROM refresh_token WHERE device_id = ?', [
          device.value,
        ]);
        return const Ok(null);
      });
}
