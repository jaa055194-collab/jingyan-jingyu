/// M07 brain - three-layer meme library and AI proposal inbox (FR-47).
///
/// Pure Dart: no IO, no network, no model calls. Matching uses the regular
/// expression triggers that ship with each meme by default, plus an optional
/// injected [SemanticMemeMatcher] that stands in for the embedding binding
/// described in FR-47 (a `chat.fast`/embedding provider is wired later, never
/// here).
///
/// The three layers follow `鲸言鲸语-需求规格-v4.2.md` FR-47:
/// * [MemeLayer.general]  - general internet slang, shipped with the product;
/// * [MemeLayer.circle]   - circle memes, user-defined and shared in a circle;
/// * [MemeLayer.personal] - inside memes grown between one AI and one user.
///
/// More specific layers win when several match, so a personal inside joke is
/// never shadowed by a generic slang entry. Every meme may carry an expiry
/// (`expiresAt`) because slang ages out; an expired meme is simply no longer
/// active.
///
/// AI-generated memes are never inserted directly. They go through
/// [MemeLibrary.propose] into a proposal inbox (FR-56 style inbox) and only
/// become a usable [Meme] after [MemeLibrary.approve]; [MemeLibrary.reject]
/// drops a proposal without creating a meme.
library;

/// Which of the three meme layers a [Meme] belongs to.
enum MemeLayer {
  /// General network slang, shipped and updated with the product.
  general,

  /// User-defined circle meme, shared inside a circle.
  circle,

  /// Inside meme grown between one AI and one user.
  personal,
}

/// Rank of a layer; a larger rank is more specific and preferred on a match.
int _layerRank(MemeLayer layer) => switch (layer) {
  MemeLayer.general => 0,
  MemeLayer.circle => 1,
  MemeLayer.personal => 2,
};

/// Optional semantic matcher, the seam over an embedding provider (FR-47).
///
/// When supplied to a [MemeLibrary], a meme is considered a hit if either its
/// regular expression triggers or this matcher match. When it is absent (the
/// provider is not bound), matching stays regex-only, per `02-decisions.md`
/// B-1 rule 7.
typedef SemanticMemeMatcher = bool Function(Meme meme, String text);

/// One meme entry.
///
/// Immutable value object. [regexTriggers] and [keywords] are exposed as
/// unmodifiable lists.
class Meme {
  /// Creates a meme.
  ///
  /// Each trigger string is compiled eagerly so a malformed pattern fails at
  /// construction instead of at match time.
  Meme({
    required this.id,
    required this.layer,
    required this.reply,
    List<String> regexTriggers = const <String>[],
    List<String> keywords = const <String>[],
    this.occasion,
    this.relationship,
    this.expiresAt,
  }) : assert(id.isNotEmpty, 'meme id must not be empty'),
       assert(reply.isNotEmpty, 'meme reply must not be empty'),
       regexTriggers = List<String>.unmodifiable(regexTriggers),
       keywords = List<String>.unmodifiable(keywords),
       _patterns = List<RegExp>.unmodifiable(
         regexTriggers.map((String pattern) => RegExp(pattern)),
       );

  /// Stable meme id.
  final String id;

  /// Which layer this meme belongs to.
  final MemeLayer layer;

  /// Short reply text produced when the meme is hit (FR-46: <= 30 chars).
  final String reply;

  /// Regular expression triggers used by the default matcher.
  final List<String> regexTriggers;

  /// Plain keyword triggers; matched with [String.contains] as a cheap
  /// fallback that never throws on user text.
  final List<String> keywords;

  /// Occasion the meme applies to, e.g. `group` or `private`. Null means any.
  final String? occasion;

  /// Relationship scope the meme applies to, e.g. a friend account id. Null
  /// means any relationship.
  final String? relationship;

  /// When this meme stops being active. Null means it never expires.
  final DateTime? expiresAt;

  final List<RegExp> _patterns;

  /// Whether the meme is still active at [now].
  bool isActiveAt(DateTime now) {
    final DateTime? until = expiresAt;
    return until == null || now.isBefore(until);
  }

  /// Whether the meme may be used for the given occasion/relationship.
  ///
  /// A null field on the meme acts as a wildcard; a non-null field must match
  /// the supplied context exactly.
  bool appliesTo({String? contextOccasion, String? contextRelationship}) {
    final String? wantedOccasion = occasion;
    if (wantedOccasion != null && wantedOccasion != contextOccasion) {
      return false;
    }
    final String? wantedRelationship = relationship;
    if (wantedRelationship != null &&
        wantedRelationship != contextRelationship) {
      return false;
    }
    return true;
  }

  /// Whether [text] hits this meme.
  ///
  /// A regular-expression trigger or keyword trigger matching is enough; when
  /// [semantic] is supplied an additional semantic hit also counts.
  bool matches(String text, {SemanticMemeMatcher? semantic}) {
    for (final RegExp pattern in _patterns) {
      if (pattern.hasMatch(text)) {
        return true;
      }
    }
    for (final String keyword in keywords) {
      if (keyword.isNotEmpty && text.contains(keyword)) {
        return true;
      }
    }
    if (semantic != null && semantic(this, text)) {
      return true;
    }
    return false;
  }

  @override
  String toString() => 'Meme($id, $layer, "$reply")';
}

/// Status of an AI-proposed meme inside the inbox.
enum MemeProposalStatus {
  /// Waiting for a human/owner decision.
  pending,

  /// Converted into a usable [Meme].
  approved,

  /// Discarded; no meme is created.
  rejected,
}

/// An AI-proposed meme living in the proposal inbox (FR-47, FR-56).
///
/// [status] is advanced only through [MemeLibrary.approve] /
/// [MemeLibrary.reject]; callers should treat it as read-only.
class MemeProposal {
  /// Creates a proposal. New proposals are [MemeProposalStatus.pending].
  MemeProposal({
    required this.id,
    required this.ai,
    required this.suggestedReply,
    List<String> suggestedTriggers = const <String>[],
    this.reason,
    this.createdAt,
    this.status = MemeProposalStatus.pending,
  }) : suggestedTriggers = List<String>.unmodifiable(suggestedTriggers);

  /// Stable proposal id (also used to derive the approved meme id).
  final String id;

  /// The AI that proposed the meme.
  final String ai;

  /// The reply text the AI suggests.
  final String suggestedReply;

  /// Regex triggers the AI suggests; may be empty when only a semantic hint
  /// exists.
  final List<String> suggestedTriggers;

  /// Optional rationale the AI gives for the proposal.
  final String? reason;

  /// When the proposal was made, when the caller supplied it.
  final DateTime? createdAt;

  /// Current inbox status.
  MemeProposalStatus status;

  @override
  String toString() => 'MemeProposal($id, ai=$ai, $status)';
}

/// Result of a successful meme lookup.
class MemeMatch {
  /// Wraps the winning [meme].
  const MemeMatch(this.meme);

  /// The meme that matched.
  final Meme meme;

  @override
  String toString() => 'MemeMatch(${meme.id})';
}

/// In-memory three-layer meme store plus proposal inbox.
///
/// This is intentionally a plain value holder with no persistence; the host
/// owns storage and lifetime. Methods never mutate the caller's lists.
class MemeLibrary {
  /// Creates a library, optionally seeding memes and a semantic matcher.
  MemeLibrary({
    List<Meme> memes = const <Meme>[],
    SemanticMemeMatcher? semanticMatcher,
  }) : _memes = <Meme>[...memes],
       _semanticMatcher = semanticMatcher;

  final List<Meme> _memes;
  final List<MemeProposal> _proposals = <MemeProposal>[];
  final SemanticMemeMatcher? _semanticMatcher;

  /// All memes, in insertion order.
  List<Meme> get memes => List<Meme>.unmodifiable(_memes);

  /// All proposals, pending and resolved, in insertion order.
  List<MemeProposal> get proposals =>
      List<MemeProposal>.unmodifiable(_proposals);

  /// Proposals still waiting for a decision.
  List<MemeProposal> get pendingProposals => List<MemeProposal>.unmodifiable(
    _proposals.where(
      (MemeProposal p) => p.status == MemeProposalStatus.pending,
    ),
  );

  /// Adds a meme. Throws [ArgumentError] when the id is already present.
  void add(Meme meme) {
    if (_memes.any((Meme existing) => existing.id == meme.id)) {
      throw ArgumentError.value(meme.id, 'meme.id', 'duplicate meme id');
    }
    _memes.add(meme);
  }

  /// Memes active at [now], in insertion order.
  List<Meme> activeAt(DateTime now) => List<Meme>.unmodifiable(
    _memes.where((Meme meme) => meme.isActiveAt(now)),
  );

  /// Memes already expired at [now], in insertion order.
  List<Meme> expiredAt(DateTime now) => List<Meme>.unmodifiable(
    _memes.where((Meme meme) => !meme.isActiveAt(now)),
  );

  /// Finds the best active meme for [text].
  ///
  /// Only memes active at [now] and applicable to the given occasion and
  /// relationship are considered. Among matches the most specific layer wins
  /// (personal > circle > general); ties keep the earliest inserted meme.
  /// Returns null when nothing matches, so the caller can degrade to a natural
  /// follow-up question instead of forcing a joke.
  Meme? find(
    String text, {
    required DateTime now,
    String? occasion,
    String? relationship,
  }) {
    Meme? best;
    for (final Meme meme in _memes) {
      if (!meme.isActiveAt(now)) {
        continue;
      }
      if (!meme.appliesTo(
        contextOccasion: occasion,
        contextRelationship: relationship,
      )) {
        continue;
      }
      if (!meme.matches(text, semantic: _semanticMatcher)) {
        continue;
      }
      if (best == null || _layerRank(meme.layer) > _layerRank(best.layer)) {
        best = meme;
      }
    }
    return best;
  }

  /// Convenience wrapper around [find] that reports a [MemeMatch].
  MemeMatch? match(
    String text, {
    required DateTime now,
    String? occasion,
    String? relationship,
  }) {
    final Meme? meme = find(
      text,
      now: now,
      occasion: occasion,
      relationship: relationship,
    );
    return meme == null ? null : MemeMatch(meme);
  }

  /// Records an AI-proposed meme in the inbox as [MemeProposalStatus.pending].
  ///
  /// No meme is created here; the proposal must be approved first.
  MemeProposal propose({
    required String id,
    required String ai,
    required String suggestedReply,
    List<String> suggestedTriggers = const <String>[],
    String? reason,
    DateTime? createdAt,
  }) {
    if (_proposals.any((MemeProposal p) => p.id == id)) {
      throw ArgumentError.value(id, 'proposal.id', 'duplicate proposal id');
    }
    final MemeProposal proposal = MemeProposal(
      id: id,
      ai: ai,
      suggestedReply: suggestedReply,
      suggestedTriggers: suggestedTriggers,
      reason: reason,
      createdAt: createdAt,
    );
    _proposals.add(proposal);
    return proposal;
  }

  /// Approves a pending proposal, creating and returning a [Meme].
  ///
  /// The new meme reuses the proposal's id (prefixed `meme-`) and suggested
  /// triggers. Throws [ArgumentError] when the proposal is unknown or already
  /// resolved.
  Meme approve(String proposalId, {MemeLayer layer = MemeLayer.personal}) {
    final MemeProposal proposal = _pending(proposalId);
    final Meme meme = Meme(
      id: 'meme-$proposalId',
      layer: layer,
      reply: proposal.suggestedReply,
      regexTriggers: proposal.suggestedTriggers,
    );
    _memes.add(meme);
    proposal.status = MemeProposalStatus.approved;
    return meme;
  }

  /// Rejects a pending proposal without creating a meme.
  ///
  /// Throws [ArgumentError] when the proposal is unknown or already resolved.
  void reject(String proposalId) {
    _pending(proposalId).status = MemeProposalStatus.rejected;
  }

  MemeProposal _pending(String proposalId) {
    for (final MemeProposal proposal in _proposals) {
      if (proposal.id == proposalId) {
        if (proposal.status != MemeProposalStatus.pending) {
          throw ArgumentError.value(
            proposalId,
            'proposal.id',
            'proposal already resolved',
          );
        }
        return proposal;
      }
    }
    throw ArgumentError.value(proposalId, 'proposal.id', 'unknown proposal');
  }
}
