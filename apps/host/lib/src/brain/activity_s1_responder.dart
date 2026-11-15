import 'package:jingyu_core/jingyu_core.dart';

import 'router.dart';
import 's1_responder.dart';

/// One recent activity record from the host `activity_log`, newest first.
class S1Activity {
  const S1Activity({required this.id, required this.summary});

  final String id;
  final String summary;
}

/// Trusted lookup of an AI's recent activities (host `activity_log`).
typedef S1ActivityLookup = Future<List<S1Activity>> Function(AiId ai);

/// S1 responder that may mention the AI's own recent activity (B-1 rule 5).
///
/// Only a status question triggers a lookup, and a mention always carries the
/// real `activity_log` id from the trusted [activities] source. With no record
/// it falls back and never invents an event. Padding always delegates.
class ActivityS1Responder implements S1Responder {
  ActivityS1Responder({required this.activities, S1Responder? fallback})
    : fallback = fallback ?? const RulesS1Responder();

  final S1ActivityLookup activities;
  final S1Responder fallback;

  static const List<String> _statusQueries = <String>[
    '你在干嘛',
    '在干嘛',
    '在做什么',
    '做什么呢',
    '干嘛呢',
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
    final List<S1Activity> recent = await activities(ai);
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

  bool _isStatusQuery(String text) =>
      _statusQueries.any((String phrase) => text.contains(phrase));
}
