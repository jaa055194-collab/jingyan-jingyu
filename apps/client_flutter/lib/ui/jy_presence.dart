import 'package:material_ui/material_ui.dart';

import 'jy_motion.dart';
import 'jy_palette.dart';
import 'jy_tokens.dart';

/// What the AI companion is doing, shown by [JyPresenceOrb].
enum JyPresence {
  /// Present and quiet: a calm core inside one faint ring.
  idle,

  /// Not reachable: grey, without glow.
  offline,

  /// Waiting for a reply: the glow breathes until the state changes. Use it
  /// only where an indeterminate progress indicator was shown before, under
  /// the same condition, because it loops.
  thinking,

  /// A reply arrived: one sonar wave when the orb enters this state.
  speaking,

  /// Something new arrived: the core lights up once when the orb enters
  /// this state.
  attention,
}

/// The AI companion's light core (MASTER.md section 7).
///
/// Every motion starts from an event: entering [JyPresence.speaking] sends
/// one sonar wave, entering [JyPresence.attention] lights the core up once,
/// and [JyPresence.thinking] breathes until the state changes. When motion
/// is reduced the orb is static and its colours alone tell the states apart.
class JyPresenceOrb extends StatefulWidget {
  /// Creates an orb.
  const JyPresenceOrb({
    super.key,
    this.size = 40,
    this.state = JyPresence.idle,
    this.semanticsLabel,
    this.child,
  });

  /// The width and height.
  final double size;

  /// What the companion is doing.
  final JyPresence state;

  /// Read by screen readers. Null hides the orb from them, which suits an
  /// orb next to a name that is read anyway.
  final String? semanticsLabel;

  /// Drawn in the middle of the core, such as a small icon.
  final Widget? child;

  @override
  State<JyPresenceOrb> createState() => _JyPresenceOrbState();
}

class _JyPresenceOrbState extends State<JyPresenceOrb>
    with TickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: JyDurations.gentle * 2,
  );
  late final AnimationController _event = AnimationController(
    vsync: this,
    duration: JyDurations.gentle,
  );
  bool _reduced = false;
  bool _breathing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = JyMotion.reducedOf(context);
    if (_reduced) {
      _event.value = 0;
    }
    _syncBreath();
  }

  @override
  void didUpdateWidget(JyPresenceOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state == oldWidget.state) {
      return;
    }
    _syncBreath();
    final bool event =
        widget.state == JyPresence.speaking ||
        widget.state == JyPresence.attention;
    if (event && !_reduced) {
      _event.forward(from: 0);
    } else {
      _event.value = 0;
    }
  }

  void _syncBreath() {
    final bool breathe = widget.state == JyPresence.thinking && !_reduced;
    if (breathe == _breathing) {
      return;
    }
    _breathing = breathe;
    if (breathe) {
      _breath.repeat(reverse: true);
    } else if (_reduced) {
      _breath.value = 0;
    } else {
      _breath.animateBack(0, duration: JyDurations.quick);
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    _event.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final bool offline = widget.state == JyPresence.offline;
    final Widget orb = SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _OrbPainter(
          core: offline ? palette.text3 : palette.ember,
          ring: offline ? palette.outline : palette.ember,
          glow: !offline,
          wave: widget.state == JyPresence.speaking,
          flash: widget.state == JyPresence.attention,
          breath: _breath,
          event: _event,
        ),
        child: widget.child == null ? null : Center(child: widget.child),
      ),
    );
    final String? label = widget.semanticsLabel;
    if (label == null) {
      return ExcludeSemantics(child: orb);
    }
    return Semantics(
      container: true,
      label: label,
      child: ExcludeSemantics(child: orb),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.core,
    required this.ring,
    required this.glow,
    required this.wave,
    required this.flash,
    required this.breath,
    required this.event,
  }) : super(repaint: Listenable.merge(<Listenable>[breath, event]));

  final Color core;
  final Color ring;
  final bool glow;
  final bool wave;
  final bool flash;
  final Animation<double> breath;
  final Animation<double> event;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double radius = size.shortestSide / 2;
    final double b = breath.value;
    final double t = event.value;
    final double stroke = radius < 24 ? 1 : 1.5;
    canvas.drawCircle(
      center,
      radius - stroke,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = ring.withValues(alpha: 0.3),
    );
    if (glow) {
      // Rises and falls once over the event when the core lights up.
      final double lit = flash ? 1 - (2 * t - 1) * (2 * t - 1) : 0;
      final double strength = (0.28 + 0.22 * b + 0.4 * lit).clamp(0.0, 1.0);
      final Rect glowRect = Rect.fromCircle(
        center: center,
        radius: radius * 0.9,
      );
      canvas.drawCircle(
        center,
        radius * 0.9,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              core.withValues(alpha: strength),
              core.withValues(alpha: 0),
            ],
          ).createShader(glowRect),
      );
    }
    final double coreRadius = radius * (0.5 + 0.04 * b);
    canvas.drawCircle(
      center,
      coreRadius,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.35),
          colors: <Color>[Color.lerp(core, Colors.white, 0.45)!, core],
        ).createShader(Rect.fromCircle(center: center, radius: coreRadius)),
    );
    if (wave && t > 0 && t < 1) {
      final double e = JyCurves.enter.transform(t);
      canvas.drawCircle(
        center,
        coreRadius + (radius - coreRadius) * e,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = core.withValues(alpha: 0.6 * (1 - e)),
      );
    }
  }

  @override
  bool shouldRepaint(_OrbPainter oldDelegate) =>
      oldDelegate.core != core ||
      oldDelegate.ring != ring ||
      oldDelegate.glow != glow ||
      oldDelegate.wave != wave ||
      oldDelegate.flash != flash ||
      oldDelegate.breath != breath ||
      oldDelegate.event != event;
}

/// Sends one sonar wave out from [child] each time [trigger] changes, such
/// as when a message is sent. Nothing moves when motion is reduced.
class JySonarPulse extends StatefulWidget {
  /// Creates a pulse around [child].
  const JySonarPulse({
    super.key,
    required this.trigger,
    required this.child,
    this.color,
  });

  /// A new value, compared with `==`, sends a wave. The first value does not.
  final Object trigger;

  /// The widget the wave leaves from.
  final Widget child;

  /// The wave colour. Null uses signal.
  final Color? color;

  @override
  State<JySonarPulse> createState() => _JySonarPulseState();
}

class _JySonarPulseState extends State<JySonarPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: JyDurations.gentle,
  );
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = JyMotion.reducedOf(context);
    if (_reduced) {
      _wave.value = 0;
    }
  }

  @override
  void didUpdateWidget(JySonarPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.trigger != oldWidget.trigger && !_reduced) {
      _wave.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _WavePainter(
        _wave,
        widget.color ?? JyPalette.of(context).signal,
      ),
      child: widget.child,
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.progress, this.color) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = progress.value;
    if (t <= 0 || t >= 1) {
      return;
    }
    final double e = JyCurves.enter.transform(t);
    canvas.drawCircle(
      size.center(Offset.zero),
      size.shortestSide / 2 * (1 + 0.6 * e),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color.withValues(alpha: 0.5 * (1 - e)),
    );
  }

  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(_WavePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

/// Concentric sonar rings around [child], for status panels, onboarding and
/// the world page. They spread out once when they appear and then stay
/// still; they never loop.
class JySonarRings extends StatefulWidget {
  /// Creates the rings.
  const JySonarRings({
    super.key,
    this.size = 96,
    this.rings = 3,
    this.color,
    this.pulseOnAppear = true,
    this.child,
  }) : assert(rings > 0);

  /// The width and height.
  final double size;

  /// How many rings to draw.
  final int rings;

  /// The ring colour. Null uses signal.
  final Color? color;

  /// Whether the rings spread out once when they first appear. They are
  /// static when this is false or motion is reduced.
  final bool pulseOnAppear;

  /// Drawn in the middle, such as an icon.
  final Widget? child;

  @override
  State<JySonarRings> createState() => _JySonarRingsState();
}

class _JySonarRingsState extends State<JySonarRings>
    with SingleTickerProviderStateMixin {
  late final AnimationController _appear = AnimationController(
    vsync: this,
    duration: JyDurations.gentle,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduced = JyMotion.reducedOf(context);
    if (!_started) {
      _started = true;
      if (widget.pulseOnAppear && !reduced) {
        _appear.forward();
      } else {
        _appear.value = 1;
      }
    } else if (reduced) {
      _appear.value = 1;
    }
  }

  @override
  void dispose() {
    _appear.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(
        painter: _RingsPainter(
          progress: _appear,
          color: widget.color ?? JyPalette.of(context).signal,
          rings: widget.rings,
        ),
        child: widget.child == null ? null : Center(child: widget.child),
      ),
    );
  }
}

class _RingsPainter extends CustomPainter {
  _RingsPainter({
    required this.progress,
    required this.color,
    required this.rings,
  }) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;
  final int rings;

  /// The progress of a ring that starts after [share] of the run.
  static double _local(double t, double share) =>
      ((t - 0.45 * share) / 0.55).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    final double radius = size.shortestSide / 2;
    final double t = progress.value;
    final double inner = JyCurves.enter.transform(_local(t, 0));
    canvas.drawCircle(
      center,
      radius * 0.5,
      Paint()..color = color.withValues(alpha: 0.12 * inner),
    );
    for (int i = 0; i < rings; i++) {
      final double share = rings == 1 ? 0 : i / (rings - 1);
      final double p = JyCurves.enter.transform(_local(t, share));
      final double fraction = rings == 1 ? 1 : 0.6 + 0.4 * share;
      canvas.drawCircle(
        center,
        (radius - 1) * fraction * (0.9 + 0.1 * p),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = color.withValues(alpha: (0.5 - 0.3 * share) * p),
      );
    }
    if (t > 0 && t < 1) {
      final double e = JyCurves.enter.transform(t);
      canvas.drawCircle(
        center,
        radius * (0.6 + 0.5 * e),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: 0.5 * (1 - e)),
      );
    }
  }

  @override
  bool shouldRepaint(_RingsPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.rings != rings;
}

/// A busy or progress indicator whose [label] is read by screen readers.
///
/// It uses the Material indicators in signal colours. When motion is
/// reduced an indeterminate one becomes a still line or an hourglass that
/// is still read as [label].
class JyBusyIndicator extends StatelessWidget {
  /// Creates an indicator.
  const JyBusyIndicator({
    super.key,
    required this.label,
    this.linear = false,
    this.value,
  });

  /// Read by screen readers, such as 「正在处理」.
  final String label;

  /// A thin line instead of a circle.
  final bool linear;

  /// Progress from 0 to 1. Null means the length of the work is unknown.
  final double? value;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    if (value == null && JyMotion.reducedOf(context)) {
      final Widget still = linear
          ? ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: double.infinity,
                minHeight: 3,
              ),
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: palette.signal.withValues(alpha: 0.5),
                  shape: JyShapes.pill,
                ),
              ),
            )
          : Icon(Icons.hourglass_empty_rounded, color: palette.signal);
      return Semantics(
        label: label,
        child: ExcludeSemantics(child: still),
      );
    }
    if (linear) {
      return LinearProgressIndicator(
        value: value,
        minHeight: 3,
        color: palette.signal,
        backgroundColor: palette.signalSoft,
        borderRadius: const BorderRadius.all(Radius.circular(JyRadius.pill)),
        semanticsLabel: label,
      );
    }
    return CircularProgressIndicator(
      value: value,
      strokeWidth: 3,
      strokeCap: StrokeCap.round,
      color: palette.signal,
      backgroundColor: value == null ? null : palette.signalSoft,
      semanticsLabel: label,
    );
  }
}

/// A small connection dot. Keep the 「在线」 or 「离线」 text next to it: the
/// dot is hidden from screen readers and colour alone is not enough.
class JyStatusDot extends StatelessWidget {
  /// Creates a dot.
  const JyStatusDot({super.key, required this.online});

  /// Whether the connection is up.
  final bool online;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: JySpace.sm,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: online ? palette.success : palette.text3,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// What a [JyAvatar] stands for.
enum JyAvatarKind {
  /// One person: their initial on a disc.
  person,

  /// A group chat: two stacked discs.
  group,

  /// The AI companion: its light core.
  ai,
}

/// An avatar. It is hidden from screen readers, because the name it stands
/// for is shown and read next to it.
class JyAvatar extends StatelessWidget {
  /// Creates an avatar for [label].
  const JyAvatar({
    super.key,
    required this.label,
    this.size = 44,
    this.kind = JyAvatarKind.person,
  });

  /// The name; its first character is drawn.
  final String label;

  /// The width and height.
  final double size;

  /// What the avatar stands for.
  final JyAvatarKind kind;

  @override
  Widget build(BuildContext context) {
    switch (kind) {
      case JyAvatarKind.ai:
        return JyPresenceOrb(size: size);
      case JyAvatarKind.person:
        return ExcludeSemantics(
          child: _AvatarDisc(label: label, size: size),
        );
      case JyAvatarKind.group:
        final double small = size * 0.68;
        return ExcludeSemantics(
          child: SizedBox.square(
            dimension: size,
            child: Stack(
              children: <Widget>[
                PositionedDirectional(
                  top: 0,
                  start: 0,
                  child: _AvatarDisc(label: '', size: small, muted: true),
                ),
                PositionedDirectional(
                  bottom: 0,
                  end: 0,
                  child: _AvatarDisc(
                    label: label,
                    size: small,
                    ring: JyPalette.of(context).slab,
                  ),
                ),
              ],
            ),
          ),
        );
    }
  }
}

class _AvatarDisc extends StatelessWidget {
  const _AvatarDisc({
    required this.label,
    required this.size,
    this.muted = false,
    this.ring,
  });

  final String label;
  final double size;
  final bool muted;
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final Color ink = muted ? palette.text2 : palette.onSignalSoft;
    final String name = label.trim();
    final Widget face = name.isEmpty
        ? Icon(Icons.person_outline_rounded, size: size * 0.5, color: ink)
        : Text(
            name.characters.first.toUpperCase(),
            textScaler: TextScaler.noScaling,
            style: TextStyle(
              color: ink,
              fontSize: size * 0.4,
              fontWeight: FontWeight.w600,
              height: 1,
            ),
          );
    final Color? ring = this.ring;
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: muted ? palette.raised : palette.signalSoft,
          shape: CircleBorder(
            side: ring == null
                ? BorderSide.none
                : BorderSide(color: ring, width: 2),
          ),
        ),
        child: Center(child: face),
      ),
    );
  }
}
