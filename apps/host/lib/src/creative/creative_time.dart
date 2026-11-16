/// 创意功能共用的时间与调度原语（CR-03 周报/年报、CR-07 深夜电台）。
///
/// 设计要点（对应需求口径）：
/// * 一切"按几点触发"的判定都用**用户本地时区**，时区由客户端上报（FR-44）；
///   宿主不读取自身时区，业务代码也不直接调用 `DateTime.now()`，一律注入 [Clock]。
/// * 静默窗顺延按 B-4：落在静默窗内的定时项顺延到静默窗结束，而非丢弃。
/// * 错过的定时项按 B-4「周报、电台：不补」：宿主恢复时若已明显错过触发点，
///   只记一次"错过"，不再补生成。
///
/// 墙钟表示约定：本文件里所有"本地墙钟"都用 `DateTime.utc(...)` 构造，
/// 只取年月日时分秒分量，不代表 UTC 语义；与绝对时刻的换算只走 [UserTimeZone]。
library;

import 'package:jingyu_core/jingyu_core.dart';

/// 用户本地时区（相对 UTC 的固定偏移）。
///
/// 客户端上报时把夏时令折算进 [offset]（FR-44/CR-03「用户本地时区」）。
class UserTimeZone {
  const UserTimeZone(this.offset);

  /// 相对 UTC 的偏移，例如东八区为 `Duration(hours: 8)`。
  final Duration offset;

  /// 绝对时刻 → 本地墙钟（UTC 标记，仅分量有意义）。
  DateTime toLocalWall(DateTime instant) => instant.toUtc().add(offset);

  /// 本地墙钟 → 绝对时刻（UTC）。
  DateTime toInstant(DateTime wall) => DateTime.utc(
    wall.year,
    wall.month,
    wall.day,
    wall.hour,
    wall.minute,
    wall.second,
    wall.millisecond,
    wall.microsecond,
  ).subtract(offset);

  /// 当前本地墙钟。
  DateTime nowLocal(Clock clock) => toLocalWall(clock.now());

  /// 当前本地日界键（yyyy-mm-dd）。
  String todayLocalDayKey(Clock clock) => dayKey(nowLocal(clock));
}

/// 一天中的本地时刻（小时 + 分钟）。
class LocalTime {
  const LocalTime(this.hour, this.minute);

  final int hour;
  final int minute;

  int get minuteOfDay => hour * 60 + minute;

  @override
  String toString() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

/// 静默窗（默认 23:00–08:00，v4.2 可调默认值）。
///
/// 起止相同视为"无静默窗"。支持跨夜（start > end）。判定与顺延都只看墙钟分量，
/// 由调用方保证传入的是目标用户本地时间。
class SilentWindow {
  const SilentWindow({
    this.start = const LocalTime(23, 0),
    this.end = const LocalTime(8, 0),
    this.enabled = true,
  });

  /// 关闭静默窗（例如用户显式关闭）。
  const SilentWindow.disabled()
    : start = const LocalTime(23, 0),
      end = const LocalTime(8, 0),
      enabled = false;

  final LocalTime start;
  final LocalTime end;
  final bool enabled;

  /// [wall]（本地墙钟）是否落在静默窗内。
  bool containsWall(DateTime wall) {
    if (!enabled) return false;
    final s = start.minuteOfDay;
    final e = end.minuteOfDay;
    if (s == e) return false;
    final m = wall.hour * 60 + wall.minute;
    if (s < e) return m >= s && m < e;
    // 跨夜：傍晚段 [s, 24:00) 或清晨段 [00:00, e)
    return m >= s || m < e;
  }

  /// 若 [wall] 落在静默窗内，返回顺延到窗结束的墙钟；否则原样返回。
  ///
  /// B-4：「落在静默窗内的顺延到静默窗结束」。
  DateTime deferToEnd(DateTime wall) {
    if (!containsWall(wall)) return wall;
    final s = start.minuteOfDay;
    final m = wall.hour * 60 + wall.minute;
    var dayOffset = 0;
    if (s >= end.minuteOfDay) {
      // 跨夜：傍晚段顺延到次日结束；清晨段当天结束。
      dayOffset = m >= s ? 1 : 0;
    }
    final base = DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
    ).add(Duration(days: dayOffset));
    return DateTime.utc(base.year, base.month, base.day, end.hour, end.minute);
  }
}

/// 每周固定本地时刻（例如周日 21:30，CR-03）。
class WeeklySchedule {
  const WeeklySchedule({required this.weekday, required this.time});

  /// `DateTime.monday`(1) … `DateTime.sunday`(7)。
  final int weekday;
  final LocalTime time;

  DateTime _at(DateTime day) => DateTime.utc(
    day.year,
    day.month,
    day.day,
    time.hour,
    time.minute,
  );

  /// 不晚于 [wall] 的最近一次触发墙钟。
  DateTime lastOccurrenceOnOrBefore(DateTime wall) {
    final wallAtMinute = DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
    );
    var delta = (wall.weekday - weekday) % 7;
    if (delta < 0) delta += 7;
    final day = DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
    ).subtract(Duration(days: delta));
    var candidate = _at(day);
    if (candidate.isAfter(wallAtMinute)) {
      candidate = candidate.subtract(const Duration(days: 7));
    }
    return candidate;
  }

  /// 不早于 [wall] 的下一次触发墙钟。
  DateTime nextOccurrenceOnOrAfter(DateTime wall) {
    final wallAtMinute = DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
    );
    var delta = (weekday - wall.weekday) % 7;
    if (delta < 0) delta += 7;
    final day = DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
    ).add(Duration(days: delta));
    var candidate = _at(day);
    if (candidate.isBefore(wallAtMinute)) {
      candidate = candidate.add(const Duration(days: 7));
    }
    return candidate;
  }
}

/// 每天固定本地时刻（例如 23:00，CR-07）。
class DailySchedule {
  const DailySchedule({required this.time});

  final LocalTime time;

  /// [instant] 当天（本地）的触发墙钟。
  DateTime occurrenceOnDay(DateTime localDay) => DateTime.utc(
    localDay.year,
    localDay.month,
    localDay.day,
    time.hour,
    time.minute,
  );

  /// 不晚于 [wall] 的最近一次触发墙钟。
  DateTime lastOccurrenceOnOrBefore(DateTime wall) {
    final wallAtMinute = DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
    );
    final today = occurrenceOnDay(wall);
    return today.isAfter(wallAtMinute)
        ? today.subtract(const Duration(days: 1))
        : today;
  }
}

/// 定时槽的判定结果。
enum SlotOutcome {
  /// 尚未到点（含被静默窗顺延到未来）。
  notDue,

  /// 已到点且仍在"准时容忍窗"内——应立即生成。
  due,

  /// 已明显错过触发点——按 B-4 不补。
  missed,
}

/// 把"周期触发点 + 静默窗 + 准容忍窗"折算成本次是否生成。
///
/// [nowWall] 为当前本地墙钟；[occurrenceWall] 为待判定的周期触发墙钟（本地）。
/// [exemptSilentWindow] 为 true 时不做静默窗顺延（CR-07「本地播放不受静默窗限制」）。
SlotOutcome evaluateSlot({
  required DateTime occurrenceWall,
  required DateTime nowWall,
  required SilentWindow silentWindow,
  required Duration onTimeGrace,
  required UserTimeZone timeZone,
  bool exemptSilentWindow = false,
}) {
  final effectiveWall = exemptSilentWindow
      ? occurrenceWall
      : silentWindow.deferToEnd(occurrenceWall);
  final dueInstant = timeZone.toInstant(effectiveWall);
  final nowInstant = timeZone.toInstant(nowWall);
  if (nowInstant.isBefore(dueInstant)) return SlotOutcome.notDue;
  if (nowInstant.difference(dueInstant) > onTimeGrace) {
    return SlotOutcome.missed;
  }
  return SlotOutcome.due;
}

/// 取 [wall] 所在自然周（周一为起点）的起始日界键。
String weekStartDayKey(DateTime wall) {
  final start = DateTime.utc(
    wall.year,
    wall.month,
    wall.day,
  ).subtract(Duration(days: wall.weekday - DateTime.monday));
  return dayKey(start);
}
