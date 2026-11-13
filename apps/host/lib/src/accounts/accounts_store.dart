import 'dart:async';

import 'package:jingyu_core/jingyu_core.dart';

import 'account_service.dart';

class AccountRecord {
  AccountRecord({
    required this.id,
    required this.kind,
    required this.displayName,
    required this.passwordHash,
    this.isAdmin = false,
    this.enabled = true,
    this.failedLogins = 0,
    this.lockedUntil,
  });
  final AccountId id;
  final AccountKind kind;
  final String displayName;
  String passwordHash;
  final bool isAdmin;
  bool enabled;
  int failedLogins;
  DateTime? lockedUntil;
}

class InviteRecord {
  InviteRecord({
    required this.id,
    required this.codeHash,
    required this.expiresAt,
    required this.maxUses,
  });
  final String id;
  final String codeHash;
  final DateTime expiresAt;
  final int maxUses;
  int usedCount = 0;
  DateTime? revokedAt;
}

class DeviceRecord {
  DeviceRecord({
    required this.id,
    required this.account,
    required this.deviceName,
    required this.accessHash,
    required this.refreshHash,
    required this.createdAt,
    required this.lastUsedAt,
  });
  final DeviceId id;
  final AccountId account;
  final String deviceName;
  String accessHash;
  String refreshHash;
  final DateTime createdAt;
  DateTime lastUsedAt;
  DateTime? revokedAt;
}

class AccountsState {
  final Map<String, AccountRecord> accounts = {};
  final Map<String, AccountId> operators = {};
  final Map<String, InviteRecord> invites = {};
  final Map<String, DeviceRecord> devices = {};
  int sequence = 0;
  String nextId(String prefix) => '$prefix${++sequence}';
}

abstract class AccountsStore {
  /// Serializes actions within this store. This is not a rollback transaction:
  /// callers validate and compute fallible values before mutating state.
  /// A persistent store needs a separate database transaction/owner-aware API.
  Future<T> serialized<T>(FutureOr<T> Function(AccountsState state) action);
}

class InMemoryAccountsStore implements AccountsStore {
  final AccountsState _state = AccountsState();
  Future<void> _tail = Future<void>.value();

  @override
  Future<T> serialized<T>(
    FutureOr<T> Function(AccountsState state) action,
  ) async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    try {
      return await action(_state);
    } finally {
      release.complete();
    }
  }
}
