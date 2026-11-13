/// Transactional memory adapter. SQL adapters must preserve this contract.
library;

import 'dart:async';

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
  Future<AccountsState> snapshot();
}

class InMemoryAccountsStore implements AccountsStore {
  AccountsState _state = AccountsState();
  Future<void> _tail = Future<void>.value();

  @override
  Future<T> transaction<T>(FutureOr<T> Function(AccountsState state) action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      final working = _state.copy();
      try {
        final value = await action(working);
        _state = working.copy();
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
