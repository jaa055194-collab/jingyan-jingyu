import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:material_ui/material_ui.dart';

import 'jy_interaction.dart';
import 'jy_motion.dart';
import 'jy_palette.dart';
import 'jy_tokens.dart';

/// Cards of one kind gathered into a deck (MASTER.md section 7, item 4).
///
/// Collapsed, [children] first is on top and up to [maxPeek] cards peek out
/// behind it, at 0.95 and 0.90 scale, 8 and 16px lower and fading. Those
/// back cards stay in the tree but ignore pointers and are left out of
/// semantics. The [summary] row above the deck is its own button, at least
/// [JySpace.touchTarget] tall, with an expanded state; tapping it opens the
/// deck into a list whose cards come in 30ms apart and settle with the
/// spring, and tapping it again gathers them up. The deck never takes taps
/// from buttons inside a card.
///
/// Pass [expanded] to control it from outside; [onExpandedChanged] is
/// called either way. A deck of one card shows just that card, and an empty
/// deck shows nothing. With reduced motion the change is a short fade.
class JyStackDeck extends StatefulWidget {
  const JyStackDeck({
    super.key,
    required this.children,
    required this.summary,
    this.expanded,
    this.onExpandedChanged,
    this.maxPeek = 2,
  });

  final List<Widget> children;

  /// Text of the summary row, such as 「3 条好友邀请」.
  final String summary;

  /// Whether the deck is open; null lets the deck keep its own state.
  final bool? expanded;
  final ValueChanged<bool>? onExpandedChanged;

  /// How many cards peek out behind the top one while collapsed.
  final int maxPeek;

  @override
  State<JyStackDeck> createState() => _JyStackDeckState();
}

class _JyStackDeckState extends State<JyStackDeck>
    with SingleTickerProviderStateMixin {
  late bool _ownExpanded = widget.expanded ?? false;
  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: _open ? 1 : 0,
  );

  bool get _open => widget.expanded ?? _ownExpanded;

  /// Cards that animate when the deck opens; later ones simply follow.
  static const int _staggeredCount = 8;

  Duration get _openDuration =>
      JyDurations.emphasized +
      JyDurations.stagger *
          (widget.children.length - 1).clamp(0, _staggeredCount - 1);

  @override
  void didUpdateWidget(JyStackDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool wasOpen = oldWidget.expanded ?? _ownExpanded;
    if (wasOpen != _open) {
      _run(_open);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _run(bool open) {
    final bool reduced = JyMotion.reducedOf(context);
    _controller
      ..duration = reduced ? JyDurations.reduced : _openDuration
      ..reverseDuration = reduced
          ? JyDurations.reduced
          : JyDurations.exit(JyDurations.standard);
    if (open) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _toggle() {
    final bool next = !_open;
    if (widget.expanded == null) {
      setState(() => _ownExpanded = next);
      _run(next);
    }
    widget.onExpandedChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> cards = widget.children;
    if (cards.isEmpty) {
      return const SizedBox.shrink();
    }
    if (cards.length == 1) {
      return cards.first;
    }
    final bool reduced = JyMotion.reducedOf(context);
    final Widget deck = AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? _) {
        if (_controller.isDismissed) {
          return _collapsed(cards);
        }
        return _expanded(cards, reduced);
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _SummaryRow(summary: widget.summary, open: _open, onTap: _toggle),
        RepaintBoundary(
          // With reduced motion the height changes at once.
          child: reduced
              ? deck
              : AnimatedSize(
                  duration: JyDurations.standard,
                  curve: JyCurves.enter,
                  alignment: AlignmentDirectional.topCenter,
                  child: deck,
                ),
        ),
      ],
    );
  }

  Widget _collapsed(List<Widget> cards) {
    final int peek = widget.maxPeek.clamp(0, cards.length - 1);
    return Padding(
      padding: EdgeInsets.only(bottom: JySpace.sm * peek),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          for (int depth = peek; depth >= 1; depth--)
            Positioned.fill(
              child: IgnorePointer(
                child: ExcludeSemantics(
                  child: Opacity(
                    opacity: (1 - 0.3 * depth).clamp(0.1, 1).toDouble(),
                    child: Transform.translate(
                      offset: Offset(0, JySpace.sm * depth),
                      child: Transform.scale(
                        scale: 1 - 0.05 * depth,
                        alignment: Alignment.bottomCenter,
                        child: ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.topCenter,
                            minHeight: 0,
                            maxHeight: double.infinity,
                            child: KeyedSubtree(
                              key: ValueKey<int>(depth),
                              child: cards[depth],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          KeyedSubtree(key: const ValueKey<int>(0), child: cards.first),
        ],
      ),
    );
  }

  Widget _expanded(List<Widget> cards, bool reduced) {
    // A deck that starts open has not run yet, so it has no duration.
    final double total = (_controller.duration ?? _openDuration).inMicroseconds
        .toDouble();
    final double span = JyDurations.emphasized.inMicroseconds / total;
    final double raw = _controller.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < cards.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: JySpace.sm),
          _card(i, cards[i], raw, total, span, reduced),
        ],
      ],
    );
  }

  Widget _card(
    int i,
    Widget card,
    double raw,
    double total,
    double span,
    bool reduced,
  ) {
    final Widget keyed = KeyedSubtree(key: ValueKey<int>(i), child: card);
    if (i == 0) {
      return keyed;
    }
    if (reduced) {
      return Opacity(opacity: raw, child: keyed);
    }
    final int slot = i.clamp(1, _staggeredCount - 1);
    final double start = (JyDurations.stagger * slot).inMicroseconds / total;
    final double end = (start + span).clamp(0, 1).toDouble();
    final double t = _controller.status == AnimationStatus.reverse
        ? JyCurves.exitReverse.transform(raw)
        : Interval(start, end, curve: const _SpringCurve()).transform(raw);
    final double fade = Interval(
      start,
      end,
      curve: JyCurves.enter,
    ).transform(raw);
    return Opacity(
      opacity: _controller.status == AnimationStatus.reverse ? t : fade,
      child: Transform.translate(
        offset: Offset(0, -JySpace.lg * (1 - t)),
        child: Transform.scale(scale: 0.95 + 0.05 * t, child: keyed),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.summary,
    required this.open,
    required this.onTap,
  });

  final String summary;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    return MergeSemantics(
      child: Semantics(
        expanded: open,
        child: JyPressable(
          onTap: onTap,
          borderRadius: BorderRadius.circular(JyRadius.md),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: JySpace.touchTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: JySpace.xs),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      summary,
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(color: palette.text1),
                    ),
                  ),
                  JyChevron(expanded: open),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [JyCurves.spring] from rest at 0 to 1, as a curve over its settling time.
class _SpringCurve extends Curve {
  const _SpringCurve();

  /// Time the spring takes to settle within tolerance, in seconds.
  static const double _seconds = 0.36;

  @override
  double transformInternal(double t) =>
      SpringSimulation(JyCurves.spring, 0, 1, 0).x(t * _seconds);
}
