/// 审计日志接口与内存实现。
///
/// 审计记录"谁在何时对什么做了什么"，**不记录正文、音频与 key**（NFR-07、NFR-10）。
/// 例外：需求方确认"历史正文在审计管理端可见"（2026-11-13 答复第 8 条），
/// 那是被编辑/重新生成前的旧版本正文，存放在 `message_edits` 等版本表里，
/// 由管理端按需读取；审计条目本身仍只存引用。
library;

import 'package:jingyu_core/jingyu_core.dart';

/// 一条审计记录。
class AuditEntry {
  AuditEntry({
    required this.at,
    required this.actorId,
    required this.action,
    required this.targetKind,
    required this.targetId,
    Map<String, Object?> meta = const {},
  }) : meta = _sanitize(meta);

  final DateTime at;
  final String actorId;

  /// 动作名，形如 `message.recall`、`memory.archive`。
  final String action;
  final String targetKind;
  final String targetId;

  /// 机器可读元数据，只允许标量。
  final Map<String, Object?> meta;

  /// 禁止进入审计的字段名。
  static const Set<String> forbiddenKeys = {
    'text', 'body', 'content', 'audio', 'key', 'apiKey', 'api_key', 'password', 'token',
  };

  static Map<String, Object?> _sanitize(Map<String, Object?> meta) {
    for (final key in meta.keys) {
      if (forbiddenKeys.contains(key)) {
        throw ArgumentError.value(key, 'meta', '审计不得包含正文、音频或密钥字段');
      }
      final value = meta[key];
      if (value != null && value is! num && value is! bool && value is! String) {
        throw ArgumentError.value(key, 'meta', '审计元数据只允许标量');
      }
    }
    return Map.unmodifiable(meta);
  }
}

/// 审计写入接口。
abstract class AuditLog {
  Future<void> record(AuditEntry entry);

  /// 按目标查询（管理端用）。
  Future<List<AuditEntry>> forTarget(String targetKind, String targetId);
}

/// 内存实现：框架与测试使用；持久化实现见 docs/modules/M01-storage.md。
class InMemoryAuditLog implements AuditLog {
  InMemoryAuditLog({this.clock = const SystemClock()});

  final Clock clock;
  final List<AuditEntry> _entries = [];

  List<AuditEntry> get entries => List.unmodifiable(_entries);

  @override
  Future<void> record(AuditEntry entry) async => _entries.add(entry);

  @override
  Future<List<AuditEntry>> forTarget(String targetKind, String targetId) async => [
        for (final e in _entries)
          if (e.targetKind == targetKind && e.targetId == targetId) e,
      ];
}
