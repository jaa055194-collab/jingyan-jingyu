import 'package:jingyu_core/jingyu_core.dart';
import 'social_level_service.dart';

abstract interface class SocialLevelStore implements SocialLevelService {}

/// Memory adapter requires an explicit trusted identity policy, never defaults
/// to allow. Production SQLite checks canonical identity in its own transaction.
final class InMemorySocialLevelStore implements SocialLevelStore {
  InMemorySocialLevelStore({required this.clock, required this.ownsActiveAi});
  final Clock clock;
  final bool Function(AccountId owner, AiId ai) ownsActiveAi;
  final _rows = <(String, String), SocialLevelView>{};
  @override
  Future<Result<SocialLevelView>> get({
    required AccountId owner,
    required AiId ai,
  }) async {
    if (!ownsActiveAi(owner, ai)) {
      return err(FailureCode.notFound, 'AI not found');
    }
    return Ok(
      _rows[(owner.value, ai.value)] ?? const SocialLevelView.unconfigured(),
    );
  }

  @override
  Future<Result<SocialLevelView>> set({
    required AccountId owner,
    required AiId ai,
    required AiSocialLevel level,
  }) async {
    if (!ownsActiveAi(owner, ai)) {
      return err(FailureCode.notFound, 'AI not found');
    }
    final view = SocialLevelView.configured(level, clock.now().toUtc());
    _rows[(owner.value, ai.value)] = view;
    return Ok(view);
  }
}
