import 'package:flutter/physics.dart' show SpringSimulation;
import 'package:material_ui/material_ui.dart';

import 'jy_motion.dart';
import 'jy_palette.dart';
import 'jy_tokens.dart';

/// How far the dock labels grow with the system text size, as in the
/// Material navigation bar. Five labels side by side do not fit at larger
/// sizes; up to this one no label is cut off.
const double _kMaxLabelScale = 1.3;

/// One destination of a [JyDock].
class JyDockItem {
  /// Creates a destination.
  const JyDockItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.key,
  });

  /// The icon while the destination is not selected, usually outlined.
  final IconData icon;

  /// The icon while the destination is selected, usually filled.
  final IconData selectedIcon;

  /// The text under the icon. It is always shown, and screen readers read
  /// it.
  final String label;

  /// The key of the destination's tap area.
  final Key? key;
}

/// The floating navigation dock of narrow layouts (MASTER.md section 9).
///
/// A pill in the overlay colour that floats [JySpace.md] above the bottom
/// safe area. Every destination shows its icon and label and is a tap
/// target of at least 48dp; a signalSoft capsule slides to the selected one
/// with the settling spring, or jumps there when motion is reduced.
///
/// Put it in `Scaffold.bottomNavigationBar` without `extendBody`. It adds
/// its own margins and safe-area padding, so content never runs under it.
class JyDock extends StatelessWidget {
  /// Creates a dock.
  const JyDock({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
  });

  /// The destinations, from the start side.
  final List<JyDockItem> items;

  /// The index of the selected destination in [items].
  final int selectedIndex;

  /// Called with the index of a tapped destination, the selected one too.
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final EdgeInsets safe = MediaQuery.paddingOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        JySpace.lg + safe.left,
        0,
        JySpace.lg + safe.right,
        JySpace.md + safe.bottom,
      ),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              shape: const StadiumBorder(),
              shadows: JyShadows.floating(context),
            ),
            child: Material(
              color: palette.overlay,
              shape: StadiumBorder(side: BorderSide(color: palette.hairline)),
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(JySpace.xs),
                child: _DockRow(
                  items: items,
                  selectedIndex: selectedIndex,
                  onSelected: onSelected,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockRow extends StatefulWidget {
  const _DockRow({
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<JyDockItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  State<_DockRow> createState() => _DockRowState();
}

class _DockRowState extends State<_DockRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _position;

  /// Where the capsule is going, as an index.
  late double _goal;
  bool _reduced = false;

  double get _target {
    if (widget.items.isEmpty) {
      return 0;
    }
    return widget.selectedIndex.clamp(0, widget.items.length - 1).toDouble();
  }

  @override
  void initState() {
    super.initState();
    _goal = _target;
    _position = AnimationController.unbounded(vsync: this, value: _goal);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = JyMotion.reducedOf(context);
    if (_reduced && _position.isAnimating) {
      _position.value = _goal;
    }
  }

  @override
  void didUpdateWidget(_DockRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final double target = _target;
    if (target == _goal) {
      return;
    }
    _goal = target;
    if (_reduced) {
      _position.value = target;
      return;
    }
    _position
        .animateWith(
          SpringSimulation(
            JyCurves.spring,
            _position.value,
            target,
            _position.velocity,
          ),
        )
        .then((void _) {
          // The spring stops within its tolerance; land exactly.
          if (mounted && _goal == target) {
            _position.value = target;
          }
        });
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final int count = widget.items.length;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _position,
            builder: (BuildContext context, Widget? capsule) => Align(
              alignment: AlignmentDirectional(
                count < 2 ? 0 : -1 + 2 * _position.value / (count - 1),
                0,
              ),
              child: capsule,
            ),
            child: FractionallySizedBox(
              widthFactor: count == 0 ? 0 : 1 / count,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: palette.signalSoft,
                  shape: const StadiumBorder(),
                ),
              ),
            ),
          ),
        ),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i < count; i++)
                Expanded(
                  child: _DockButton(
                    item: widget.items[i],
                    selected: i == widget.selectedIndex,
                    onTap: () => widget.onSelected(i),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DockButton extends StatelessWidget {
  const _DockButton({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final JyDockItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final Color color = selected ? palette.onSignalSoft : palette.text2;
    final TextStyle? style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: color,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
    );
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      child: InkWell(
        key: item.key,
        onTap: onTap,
        customBorder: const StadiumBorder(),
        overlayColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.pressed)) {
            return palette.signal.withValues(alpha: 0.08);
          }
          if (states.contains(WidgetState.focused)) {
            return palette.signal.withValues(alpha: 0.12);
          }
          if (states.contains(WidgetState.hovered)) {
            return palette.signal.withValues(alpha: 0.04);
          }
          return null;
        }),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: JySpace.x5 + JySpace.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: JySpace.xs,
              vertical: JySpace.sm - 2,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  selected ? item.selectedIcon : item.icon,
                  size: 24,
                  color: color,
                ),
                const SizedBox(height: 2),
                MediaQuery.withClampedTextScaling(
                  maxScaleFactor: _kMaxLabelScale,
                  child: Text(
                    item.label,
                    textAlign: TextAlign.center,
                    style: style,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
