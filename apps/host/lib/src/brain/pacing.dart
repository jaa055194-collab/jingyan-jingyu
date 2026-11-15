/// M07 brain · human-like pacing.
///
/// Pure Dart: the only time source is an injected [Clock], so delays are
/// deterministic in tests. This models the short "typing" pause (1–4s by
/// default) the assistant should wait before sending a real reply, keeping it
/// from answering at machine speed.
library;

import 'package:jingyu_core/jingyu_core.dart';

/// Computes a human-like delay before an outbound reply.
///
/// The delay is deterministic for a given ([clock] instant, [text]) pair and is
/// always clamped into `[min, max]`. Pacing can be switched off entirely with
/// [enabled] (then [delayFor] returns [Duration.zero]), which satisfies the
/// "拟人延迟可关" acceptance rule.
class HumanPacing {
  const HumanPacing({
    required this.clock,
    this.min = const Duration(seconds: 1),
    this.max = const Duration(seconds: 4),
    this.enabled = true,
  });

  /// Time source. Implementations must not be `DateTime.now()` in production
  /// code; tests inject a [FakeClock].
  final Clock clock;

  /// Lower bound of the pause window (inclusive).
  final Duration min;

  /// Upper bound of the pause window (inclusive).
  final Duration max;

  /// When false, [delayFor] always returns [Duration.zero].
  final bool enabled;

  /// The delay to wait before replying to [text].
  ///
  /// Deterministic: the same messages at the same clock instant always produce
  /// the same delay. Empty text is still paced (based on the clock alone).
  Duration delayFor(String text) {
    if (!enabled) {
      return Duration.zero;
    }
    final int low = min.inMilliseconds < 0 ? 0 : min.inMilliseconds;
    final int high = max.inMilliseconds < low ? low : max.inMilliseconds;
    final int span = high - low;
    if (span <= 0) {
      return Duration(milliseconds: low);
    }
    final int seed = _seed(text);
    return Duration(milliseconds: low + (seed % (span + 1)));
  }

  /// Deterministic 31-bit mix of the message content and the injected clock.
  int _seed(String text) {
    // FNV-1a over the message code points.
    int hash = 0x811c9dc5;
    for (final int rune in text.runes) {
      hash ^= rune;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    // Fold in the clock so pacing varies over time but stays reproducible.
    hash ^= clock.now().microsecondsSinceEpoch & 0x7fffffff;
    hash = (hash * 0x01000193) & 0x7fffffff;
    return hash;
  }
}
