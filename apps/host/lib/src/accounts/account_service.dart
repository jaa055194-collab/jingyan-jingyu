import 'package:jingyu_core/jingyu_core.dart';

enum AccountKind { human, ai }

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
