import 'package:jingyu_core/jingyu_core.dart';

abstract class InviteService {
  Future<Result<String>> issue({required DateTime expiresAt, int maxUses = 1});
  Future<Result<AccountId>> redeem(
    String code, {
    required String displayName,
    required String password,
  });
  Future<Result<void>> revoke(String inviteId);
}
