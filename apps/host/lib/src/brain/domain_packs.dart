/// M07 brain - lightweight per-domain knowledge packs (FR-47).
///
/// Pure Dart: no network, no RSS fetching, no persistence. A domain pack is a
/// small card (glossary, current hotspots, the AI's stance/preferences) that the
/// router injects into the S2 context for **one turn only** when the user is
/// talking about that domain. Packs are capped at [DomainPack.render]'s
/// `maxChars` (500 code points by default), and the resulting
/// [DomainInjection] is explicitly ephemeral: the host must not write it into
/// message history (FR-47, `02-decisions.md`).
///
/// When the user mentions a domain the host knows about but has no card for,
/// [DomainPackRegistry.injectionFor] reports [DomainInjectionStatus.unfamiliar]
/// so S2 can answer honestly ("这个我不熟") instead of improvising facts.
library;

/// One domain knowledge card.
///
/// Immutable value object. [keywords] is unmodifiable.
class DomainPack {
  /// Creates a domain pack.
  DomainPack({
    required this.domain,
    List<String> keywords = const <String>[],
    this.glossary = '',
    this.hotspots = '',
    this.stance = '',
  }) : assert(domain.isNotEmpty, 'domain must not be empty'),
       keywords = List<String>.unmodifiable(keywords);

  /// Domain name, e.g. `游戏` or `美食`.
  final String domain;

  /// Plain keywords that signal the user is talking about this domain.
  final List<String> keywords;

  /// Glossary / terminology text for this domain.
  final String glossary;

  /// Current hotspots / trending text for this domain.
  final String hotspots;

  /// The AI's stance and preferences (sourced from the persona P1 layer).
  final String stance;

  /// Whether [text] mentions this domain via any of its keywords.
  bool mentions(String text) {
    for (final String keyword in keywords) {
      if (keyword.isNotEmpty && text.contains(keyword)) {
        return true;
      }
    }
    return false;
  }

  /// Renders the card into an injectable context block of at most [maxChars]
  /// Unicode code points.
  ///
  /// The block is assembled in a fixed order (术语 / 热点 / 立场) and truncated
  /// with a trailing `…` when it would exceed the budget, so it can never blow
  /// the per-domain context cap.
  String render({int maxChars = 500}) {
    if (maxChars <= 0) {
      return '';
    }
    final List<String> parts = <String>[];
    if (glossary.isNotEmpty) {
      parts.add('术语：$glossary');
    }
    if (hotspots.isNotEmpty) {
      parts.add('热点：$hotspots');
    }
    if (stance.isNotEmpty) {
      parts.add('立场：$stance');
    }
    return _truncate(parts.join('\n'), maxChars);
  }

  static String _truncate(String text, int maxChars) {
    final List<int> runes = text.runes.toList(growable: false);
    if (runes.length <= maxChars) {
      return text;
    }
    // Reserve one code point for the ellipsis so the result stays <= maxChars.
    final String head = String.fromCharCodes(runes.take(maxChars - 1));
    return '$head…';
  }

  @override
  String toString() => 'DomainPack($domain)';
}

/// Outcome of a domain lookup.
enum DomainInjectionStatus {
  /// A registered pack was matched and its rendered text should be injected.
  injected,

  /// The domain is known but has no pack; S2 should say it is unfamiliar.
  unfamiliar,

  /// The text does not mention any known domain; no injection, answer normally.
  none,
}

/// The (possibly empty) result of looking up a domain for a message.
///
/// The [text] of an injected result is **ephemeral**: it is meant for the
/// current S2 turn only and must never be persisted into history.
class DomainInjection {
  const DomainInjection._({
    required this.status,
    this.domain,
    this.text = '',
  });

  /// A successful injection for [domain] with rendered [text].
  const DomainInjection.injected({
    required String domain,
    required String text,
  }) : this._(
         status: DomainInjectionStatus.injected,
         domain: domain,
         text: text,
       );

  /// A known [domain] that has no pack.
  const DomainInjection.unfamiliar(String domain)
    : this._(status: DomainInjectionStatus.unfamiliar, domain: domain);

  /// No domain was detected.
  const DomainInjection.none()
    : this._(status: DomainInjectionStatus.none);

  /// The lookup outcome.
  final DomainInjectionStatus status;

  /// The domain involved, when one was detected.
  final String? domain;

  /// The rendered, per-turn-only context block (empty unless injected).
  final String text;

  /// Whether a pack was injected.
  bool get isInjected => status == DomainInjectionStatus.injected;

  /// Whether a known domain had no pack.
  bool get isUnfamiliar => status == DomainInjectionStatus.unfamiliar;

  /// Injections are always single-turn; there is no persistence path here.
  bool get ephemeral => true;

  @override
  String toString() => 'DomainInjection($status, domain=$domain)';
}

/// Registry of domain packs plus the set of domains the host knows about.
class DomainPackRegistry {
  /// Creates a registry.
  ///
  /// [knownDomains] lists domains that exist conceptually but may not have a
  /// pack yet; mentioning one yields [DomainInjectionStatus.unfamiliar].
  DomainPackRegistry({
    List<DomainPack> packs = const <DomainPack>[],
    List<String> knownDomains = const <String>[],
    this.maxChars = 500,
  }) : _packs = <String, DomainPack>{
         for (final DomainPack pack in packs) pack.domain: pack,
       },
       _knownDomains = List<String>.unmodifiable(knownDomains),
       assert(maxChars > 0, 'maxChars must be positive');

  final Map<String, DomainPack> _packs;
  final List<String> _knownDomains;

  /// Per-domain cap applied to every rendered injection.
  final int maxChars;

  /// Registered packs by domain name.
  Map<String, DomainPack> get packs => Map<String, DomainPack>.unmodifiable(
    _packs,
  );

  /// Looks up the domain for [text] and produces a single-turn injection.
  ///
  /// Registered packs are checked first; the first pack whose keywords appear
  /// wins. If none match, a known-but-packless domain produces
  /// [DomainInjectionStatus.unfamiliar]. Otherwise the status is
  /// [DomainInjectionStatus.none] and S2 answers without extra context.
  DomainInjection injectionFor(String text) {
    for (final DomainPack pack in _packs.values) {
      if (pack.mentions(text)) {
        return DomainInjection.injected(
          domain: pack.domain,
          text: pack.render(maxChars: maxChars),
        );
      }
    }
    for (final String domain in _knownDomains) {
      if (domain.isNotEmpty && text.contains(domain)) {
        return DomainInjection.unfamiliar(domain);
      }
    }
    return const DomainInjection.none();
  }
}
