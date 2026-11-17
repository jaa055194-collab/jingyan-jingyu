import 'dart:io' show ProcessInfo;

/// One rendered frame's build and raster time in milliseconds.
class FrameSample {
  const FrameSample({required this.buildMillis, required this.rasterMillis});

  final double buildMillis;
  final double rasterMillis;

  double get totalMillis => buildMillis + rasterMillis;
}

/// Aggregated performance over a measurement window.
///
/// Values are best-effort *measurements*, never guaranteed budgets.
/// [rssMegabytes] is process resident memory (a coarse proxy for overall
/// footprint); on most platforms it is NOT GPU VRAM, which needs native/DevTools
/// counters on a real device.
class PerfSummary {
  const PerfSummary({
    required this.fps,
    required this.avgMillis,
    required this.p95Millis,
    required this.jankFrames,
    required this.totalFrames,
    required this.rssMegabytes,
  });

  final double fps;
  final double avgMillis;
  final double p95Millis;
  final int jankFrames;
  final int totalFrames;
  final double? rssMegabytes;

  static const PerfSummary empty = PerfSummary(
    fps: 0,
    avgMillis: 0,
    p95Millis: 0,
    jankFrames: 0,
    totalFrames: 0,
    rssMegabytes: null,
  );
}

/// A frame slower than this counts as janky. 33ms is roughly slower than 30fps,
/// the NFR-04 target for mid-range Android indoors.
const double kDefaultJankThresholdMillis = 33.0;

/// Aggregate raw frame samples into observable metrics.
///
/// FPS is total frames divided by summed frame time (i.e. the rate implied by
/// actual rendered frame durations), not wall-clock. p95 uses nearest-rank over
/// the sorted total frame times.
PerfSummary summarizeFrames(
  List<FrameSample> samples, {
  double jankThresholdMillis = kDefaultJankThresholdMillis,
  int? rssBytes,
}) {
  final total = samples.length;
  final rssMegabytes = rssBytes == null ? null : rssBytes / (1024 * 1024);
  if (total == 0) {
    return PerfSummary(
      fps: 0,
      avgMillis: 0,
      p95Millis: 0,
      jankFrames: 0,
      totalFrames: 0,
      rssMegabytes: rssMegabytes,
    );
  }
  var sum = 0.0;
  var jank = 0;
  final totals = <double>[];
  for (final sample in samples) {
    final t = sample.totalMillis;
    if (t < 0) continue;
    sum += t;
    totals.add(t);
    if (t > jankThresholdMillis) jank++;
  }
  final measured = totals.length;
  if (measured == 0) {
    return PerfSummary(
      fps: 0,
      avgMillis: 0,
      p95Millis: 0,
      jankFrames: 0,
      totalFrames: 0,
      rssMegabytes: rssMegabytes,
    );
  }
  final avg = sum / measured;
  final seconds = sum / 1000.0;
  final fps = seconds > 0 ? measured / seconds : 0.0;
  totals.sort();
  final index = ((0.95 * measured).ceil() - 1).clamp(0, measured - 1);
  return PerfSummary(
    fps: fps,
    avgMillis: avg,
    p95Millis: totals[index],
    jankFrames: jank,
    totalFrames: measured,
    rssMegabytes: rssMegabytes,
  );
}

/// Process resident memory in bytes, best-effort. Returns null when the platform
/// cannot report it (some returns are -1/0 for "unknown").
int? currentRssBytes() {
  try {
    final rss = ProcessInfo.currentRss;
    return rss > 0 ? rss : null;
  } catch (_) {
    return null;
  }
}
