/// Transactional memory adapter. SQL adapters must preserve this contract.
library;

import 'dart:async';

import '../audit/audit_log.dart';

/// Builds audit entries from the state observed immediately before and after
/// the transaction action. Returning an empty list records no audit.
typedef AccountsStateAudit =
    List<AuditEntry> Function(AccountsState before, AccountsState after);

/// Storage rows contain primitives and credential digests, never raw credentials.
class AccountsState {
  AccountsState({
    Map<String, Map<String, Object?>>? accounts,
    Map<String, Map<String, Object?>>? devices,
    Map<String, Map<String, Object?>>? invites,
  }) : accounts = accounts ?? {},
       devices = devices ?? {},
       invites = invites ?? {};
  final Map<String, Map<String, Object?>> accounts;
  final Map<String, Map<String, Object?>> devices;
  final Map<String, Map<String, Object?>> invites;

  AccountsState copy() => AccountsState(
    accounts: _copy(accounts),
    devices: _copy(devices),
    invites: _copy(invites),
  );
  static Map<String, Map<String, Object?>> _copy(
    Map<String, Map<String, Object?>> rows,
  ) => rows.map((key, row) => MapEntry(key, Map<String, Object?>.from(row)));
  Map<String, Object?> toJson() => {
    'accounts': _copy(accounts),
    'devices': _copy(devices),
    'invites': _copy(invites),
  };
}

/// Trusted storage boundary, not a client-facing service. Callbacks must not nest
/// transactions. Commit on success; exceptions discard the complete working copy.
abstract class AccountsStore {
  Future<T> transaction<T>(FutureOr<T> Function(AccountsState state) action);

  /// Same transaction contract plus append-only audit writes in the same
  /// storage commit. The audit builder runs after the action and before commit;
  /// a throw from either rolls back both state and audit.
  Future<T> transactionWithAudit<T>(
    FutureOr<T> Function(AccountsState state) action, {
    required AccountsStateAudit audit,
  });

  Future<AccountsState> snapshot();
}

class InMemoryAccountsStore implements AccountsStore {
  AccountsState _state = AccountsState();
  final List<AuditEntry> _auditEntries = <AuditEntry>[];
  Future<void> _tail = Future<void>.value();

  /// Diagnostics for trusted tests; entries are committed with the same
  /// serialized transaction as the state they describe.
  List<AuditEntry> get auditEntries =>
      List<AuditEntry>.unmodifiable(_auditEntries);

  @override
  Future<T> transaction<T>(FutureOr<T> Function(AccountsState state) action) =>
      _transaction(action, null);

  @override
  Future<T> transactionWithAudit<T>(
    FutureOr<T> Function(AccountsState state) action, {
    required AccountsStateAudit audit,
  }) => _transaction(action, audit);

  Future<T> _transaction<T>(
    FutureOr<T> Function(AccountsState state) action,
    AccountsStateAudit? audit,
  ) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      final before = _state.copy();
      final working = before.copy();
      try {
        final value = await action(working);
        final entries =
            audit?.call(before, working.copy()) ?? const <AuditEntry>[];
        _state = working.copy();
        _auditEntries.addAll(entries);
        result.complete(value);
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  @override
  Future<AccountsState> snapshot() => transaction((state) => state.copy());
}
