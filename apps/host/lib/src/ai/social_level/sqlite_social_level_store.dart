import 'package:jingyu_core/jingyu_core.dart';
import '../../storage/database.dart';
import 'social_level_service.dart';
import 'social_level_store.dart';

/// Owner-keyed settings do not transfer between operators. Dormant rows are
/// retained and may reappear if the same profile returns to its former owner.
final class SqliteSocialLevelStore implements SocialLevelStore {
  SqliteSocialLevelStore({required this.database, required this.clock});
  final Database database;
  final Clock clock;

  Future<Result<SocialLevelView>> _withOwnedAi(
    AccountId owner,
    AiId ai,
    Future<Result<SocialLevelView>> Function(Tx) action,
  ) => database.transaction((tx) async {
    final identity = await tx.query(
      '''
SELECT p.id FROM ai_profile p
JOIN account a ON a.id=p.account_id AND a.kind='ai' AND a.disabled=0
JOIN ai_operator o ON o.ai_id=a.id
JOIN account owner ON owner.id=o.operator_id AND owner.kind='human' AND owner.disabled=0
WHERE p.id=? AND o.operator_id=?
''',
      [ai.value, owner.value],
    );
    if (identity.length != 1) return err(FailureCode.notFound, 'AI not found');
    return action(tx);
  });

  @override
  Future<Result<SocialLevelView>> get({
    required AccountId owner,
    required AiId ai,
  }) => _withOwnedAi(owner, ai, (tx) async {
    final rows = await tx.query(
      'SELECT level,updated_at FROM ai_social_levels WHERE owner_id=? AND ai_profile_id=?',
      [owner.value, ai.value],
    );
    if (rows.isEmpty) return const Ok(SocialLevelView.unconfigured());
    final rawLevel = rows.single['level'];
    final rawTime = rows.single['updated_at'];
    final level = rawLevel is String ? AiSocialLevel.tryParse(rawLevel) : null;
    final time = rawTime is String ? DateTime.tryParse(rawTime) : null;
    if (level == null ||
        time == null ||
        !time.isUtc ||
        rawTime != time.toIso8601String()) {
      return err(FailureCode.internal, 'Stored social level invalid');
    }
    return Ok(SocialLevelView.configured(level, time));
  });

  @override
  Future<Result<SocialLevelView>> set({
    required AccountId owner,
    required AiId ai,
    required AiSocialLevel level,
  }) => _withOwnedAi(owner, ai, (tx) async {
    final at = clock.now().toUtc();
    await tx.execute(
      '''
INSERT INTO ai_social_levels(owner_id,ai_profile_id,level,updated_at) VALUES(?,?,?,?)
ON CONFLICT(owner_id,ai_profile_id) DO UPDATE SET level=excluded.level,updated_at=excluded.updated_at
''',
      [owner.value, ai.value, level.wire, at.toIso8601String()],
    );
    return Ok(SocialLevelView.configured(level, at));
  });
}
