import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/module_catalog.dart';
import '../../app/perf_probe.dart';

/// Developer-only shell test harness: lists shell modules and measures live
/// frame rate / frame time / jank / process memory on the current device.
///
/// This is a measurement tool, not a performance guarantee. On a real device it
/// surfaces actual FPS and RSS; GPU VRAM needs native/DevTools counters and is
/// explicitly out of scope here.
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
    _stop();
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

  void _stop() {
    final callback = _callback;
    if (callback != null) {
      SchedulerBinding.instance.removeTimingsCallback(callback);
      _callback = null;
    }
    _ticker?.cancel();
    _ticker = null;
    if (_measuring && mounted) {
      setState(() => _measuring = false);
    } else {
      _measuring = false;
    }
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
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '本面板证明：外壳可路由到哪些模块、各模块的真实接入状态，以及本机的实际'
          '渲染帧耗时/帧率与进程内存（RSS）。\n'
          '本面板不证明：模型可用、配置已授权、预算已获批，或任何端到端 AI 回复能力；'
          '也不代表 GPU 显存（需真机原生工具）。',
          key: Key('module-test-help'),
        ),
        const Divider(height: 32),
        Text('模块清单', style: Theme.of(context).textTheme.titleMedium),
        const Text('当前外壳可路由到的模块及真实接入状态；占位/未接入不会伪装成功。'),
        const SizedBox(height: 8),
        for (final module in appModules)
          ListTile(
            key: Key('module-row-${module.id}'),
            contentPadding: EdgeInsets.zero,
            title: Text(module.title),
            subtitle: Text(
              '${module.description}\n${_availabilityExplain(module.availability)}',
            ),
            isThreeLine: true,
            trailing: Chip(
              key: Key('module-availability-${module.id}'),
              label: Text(module.availabilityLabel),
              visualDensity: VisualDensity.compact,
            ),
          ),
        const Divider(height: 32),
        Text('帧率 / 帧耗时 / 内存探针', style: Theme.of(context).textTheme.titleMedium),
        const Text('在本机测量实际渲染帧耗时与进程内存（RSS）；这不等于 GPU 显存，显存需真机原生工具单独采集。'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.icon(
              key: const Key('module-test-start'),
              onPressed: _measuring ? null : _start,
              icon: const Icon(Icons.play_arrow),
              label: const Text('开始测量'),
            ),
            FilledButton.tonalIcon(
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
        const SizedBox(height: 8),
        Text(_measuring ? '状态：测量中…' : '状态：未开始（点击开始测量）'),
        Card(
          key: const Key('module-test-probe-result'),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _probeStatus(summary, _measuring),
                  key: const Key('module-test-probe-status'),
                ),
                const SizedBox(height: 8),
                Text('FPS：${_fmt(summary.fps)}'),
                Text('平均帧耗时：${_fmt(summary.avgMillis)} ms'),
                Text('P95 帧耗时：${_fmt(summary.p95Millis)} ms'),
                Text(
                  '卡顿帧（>${_fmt(kDefaultJankThresholdMillis, 0)}ms）：${summary.jankFrames} / ${summary.totalFrames}',
                ),
                Text('进程内存 RSS：$rssText'),
                const SizedBox(height: 4),
                const Text('以上为本机实测值，不代表宿主可用性或任何 AI 能力。'),
              ],
            ),
          ),
        ),
      ],
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
