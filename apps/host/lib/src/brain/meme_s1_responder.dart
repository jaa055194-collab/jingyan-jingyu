import 'package:jingyu_core/jingyu_core.dart';

import 'meme_library.dart';
import 'router.dart';
import 's1_responder.dart';

/// S1 responder that prefers an active meme hit (FR-46 接梗 / FR-47 梗库)
/// before falling back to curated rules.
///
/// Memes are curated (product/user/AI-approved); this only replays their short
/// reply and never generates facts, promises or user/world assertions. Padding
/// always delegates to [fallback] so it stays neutral. Sets no activity refs.
class MemeS1Responder implements S1Responder {
  MemeS1Responder({
    required this.memes,
    required this.clock,
    S1Responder? fallback,
    this.maxReplyChars = 30,
  }) : fallback = fallback ?? const RulesS1Responder(),
       assert(maxReplyChars > 0, 'maxReplyChars must be positive');

  final MemeLibrary memes;
  final Clock clock;
  final S1Responder fallback;
  final int maxReplyChars;

  @override
  Future<S1Reply> replyTo(
    AiId ai,
    IncomingMessage message, {
    required bool padding,
  }) async {
    // Padding must stay neutral even if the message happens to match a meme.
    if (padding) {
      return fallback.replyTo(ai, message, padding: true);
    }
    final String text = message.text.trim();
    if (text.isEmpty) {
      return fallback.replyTo(ai, message, padding: false);
    }
    // Occasion-scoped memes are reachable via the group/private signal; the
    // per-relationship scope is not threaded here (needs M04 relationship data)
    // and is documented as a gap rather than silently assumed.
    final String occasion = message.inGroup ? 'group' : 'private';
    final Meme? meme = memes.find(text, now: clock.now(), occasion: occasion);
    if (meme == null) {
      return fallback.replyTo(ai, message, padding: false);
    }
    return S1Reply(_clamp(meme.reply));
  }

  /// Keeps S1 接梗 within FR-46's short-reply bound without splitting a scalar.
  String _clamp(String text) {
    final List<int> runes = text.runes.toList(growable: false);
    if (runes.length <= maxReplyChars) {
      return text;
    }
    return '${String.fromCharCodes(runes.take(maxReplyChars - 1))}…';
  }
}
