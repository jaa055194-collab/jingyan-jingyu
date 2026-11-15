/// M07 brain · rules-first S1/S2 routing core.
///
/// Pure Dart: no IO, network, or real model calls. [RulesFirstBrainRouter]
/// composes the existing [RuleClassifier] with two injected responder ports and
/// an optional group-posting gate, so routing can be unit-tested with fake
/// responders that only count how often they are invoked (AC-33).
///
/// Routing follows `02-decisions.md` B-1:
/// * `simple`      -> S1 only; S2 is never started.
/// * `complex`     -> optional S1 padding (configurable) then S2.
/// * `unsure`      -> treated as `complex` (escalate to S2).
///
/// Group admission is delegated to an injected [GroupPostPolicy]; when it
/// denies a group message, [RulesFirstBrainRouter.respond] yields no output.
library;

import 'package:jingyu_core/jingyu_core.dart';

import 'classifier.dart';
import 'pacing.dart';

/// One outbound chat piece produced by the router.
///
/// Immutable value object. [source] is either `s1` or `s2`; [activityRefs]
/// carries the `activity_log` ids an S1 reply cites (empty for S2 and for S1
/// replies that reference nothing).
class OutgoingPiece {
  OutgoingPiece({
    required this.text,
    required this.source,
    List<String> activityRefs = const <String>[],
  }) : assert(source == 's1' || source == 's2', 'source must be s1 or s2'),
       activityRefs = List<String>.unmodifiable(activityRefs);

  /// The message text.
  final String text;

  /// Which responder produced this piece: `s1` or `s2`.
  final String source;

  /// `activity_log` ids cited by an S1 reply. Never fabricated here.
  final List<String> activityRefs;

  @override
  String toString() =>
      'OutgoingPiece($source, "$text", activityRefs=$activityRefs)';
}

/// The routing decision for one incoming message.
///
/// Immutable value object. [reasons] mirrors the classifier's rule tags and is
/// intended for logging only.
class BrainDecision {
  BrainDecision({
    required this.complexity,
    required this.sendPadding,
    required List<String> reasons,
  }) : reasons = List<String>.unmodifiable(reasons);

  /// The judged complexity.
  final Complexity complexity;

  /// Whether an S1 padding line should be sent before the S2 answer.
  final bool sendPadding;

  /// Rule tags explaining the decision, e.g. `greeting`, `question`, `group`.
  final List<String> reasons;

  @override
  String toString() =>
      'BrainDecision($complexity, sendPadding=$sendPadding, $reasons)';
}

/// A normalized inbound message handed to the router.
///
/// Kept deliberately small and transport-agnostic; the host maps its protocol
/// message onto this. Group metadata ([inGroup], [mentioned], [roundId]) is
/// carried so the [GroupPostPolicy] seam can make an admission decision.
class IncomingMessage {
  const IncomingMessage({
    required this.id,
    required this.text,
    this.conversationId,
    this.senderId,
    this.inGroup = false,
    this.mentioned = false,
    this.roundId,
  });

  /// Stable message id.
  final String id;

  /// Raw message text.
  final String text;

  /// Conversation the message arrived in, when known.
  final ConversationId? conversationId;

  /// Human sender, when known.
  final AccountId? senderId;

  /// Whether this arrived in a group chat.
  final bool inGroup;

  /// Whether the AI was explicitly mentioned (group context only).
  final bool mentioned;

  /// Group round id, used by group admission (group context only).
  final String? roundId;
}

/// Output produced by an S1 responder.
///
/// [activityRefs] must only contain ids that exist in the host `activity_log`;
/// the router never invents them.
class S1Reply {
  const S1Reply(this.text, {this.activityRefs = const <String>[]});

  /// The S1 reply text.
  final String text;

  /// `activity_log` ids cited by this reply. Defaults to empty.
  final List<String> activityRefs;
}

/// Port for the S1 responder (fast, cheap, rule/template driven).
abstract class S1Responder {
  /// Produce an S1 reply.
  ///
  /// When [padding] is true the reply is a short filler sent before S2; when
  /// false it is a complete direct answer for a `simple` message.
  Future<S1Reply> replyTo(
    AiId ai,
    IncomingMessage message, {
    required bool padding,
  });
}

/// Port for the S2 responder (main dialog, streaming).
abstract class S2Responder {
  /// Stream the main answer as text chunks.
  Stream<String> respond(AiId ai, IncomingMessage message);
}

/// Port deciding whether an AI may post into a group.
///
/// Adapter seam over M04's `GroupAiPolicy.mayPost`; kept abstract so the brain
/// module has no storage dependency and tests can deny/allow cheaply.
abstract class GroupPostPolicy {
  /// Returns true when the AI may post in response to [message].
  Future<bool> mayPost(AiId ai, IncomingMessage message);
}

/// The brain's routing contract, matching `docs/modules/M07-brain.md`.
abstract class BrainRouter {
  /// Decide how to handle [message].
  Future<BrainDecision> decide(
    AiId ai,
    IncomingMessage message, {
    required bool inGroup,
  });

  /// Produce the outbound pieces for [message] according to [decision].
  Stream<OutgoingPiece> respond(
    AiId ai,
    IncomingMessage message,
    BrainDecision decision,
  );
}

/// Rules-first router: [RuleClassifier] decides, injected ports produce output.
class RulesFirstBrainRouter implements BrainRouter {
  RulesFirstBrainRouter({
    RuleClassifier classifier = const RuleClassifier(),
    required S1Responder s1,
    required S2Responder s2,
    GroupPostPolicy? groupPolicy,
    HumanPacing? pacing,
    this.enablePadding = true,
    Future<void> Function(Duration delay)? sleep,
  }) : _classifier = classifier,
       _s1 = s1,
       _s2 = s2,
       _groupPolicy = groupPolicy,
       _pacing = pacing,
       _sleep = sleep ?? _defaultSleep;

  final RuleClassifier _classifier;
  final S1Responder _s1;
  final S2Responder _s2;
  final GroupPostPolicy? _groupPolicy;
  final HumanPacing? _pacing;
  final Future<void> Function(Duration delay) _sleep;

  /// Whether a `complex`/`unsure` message may get an S1 padding line first.
  final bool enablePadding;

  static Future<void> _defaultSleep(Duration delay) =>
      Future<void>.delayed(delay);

  @override
  Future<BrainDecision> decide(
    AiId ai,
    IncomingMessage message, {
    required bool inGroup,
  }) async {
    final Classification classification =
        _classifier.classify(message.text, inGroup: inGroup);
    final bool sendPadding =
        enablePadding && classification.complexity != Complexity.simple;
    return BrainDecision(
      complexity: classification.complexity,
      sendPadding: sendPadding,
      reasons: classification.reasons,
    );
  }

  @override
  Stream<OutgoingPiece> respond(
    AiId ai,
    IncomingMessage message,
    BrainDecision decision,
  ) async* {
    // Group admission first: a denied post produces no output at all.
    final GroupPostPolicy? policy = _groupPolicy;
    if (message.inGroup && policy != null) {
      final bool allowed = await policy.mayPost(ai, message);
      if (!allowed) {
        return;
      }
    }

    if (decision.complexity == Complexity.simple) {
      await _pace(message.text);
      final S1Reply reply = await _s1.replyTo(ai, message, padding: false);
      yield _piece(reply, 's1');
      return;
    }

    // complex or unsure: optional padding, then S2.
    if (decision.sendPadding) {
      final S1Reply padding = await _s1.replyTo(ai, message, padding: true);
      yield _piece(padding, 's1');
    }
    await _pace(message.text);
    await for (final String chunk in _s2.respond(ai, message)) {
      yield OutgoingPiece(text: chunk, source: 's2');
    }
  }

  OutgoingPiece _piece(S1Reply reply, String source) => OutgoingPiece(
    text: reply.text,
    source: source,
    activityRefs: reply.activityRefs,
  );

  Future<void> _pace(String text) async {
    final HumanPacing? pacing = _pacing;
    if (pacing == null) {
      return;
    }
    final Duration delay = pacing.delayFor(text);
    if (delay > Duration.zero) {
      await _sleep(delay);
    }
  }
}
