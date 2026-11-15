import 'package:jingyu_core/jingyu_core.dart';

import 'router.dart';

/// Offline, rule-only fallback for M07 (FR-46 and decisions B-1/B-5).
///
/// Deliberately limited to curated social reactions: no model, memory writes,
/// promises, user/world facts or invented life events. No activity-log adapter
/// is bound, so every reply has empty activity references. The router owns
/// classification, group admission, pacing and the `source=s1` marker.
///
/// This is not default-host wiring or a budget gate. A caller can inject this
/// into [RulesFirstBrainRouter] when `chat.fast` is absent or unavailable.
class RulesS1Responder implements S1Responder {
  const RulesS1Responder();

  // Match the entire normalized message, never a greeting substring within an
  // action request, negative statement or quoted/factual text.
  static final RegExp _trailingPunctuation = RegExp(r'[!！.。]+$');
  static const Map<String, String> _reactions = <String, String>{
    '你好': '你好呀',
    'hello': '你好呀',
    '早安': '早呀',
    '晚安': '晚安',
    '收到': '嗯嗯',
    '好的': '嗯嗯',
    '谢谢': '不客气',
    '👍': '👍',
    '😂': '😂',
  };

  @override
  Future<S1Reply> replyTo(
    AiId ai,
    IncomingMessage message, {
    required bool padding,
  }) async {
    // Padding must remain neutral even for distressing or adversarial input.
    if (padding) return const S1Reply('嗯……');
    final String token = message.text.trim().toLowerCase().replaceFirst(
      _trailingPunctuation,
      '',
    );
    return S1Reply(_reactions[token] ?? '愿意多说一点吗？');
  }
}
