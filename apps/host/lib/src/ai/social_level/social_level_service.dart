import 'package:jingyu_core/jingyu_core.dart';

/// Stored configuration only: no consent, L4 switch or dispatch authorization.
enum AiSocialLevel {
  l0('L0'),
  l1('L1'),
  l2('L2'),
  l3('L3'),
  l4('L4');

  const AiSocialLevel(this.wire);
  final String wire;
  static AiSocialLevel? tryParse(String raw) {
    for (final level in values) {
      if (level.wire == raw) return level;
    }
    return null;
  }
}

final class SocialLevelView {
  const SocialLevelView.unconfigured() : level = null, updatedAt = null;
  const SocialLevelView.configured(this.level, this.updatedAt);
  final AiSocialLevel? level;
  final DateTime? updatedAt;
  bool get configurationRequired => level == null;
  Map<String, Object?> toJson() => {
    'configurationRequired': configurationRequired,
    'level': level?.wire,
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
  };
}

/// Owner is supplied by a trusted authenticated boundary, never request JSON.
/// Missing rows remain unconfigured: callers must not infer L0/L1 permission.
abstract interface class SocialLevelService {
  Future<Result<SocialLevelView>> get({
    required AccountId owner,
    required AiId ai,
  });
  Future<Result<SocialLevelView>> set({
    required AccountId owner,
    required AiId ai,
    required AiSocialLevel level,
  });
}
