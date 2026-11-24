import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/module_catalog.dart';
import '../../app/perf_probe.dart';
import '../../ui/jy_palette.dart';
import '../../ui/jy_tokens.dart';
import '../../ui/jy_typography.dart';

/// Developer-only shell test harness: lists shell modules and measures live
/// frame rate / frame time / jank / process memory on the current device.
///
/// This is a measurement tool, not a performance guarantee. On a real device it
/// surfaces actual FPS and RSS; GPU VRAM needs native/DevTools counters and is
/// explicitly out of scope here.
///
/// Settings and the world screen show it as a Scaffold body under their own
/// app bar, so the panel brings its own page padding.
class ModuleTestPanel extends StatefulWidget {
  const ModuleTestPanel({super.key});

  @override
  State<ModuleTestPanel> createState() => _ModuleTestPanelState();
}

class _ModuleTestPanelState extends State<ModuleTestPanel> {
  final List<FrameSample> _samples = <FrameSample>[];
  TimingsCallback? _callback;
  Timer? _ticker;
  bool _measuring = false;

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _start() {
    if (_measuring) return;
    _samples.clear();
    _callback = (List<FrameTiming> timings) {
      for (final timing in timings) {
        _samples.add(
          FrameSample(
            buildMillis: timing.buildDuration.inMicroseconds / 1000.0,
            rasterMillis: timing.rasterDuration.inMicroseconds / 1000.0,
          ),
        );
      }
    };
    SchedulerBinding.instance.addTimingsCallback(_callback!);
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
    setState(() => _measuring = true);
  }

  void _stop() => setState(_detach);

  /// Stops listening to frame timings and stops the refresh ticker. No
  /// setState here: dispose calls it after the element is unmounted, where
  /// setState trips a framework assertion.
  void _detach() {
    final callback = _callback;
    if (callback != null) {
      SchedulerBinding.instance.removeTimingsCallback(callback);
      _callback = null;
    }
    _ticker?.cancel();
    _ticker = null;
    _measuring = false;
  }

  void _reset() {
    setState(_samples.clear);
  }

  String _fmt(double value, [int digits = 1]) => value.toStringAsFixed(digits);

  @override
  Widget build(BuildContext context) {
    final summary = summarizeFrames(_samples, rssBytes: currentRssBytes());
    final rssText = summary.rssMegabytes == null
        ? '不可用'
        : '${_fmt(summary.rssMegabytes!)} MB';
    final JyPalette palette = JyPalette.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final TextStyle? metric = text.bodySmall?.copyWith(
      color: palette.text2,
      fontFeatures: JyTypography.tabularFigures,
    );
    // The hosts give the panel a whole Scaffold body. An explicit list padding
    // turns off the automatic safe-area insets, so add them back here; under
    // an app bar the top inset is already zero.
    final EdgeInsets safe = MediaQuery.paddingOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double side = _pageInset(constraints.maxWidth);
        return ListView(
          padding: EdgeInsets.fromLTRB(
            side + safe.left,
            JySpace.lg + safe.top,
            side + safe.right,
            JySpace.x3 + safe.bottom,
          ),
          children: <Widget>[
            _Slab(
              raised: true,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.info_outline, size: 20, color: palette.text2),
                  const SizedBox(width: JySpace.md),
                  Expanded(
                    child: Text(
                      '本面板证明：外壳可路由到哪些模块、各模块的真实接入状态，以及本机的实际'
                      '渲染帧耗时/帧率与进程内存（RSS）。\n'
                      '本面板不证明：模型可用、配置已授权、预算已获批，或任何端到端 AI 回复能力；'
                      '也不代表 GPU 显存（需真机原生工具）。',
                      key: const Key('module-test-help'),
                      style: text.bodySmall?.copyWith(color: palette.text2),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: JySpace.xxl),
            const _SectionHeader(
              title: '模块清单',
              detail: '当前外壳可路由到的模块及真实接入状态；占位/未接入不会伪装成功。',
            ),
            _Slab(
              padding: const EdgeInsets.symmetric(vertical: JySpace.xs),
              child: Column(
                children: <Widget>[
                  for (final (int index, AppModule module)
                      in appModules.indexed) ...<Widget>[
                    if (index > 0)
                      Divider(
                        height: 1,
                        thickness: 1,
                        indent: _ModuleRow.textStart,
                        color: palette.hairline,
                      ),
                    _ModuleRow(
                      module: module,
                      explanation: _availabilityExplain(module.availability),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: JySpace.xxl),
            const _SectionHeader(
              title: '帧率 / 帧耗时 / 内存探针',
              detail: '在本机测量实际渲染帧耗时与进程内存（RSS）；这不等于 GPU 显存，显存需真机原生工具单独采集。',
            ),
            _Slab(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'FPS：${_fmt(summary.fps)}',
                    style: text.headlineSmall?.copyWith(
                      fontFeatures: JyTypography.tabularFigures,
                    ),
                  ),
                  const SizedBox(height: JySpace.xs),
                  Text(
                    _measuring ? '状态：测量中…' : '状态：未开始（点击开始测量）',
                    style: text.bodyMedium?.copyWith(color: palette.text2),
                  ),
                  const SizedBox(height: JySpace.lg),
                  Wrap(
                    spacing: JySpace.md,
                    runSpacing: JySpace.sm,
                    children: <Widget>[
                      FilledButton.icon(
                        key: const Key('module-test-start'),
                        onPressed: _measuring ? null : _start,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('开始测量'),
                      ),
                      // Outlined rather than tonal: the theme gives tonal
                      // buttons the companion's ember colours.
                      OutlinedButton.icon(
                        key: const Key('module-test-stop'),
                        onPressed: _measuring ? _stop : null,
                        icon: const Icon(Icons.stop),
                        label: const Text('停止测量'),
                      ),
                      TextButton.icon(
                        key: const Key('module-test-reset'),
                        onPressed: _samples.isEmpty ? null : _reset,
                        icon: const Icon(Icons.refresh),
                        label: const Text('清零'),
                      ),
                    ],
                  ),
                  const SizedBox(height: JySpace.lg),
                  _Slab(
                    key: const Key('module-test-probe-result'),
                    raised: true,
                    radius: JyRadius.md,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          _probeStatus(summary, _measuring),
                          key: const Key('module-test-probe-status'),
                          style: text.bodyMedium,
                        ),
                        const SizedBox(height: JySpace.sm),
                        Wrap(
                          spacing: JySpace.xxl,
                          runSpacing: JySpace.xs,
                          children: <Widget>[
                            Text(
                              '平均帧耗时：${_fmt(summary.avgMillis)} ms',
                              style: metric,
                            ),
                            Text(
                              'P95 帧耗时：${_fmt(summary.p95Millis)} ms',
                              style: metric,
                            ),
                            Text(
                              '卡顿帧（>${_fmt(kDefaultJankThresholdMillis, 0)}ms）：${summary.jankFrames} / ${summary.totalFrames}',
                              style: metric,
                            ),
                            Text('进程内存 RSS：$rssText', style: metric),
                          ],
                        ),
                        const SizedBox(height: JySpace.sm),
                        Text(
                          '以上为本机实测值，不代表宿主可用性或任何 AI 能力。',
                          style: text.bodySmall?.copyWith(color: palette.text3),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// One-line explanation per module availability, honest and non-promotional.
  String _availabilityExplain(ModuleAvailability availability) =>
      switch (availability) {
        ModuleAvailability.available => '已实现：可路由并具备真实功能，但不代表模型可用或已授权',
        ModuleAvailability.placeholder => '占位：入口存在，宿主数据未接入，界面为诚实空态',
        ModuleAvailability.unavailable => '未接入：渲染/能力尚未接入外壳，无法使用',
      };

  /// Honest probe state: distinguishes 未配置 / 测量中 / 已测得数据 / 未知.
  String _probeStatus(PerfSummary summary, bool measuring) {
    if (measuring) return '探针状态：测量中（数据实时更新）';
    if (summary.totalFrames == 0) {
      return '探针状态：未配置（尚未开始测量，数值为 0，不代表性能差）';
    }
    return '探针状态：已测得 ${summary.totalFrames} 帧数据（停止后数值保留，可清零）';
  }
}

/// Widest the content column gets; wider windows centre it.
const double _maxContentWidth = 720;

/// Page side padding: 16 on narrow layouts, 24 from 720 up, and on wide
/// windows enough to keep the content column [_maxContentWidth] wide.
double _pageInset(double width) {
  if (width < _maxContentWidth) {
    return JySpace.pageNarrow;
  }
  return math.max(JySpace.pageWide, (width - _maxContentWidth) / 2);
}

/// One read-only module: icon, name, description with the honest
/// availability note, and the availability badge. Nothing here is tappable.
class _ModuleRow extends StatelessWidget {
  const _ModuleRow({required this.module, required this.explanation});

  final AppModule module;
  final String explanation;

  /// Where the text starts, so the hairline between rows lines up with it.
  static const double textStart = JySpace.lg + _IconTile.size + JySpace.md;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return MergeSemantics(
      key: Key('module-row-${module.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: JySpace.lg,
          vertical: JySpace.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _IconTile(icon: _moduleIcon(module.id)),
            const SizedBox(width: JySpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Text(module.title, style: text.titleMedium),
                      ),
                      const SizedBox(width: JySpace.md),
                      _AvailabilityBadge(
                        key: Key('module-availability-${module.id}'),
                        availability: module.availability,
                        label: module.availabilityLabel,
                      ),
                    ],
                  ),
                  const SizedBox(height: JySpace.xs),
                  Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        TextSpan(
                          text: '${module.description}\n',
                          style: TextStyle(color: palette.text2),
                        ),
                        TextSpan(
                          text: explanation,
                          style: TextStyle(color: palette.text3),
                        ),
                      ],
                    ),
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Outlined icons only: MASTER.md section 6 keeps one icon set.
IconData _moduleIcon(String id) => switch (id) {
  'chat' => Icons.chat_bubble_outline,
  'contacts' => Icons.people_outline,
  'moments' => Icons.feed_outlined,
  'inbox' => Icons.inbox_outlined,
  'world' => Icons.public_outlined,
  'own-ai-consent' => Icons.verified_user_outlined,
  'settings' => Icons.settings_outlined,
  _ => Icons.widgets_outlined,
};

/// The availability label on a pill. The icon only repeats what the label
/// says, so colour is never the only signal.
class _AvailabilityBadge extends StatelessWidget {
  const _AvailabilityBadge({
    super.key,
    required this.availability,
    required this.label,
  });

  final ModuleAvailability availability;
  final String label;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final (IconData icon, Color ink) = switch (availability) {
      ModuleAvailability.available => (
        Icons.check_circle_outline,
        palette.success,
      ),
      ModuleAvailability.placeholder => (
        Icons.radio_button_unchecked,
        palette.text3,
      ),
      ModuleAvailability.unavailable => (Icons.error_outline, palette.warning),
    };
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: palette.raised,
        shape: JyShapes.pill.copyWith(
          side: BorderSide(color: palette.hairline),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          JySpace.sm,
          JySpace.xs,
          JySpace.md,
          JySpace.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 16, color: ink),
            const SizedBox(width: JySpace.xs),
            Text(
              label,
              style: text.labelMedium?.copyWith(color: palette.text2),
            ),
          ],
        ),
      ),
    );
  }
}

/// Section title with an optional one-line note, above a slab.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.detail});

  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(JySpace.xs, 0, JySpace.xs, JySpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(header: true, child: Text(title, style: text.titleSmall)),
          if (detail case final String line) ...<Widget>[
            const SizedBox(height: JySpace.xs),
            Text(line, style: text.bodySmall?.copyWith(color: palette.text3)),
          ],
        ],
      ),
    );
  }
}

/// Module icon on a tinted superellipse at the start of a row.
class _IconTile extends StatelessWidget {
  const _IconTile({required this.icon});

  static const double size = 40;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: palette.signalSoft,
        shape: JyShapes.rounded(JyRadius.sm),
      ),
      child: SizedBox.square(
        dimension: size,
        child: Icon(icon, size: 22, color: palette.onSignalSoft),
      ),
    );
  }
}

/// A slab, or with [raised] a block inside one, on the shared superellipse
/// with a hairline edge. Stands in for JySlab until lib/ui lands.
class _Slab extends StatelessWidget {
  const _Slab({
    super.key,
    required this.child,
    this.raised = false,
    this.padding = const EdgeInsets.all(JySpace.slab),
    this.radius = JyRadius.lg,
  });

  final Widget child;
  final bool raised;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final JyPalette palette = JyPalette.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: raised ? palette.raised : palette.slab,
        shape: JyShapes.rounded(
          radius,
          side: BorderSide(color: palette.hairline),
        ),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}
