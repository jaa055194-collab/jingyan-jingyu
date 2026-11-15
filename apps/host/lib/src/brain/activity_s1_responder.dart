import 'package:jingyu_core/jingyu_core.dart';

import 'router.dart';
import 's1_responder.dart';

/// One recent activity record from the host `activity_log`, newest first.
///
/// The trusted source must only return records fresh enough to be described as
/// "刚" (just now); recency/freshness is the caller's responsibility. [id] must
/// be the real `activity_log` id so an S1 mention is always traceable.
class S1Activity {
  const S1Activity({required this.id, required this.summary});

  final String id;
  final String summary;
}

/// Trusted lookup of an AI's recent activities (host `activity_log`).
typedef S1ActivityLookup = Future<List<S1Activity>> Function(AiId ai);

/// S1 responder that may mention the AI's own recent activity (B-1 rule 5).
///
/// Only an exact status question triggers a lookup, and a mention always
/// carries the real `activity_log` id from the trusted [activities] source.
/// With no record (or a lookup error) it falls back and never invents an event.
/// Padding always delegates.
///
/// Reachability note: this fires only on the router's simple, non-padding S1
/// path. The classifier routes text containing a question marker (？ ? 吗 呢
/// 怎么 …) or length >6 code points to complex → padding + S2, so phrasings
/// like "你在干嘛？" never reach here. The phrase set is therefore limited to
/// reachable simple phrases; richer status handling would belong in the
/// classifier/routing layer.
class ActivityS1Responder implements S1Responder {
  ActivityS1Responder({required this.activities, S1Responder? fallback})
    : fallback = fallback ?? const RulesS1Responder();

  final S1ActivityLookup activities;
  final S1Responder fallback;

  static const List<String> _statusQueries = <String>[
    '你在干嘛',
    '在干嘛',
    '在做什么',
    '在忙什么',
  ];

  @override
  Future<S1Reply> replyTo(
    AiId ai,
    IncomingMessage message, {
    required bool padding,
  }) async {
    if (padding) {
      return fallback.replyTo(ai, message, padding: true);
    }
    final String text = message.text.trim();
    if (!_isStatusQuery(text)) {
      return fallback.replyTo(ai, message, padding: false);
    }
    final List<S1Activity> recent;
    try {
      recent = await activities(ai);
    } catch (_) {
      // A transient store/port error must not abort the fast S1 reply.
      return fallback.replyTo(ai, message, padding: false);
    }
    for (final S1Activity activity in recent) {
      final String id = activity.id.trim();
      final String summary = activity.summary.trim();
      if (id.isEmpty || summary.isEmpty) {
        continue;
      }
      return S1Reply('刚在$summary', activityRefs: <String>[id]);
    }
    return fallback.replyTo(ai, message, padding: false);
  }

  /// Matches only a whole status phrase (trailing punctuation ignored), so an
  /// embedded or quoted phrase (e.g. "他问你在干嘛") is not treated as a query.
  bool _isStatusQuery(String text) {
    final String normalized = text
        .replaceFirst(RegExp(r'[？?！!。.～~\s]+$'), '')
        .trim();
    return _statusQueries.contains(normalized);
  }
}
