/// M07 brain · rules-first S1 classifier foundation.
///
/// Pure Dart: no IO, network, or model calls. The classifier only inspects the
/// message text and returns a [Complexity] together with short, stable reason
/// tags. The decision order is fixed:
/// empty -> question -> longText -> emotion -> greeting/short -> noRule.
///
/// This is the deterministic rule layer described in `02-decisions.md` B-1;
/// a small `chat.fast` model may refine the result in a later phase.
library;

/// How much reasoning a message is judged to need.
enum Complexity { simple, complex, unsure }

/// Result of [RuleClassifier.classify].
class Classification {
  const Classification(this.complexity, this.reasons);

  /// The inferred complexity.
  final Complexity complexity;

  /// Short, stable tags explaining which rule fired, e.g. `question`.
  final List<String> reasons;

  @override
  String toString() => 'Classification($complexity, $reasons)';
}

/// Rules-first S1 classifier.
class RuleClassifier {
  const RuleClassifier({this.longTextThreshold = 80});

  /// Message length, counted in Unicode code points, at which text is treated
  /// as [Complexity.complex] with reason `longText`.
  final int longTextThreshold;

  /// Very short messages (code points) that are not questions become simple.
  static const int _shortTextThreshold = 6;

  static const List<String> _questionMarkers = <String>[
    '？',
    '?',
    '吗',
    '呢',
    '怎么',
    '为什么',
    '如何',
    '是不是',
    '多少',
    '哪',
  ];

  static const List<String> _emotionWords = <String>[
    '累',
    '难过',
    '生气',
    '崩溃',
    '疼',
    '失眠',
    '焦虑',
    '开心',
    '委屈',
  ];

  static const List<String> _greetings = <String>[
    '你好',
    '在吗',
    '早安',
    '晚安',
    '哈哈',
    '嗯',
    '哦',
    '好',
    '早',
    'hi',
    'hello',
    '在么',
  ];

  /// Classifies [text] into a [Complexity].
  ///
  /// [inGroup] never changes the decision; when true it only appends the
  /// reason tag `group` so callers can log group context.
  Classification classify(String text, {bool inGroup = false}) {
    final String trimmed = text.trim();
    final List<String> reasons = <String>[];
    final Complexity complexity;

    if (trimmed.isEmpty) {
      // 1. Nothing to answer.
      complexity = Complexity.unsure;
      reasons.add('empty');
    } else if (_containsAny(trimmed, _questionMarkers)) {
      // 2. A question marker means real reasoning is likely needed.
      complexity = Complexity.complex;
      reasons.add('question');
    } else if (trimmed.runes.length >= longTextThreshold) {
      // 3. Long messages carry more context than S1 should improvise on.
      complexity = Complexity.complex;
      reasons.add('longText');
    } else if (_containsAny(trimmed, _emotionWords)) {
      // 4. Emotional / health events deserve the main responder.
      complexity = Complexity.complex;
      reasons.add('emotion');
    } else if (_isGreeting(trimmed.toLowerCase())) {
      // 5a. Short greeting / interjection can be answered directly by S1.
      complexity = Complexity.simple;
      reasons.add('greeting');
    } else if (trimmed.runes.length <= _shortTextThreshold) {
      // 5b. Very short non-question text can be answered directly by S1.
      complexity = Complexity.simple;
      reasons.add('short');
    } else {
      // 6. Nothing matched; do not guess.
      complexity = Complexity.unsure;
      reasons.add('noRule');
    }

    // Group context is recorded but never changes the decision.
    if (inGroup) {
      reasons.add('group');
    }

    return Classification(complexity, List<String>.unmodifiable(reasons));
  }

  static bool _containsAny(String text, List<String> markers) {
    for (final String marker in markers) {
      if (text.contains(marker)) {
        return true;
      }
    }
    return false;
  }

  static bool _isGreeting(String lower) {
    for (final String token in _greetings) {
      if (_isAscii(token)) {
        // Match latin tokens on word boundaries so e.g. "this" is not "hi".
        final RegExp pattern = RegExp(
          '(^|[^a-z])${RegExp.escape(token)}([^a-z]|\$)',
        );
        if (pattern.hasMatch(lower)) {
          return true;
        }
      } else if (lower.contains(token)) {
        return true;
      }
    }
    return false;
  }

  static bool _isAscii(String token) =>
      token.codeUnits.every((int unit) => unit < 128);
}
