/// 时钟抽象。
///
/// 所有涉及"现在几点"的逻辑都必须接收 [Clock]，禁止在业务代码里直接
/// 调用 `DateTime.now()`：静默窗、定时消息、日记、周报、预算日切都需要
/// 可控时间来测试（FR-44、FR-52、CR-03、FR-48）。
library;

/// 供业务使用的时钟。
abstract class Clock {
  const Clock();

  /// 当前时刻。实现应返回带本地时区偏移的时间；
  /// 时区归属判定见 [dayKey]。
  DateTime now();
}

/// 系统时钟。
class SystemClock extends Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();
}

/// 测试用时钟：显式推进，不依赖真实时间。
class FakeClock extends Clock {
  FakeClock(DateTime start) : _now = start;

  DateTime _now;

  @override
  DateTime now() => _now;

  /// 前移 [delta]。
  void advance(Duration delta) {
    _now = _now.add(delta);
  }

  /// 直接设置到某个时刻。
  void set(DateTime moment) {
    _now = moment;
  }
}

/// 一天的日界（预算按日重置、日记按日生成）。
///
/// 约定：以客户端上报的本地时区为准；宿主时区只作兜底。
/// 因此调用方应传入"已按目标时区换算"的时刻。
String dayKey(DateTime moment) {
  final year = moment.year.toString().padLeft(4, '0');
  final month = moment.month.toString().padLeft(2, '0');
  final day = moment.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

/// 取当前时区下的日界键。
///
/// [utcOffset] 为空时使用宿主本地时区；客户端上报的时区值以此参数传入
/// （FR-44：静默窗按本地时区判定）。
String currentDayKey(Clock clock, {Duration? utcOffset}) {
  final now = clock.now();
  final shifted = utcOffset == null ? now : now.toUtc().add(utcOffset);
  return dayKey(shifted);
}
