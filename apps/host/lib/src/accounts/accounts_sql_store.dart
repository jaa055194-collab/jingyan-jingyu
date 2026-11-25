import 'dart:async';

import '../storage/database.dart';
import '../storage/sqlite_audit_log.dart';
import 'accounts_migrations.dart';
import 'accounts_store.dart';

/// SQL adapter for the callback-based domain contract. Each callback loads a
/// complete working state inside the database's serialized transaction, then
/// persists only changed rows. This is intentionally O(total state) per call;
/// callers must not nest transactions or use the outer database in callbacks.
class SqlAccountsStore implements AccountsStore {
  SqlAccountsStore(this.database);
  final Database database;

  /// Idempotent and safe across store instances sharing the same database.
  /// M01's foundation migration must already have created schema_migrations.
  Future<void> start() => database.transaction((tx) async {
    for (final migration in accountsMigrations) {
      final applied = await tx.query(
        'SELECT version FROM schema_migrations WHERE version = ?',
        [migration.version],
      );
      if (applied.isNotEmpty) continue;
      // M02 DDL is static and contains no string literal with semicolons.
      // Tx.execute prepares one statement, so apply each statement separately.
      for (final statement in migration.sql.split(';')) {
        if (statement.trim().isNotEmpty) await tx.execute(statement);
      }
      await tx.execute(
        'INSERT INTO schema_migrations (version, name) VALUES (?, ?)',
        [migration.version, migration.name],
      );
    }
  });

  Future<void>? _ready;
  Future<void> _ensureStarted() =>
      _ready ??= start().catchError((Object error) {
        _ready = null;
        throw error;
      });

  @override
  Future<T> transaction<T>(FutureOr<T> Function(AccountsState state) action) =>
      _transaction(action);

  @override
  Future<T> transactionWithAudit<T>(
    FutureOr<T> Function(AccountsState state) action, {
    required AccountsStateAudit audit,
  }) => _transaction(action, audit: audit);

  Future<T> _transaction<T>(
    FutureOr<T> Function(AccountsState state) action, {
    AccountsStateAudit? audit,
  }) async {
    await _ensureStarted();
    return database.transaction((tx) async {
      final before = await _load(tx);
      final working = before.copy();
      final result = await action(working);
      // Detach callback-retained references before yielding to asynchronous SQL.
      final after = working.copy();
      _validate(after);
      if (audit != null) {
        for (final entry in audit(before, after)) {
          await SqliteAuditLog.recordInTransaction(tx, entry);
        }
      }
      await _persist(tx, before, after);
      return result;
    });
  }

  @override
  Future<AccountsState> snapshot() async {
    await _ensureStarted();
    return database.transaction((tx) => _load(tx));
  }

  Future<AccountsState> _load(Tx tx) async {
    final state = AccountsState();
    for (final row in await tx.query('''
SELECT a.id, a.display_name AS displayName, a.kind,
       o.operator_id AS operator, a.is_admin AS isAdmin, a.disabled,
       r.account_id IS NOT NULL AS removed, r.removed_at AS removedAt,
       a.password_hash AS passwordHash, a.failed_passwords AS failedPasswords,
       a.locked_until AS lockedUntil
FROM account a LEFT JOIN ai_operator o ON o.ai_id = a.id
LEFT JOIN removed_ai_accounts r ON r.account_id = a.id
''')) {
      row['isAdmin'] = row['isAdmin'] == 1;
      row['disabled'] = row['disabled'] == 1;
      row['removed'] = row['removed'] == 1;
      state.accounts[row['id'] as String] = row;
    }
    for (final row in await tx.query('''
SELECT d.id, d.account_id AS account, d.device_name AS deviceName,
       d.access_hash AS accessHash, r.token_hash AS refreshHash,
       d.access_expires AS accessExpires, r.expires_at AS refreshExpires,
       d.last_used_at AS lastUsedAt
FROM device d JOIN refresh_token r ON r.device_id = d.id
''')) {
      state.devices[row['id'] as String] = row;
    }
    for (final row in await tx.query('''
SELECT id, code_hash AS codeHash, expires_at AS expiresAt,
       max_uses AS maxUses, used_count AS usedCount, revoked_at AS revokedAt
FROM invite
''')) {
      state.invites[row['id'] as String] = row;
    }
    return state;
  }

  void _validate(AccountsState state) {
    for (final rows in [state.accounts, state.devices, state.invites]) {
      for (final entry in rows.entries) {
        if (entry.key != entry.value['id']) {
          throw ArgumentError('State map key must match row id');
        }
      }
    }
    final digest = RegExp(r'^[0-9a-f]{64}$');
    for (final invite in state.invites.values) {
      if (invite['codeHash'] is! String ||
          !digest.hasMatch(invite['codeHash'] as String)) {
        throw ArgumentError('Invite must contain a SHA-256 digest');
      }
    }
    for (final account in state.accounts.values) {
      final operator = account['operator'];
      if (account['kind'] == 'ai') {
        if (operator == account['id'] ||
            state.accounts[operator]?['kind'] != 'human') {
          throw ArgumentError('AI accounts require a human operator');
        }
      } else if (operator != null) {
        throw ArgumentError('Human accounts cannot have an operator');
      }
      if (account['removed'] == true && account['removedAt'] is! int) {
        throw ArgumentError('Removed accounts require a removal timestamp');
      }
    }
    for (final device in state.devices.values) {
      for (final field in ['accessHash', 'refreshHash']) {
        final value = device[field];
        if (value is! String || !digest.hasMatch(value)) {
          throw ArgumentError('Device $field must be a SHA-256 digest');
        }
      }
      if (!state.accounts.containsKey(device['account'])) {
        throw ArgumentError('Device requires an account');
      }
    }
  }

  Future<void> _persist(
    Tx tx,
    AccountsState before,
    AccountsState after,
  ) async {
    // Remove references first; never REPLACE parent rows (which would cascade
    // deletion into other tables). Every value is bound; identifiers are static.
    for (final id in before.accounts.keys) {
      final old = before.accounts[id]!;
      final next = after.accounts[id];
      if (old['operator'] != null &&
          (next == null || old['operator'] != next['operator'])) {
        await tx.execute('DELETE FROM ai_operator WHERE ai_id = ?', [id]);
      }
    }
    for (final id in before.devices.keys) {
      if (!after.devices.containsKey(id)) {
        await tx.execute('DELETE FROM refresh_token WHERE device_id = ?', [id]);
        await tx.execute('DELETE FROM device WHERE id = ?', [id]);
      }
    }
    for (final id in before.accounts.keys) {
      if (!after.accounts.containsKey(id)) {
        await tx.execute('DELETE FROM account WHERE id = ?', [id]);
      }
    }
    for (final id in before.invites.keys) {
      if (!after.invites.containsKey(id)) {
        await tx.execute('DELETE FROM invite WHERE id = ?', [id]);
      }
    }
    for (final entry in after.accounts.entries) {
      if (_same(before.accounts[entry.key], entry.value)) continue;
      final r = entry.value;
      await tx.execute(
        '''
INSERT INTO account (id, display_name, kind, is_admin, disabled, password_hash, failed_passwords, locked_until)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET display_name=excluded.display_name,
kind=excluded.kind, is_admin=excluded.is_admin, disabled=excluded.disabled,
password_hash=excluded.password_hash, failed_passwords=excluded.failed_passwords,
locked_until=excluded.locked_until
''',
        [
          r['id'],
          r['displayName'],
          r['kind'],
          r['isAdmin'] == true ? 1 : 0,
          r['disabled'] == true ? 1 : 0,
          r['passwordHash'],
          r['failedPasswords'],
          r['lockedUntil'],
        ],
      );
      // Write the marker only on the first removal. Ordinary account upserts
      // must not recreate or change an existing removal timestamp.
      if (r['removed'] == true &&
          before.accounts[entry.key]?['removed'] != true) {
        await tx.execute(
          'INSERT INTO removed_ai_accounts (account_id, removed_at) VALUES (?, ?)',
          [entry.key, r['removedAt']],
        );
      }
    }
    for (final entry in after.accounts.entries) {
      final r = entry.value;
      if (r['operator'] != null &&
          before.accounts[entry.key]?['operator'] != r['operator']) {
        await tx.execute(
          '''
INSERT INTO ai_operator (ai_id, operator_id) VALUES (?, ?)
ON CONFLICT(ai_id) DO UPDATE SET operator_id=excluded.operator_id
''',
          [r['id'], r['operator']],
        );
      }
    }
    for (final entry in after.devices.entries) {
      if (_same(before.devices[entry.key], entry.value)) continue;
      final r = entry.value;
      await tx.execute(
        '''
INSERT INTO device (id, account_id, device_name, access_hash, access_expires, last_used_at)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET account_id=excluded.account_id,
device_name=excluded.device_name, access_hash=excluded.access_hash,
access_expires=excluded.access_expires, last_used_at=excluded.last_used_at
''',
        [
          r['id'],
          r['account'],
          r['deviceName'],
          r['accessHash'],
          r['accessExpires'],
          r['lastUsedAt'],
        ],
      );
      await tx.execute(
        '''
INSERT INTO refresh_token (device_id, token_hash, expires_at) VALUES (?, ?, ?)
ON CONFLICT(device_id) DO UPDATE SET token_hash=excluded.token_hash, expires_at=excluded.expires_at
''',
        [r['id'], r['refreshHash'], r['refreshExpires']],
      );
    }
    for (final entry in after.invites.entries) {
      if (_same(before.invites[entry.key], entry.value)) continue;
      final r = entry.value;
      await tx.execute(
        '''
INSERT INTO invite (id, code_hash, expires_at, max_uses, used_count, revoked_at)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET code_hash=excluded.code_hash,
expires_at=excluded.expires_at, max_uses=excluded.max_uses,
used_count=excluded.used_count, revoked_at=excluded.revoked_at
''',
        [
          r['id'],
          r['codeHash'],
          r['expiresAt'],
          r['maxUses'],
          r['usedCount'],
          r['revokedAt'],
        ],
      );
    }
  }

  bool _same(Map<String, Object?>? a, Map<String, Object?> b) =>
      a != null &&
      a.length == b.length &&
      b.entries.every((entry) => a[entry.key] == entry.value);
}
