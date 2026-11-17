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
        Text('模块清单', style: Theme.of(context).textTheme.titleMedium),
        const Text('当前外壳可路由到的模块及真实接入状态；占位/未接入不会伪装成功。'),
        const SizedBox(height: 8),
        for (final module in appModules)
          ListTile(
            key: Key('module-row-${module.id}'),
            contentPadding: EdgeInsets.zero,
            title: Text(module.title),
            subtitle: Text(module.description),
            trailing: Chip(
              label: Text(module.availabilityLabel),
              visualDensity: VisualDensity.compact,
            ),
          ),
        const Divider(height: 32),
        Text(
          '帧率 / 帧耗时 / 内存探针',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const Text(
          '在本机测量实际渲染帧耗时与进程内存（RSS）；这不等于 GPU 显存，显存需真机原生工具单独采集。',
        ),
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
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('FPS：${_fmt(summary.fps)}'),
                Text('平均帧耗时：${_fmt(summary.avgMillis)} ms'),
                Text('P95 帧耗时：${_fmt(summary.p95Millis)} ms'),
                Text(
                  '卡顿帧（>${_fmt(kDefaultJankThresholdMillis, 0)}ms）：${summary.jankFrames} / ${summary.totalFrames}',
                ),
                Text('进程内存 RSS：$rssText'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
