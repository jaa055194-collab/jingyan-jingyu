import 'package:jingyu_core/jingyu_core.dart';
import 'account_service.dart';
import 'accounts_store.dart';
import 'password_hasher.dart';

abstract class InviteService {
  Future<Result<String>> issue({required DateTime expiresAt, int maxUses = 1});
  Future<Result<AccountId>> redeem(
    String code, {
    required String displayName,
    required String password,
  });
  Future<Result<void>> revoke(String inviteId);
}

/// Administrative authorization for issue/revoke belongs to the admin route.
class DefaultInviteService implements InviteService {
  DefaultInviteService({
    required this.store,
    required this.clock,
    required this.passwords,
  });
  final AccountsStore store;
  final Clock clock;
  final PasswordHasher passwords;

  @override
  Future<Result<String>> issue({
    required DateTime expiresAt,
    int maxUses = 1,
  }) => store.serialized((s) {
    if (!expiresAt.isAfter(clock.now()) || maxUses < 1) {
      return err(FailureCode.invalidArgument, 'invalid invite');
    }
    final code = randomSecret(16);
    final record = InviteRecord(
      id: s.nextId('i'),
      codeHash: secretHash(code),
      expiresAt: expiresAt,
      maxUses: maxUses,
    );
    s.invites[record.id] = record;
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
    final passwordHash = await passwords.hash(password);
    return store.serialized((s) {
      if (displayName.trim().isEmpty || password.isEmpty) {
        return err(FailureCode.invalidArgument, 'invalid account');
      }
      final hash = secretHash(code);
      final matches = s.invites.values.where((i) => i.codeHash == hash);
      if (matches.isEmpty) {
        return err(FailureCode.notFound, 'invite unavailable');
      }
      final invite = matches.first;
      if (invite.revokedAt != null ||
          !clock.now().isBefore(invite.expiresAt) ||
          invite.usedCount >= invite.maxUses) {
        return err(FailureCode.notFound, 'invite unavailable');
      }
      final id = AccountId.parse(s.nextId('a'));
      s.accounts[id.value] = AccountRecord(
        id: id,
        kind: AccountKind.human,
        displayName: displayName,
        passwordHash: passwordHash,
      );
      invite.usedCount++;
      return Ok(id);
    });
  }

  @override
  Future<Result<void>> revoke(String inviteId) => store.serialized((s) {
    final invite = s.invites[inviteId];
    if (invite == null) return err(FailureCode.notFound, 'invite unavailable');
    invite.revokedAt ??= clock.now();
    return const Ok(null);
  });
}
