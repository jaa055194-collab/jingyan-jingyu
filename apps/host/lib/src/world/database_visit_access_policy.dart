/// FR-37 拜访权限的真实实现：只读查询现有 social 关系表（好友/拉黑/账号可用）。
///
/// 该策略直接读 `friendships` / `account_blocks` / `account` 表，不 import social 模块
/// 实现文件（遵守模块间只经接口交互的分层规则）。若 social 日后提供正式策略端口，
/// 可用注入的 `VisitAccessPolicy` 替换本类。
///
/// 契约缺口（未在本切片伪造）：
/// * `isHostPresent`：宿主没有"在线 presence"信号，这里以账号存在且未禁用作为近似；
/// * `aiReceivesWhileAbsent`：没有按主人持久化的"AI 接待开关"，默认返回 true
///   （需求默认开，可关）。真正可关需要 M04/设置侧新增持久化字段。
library;

import '../storage/database.dart';
import 'presence.dart';

class DatabaseVisitAccessPolicy implements VisitAccessPolicy {
  DatabaseVisitAccessPolicy({required this.database});

  final Database database;

  static List<String> _pair(String a, String b) =>
      a.compareTo(b) < 0 ? [a, b] : [b, a];

  Future<bool> _active(String accountId) async {
    final rows = await database.query(
      'SELECT 1 FROM account WHERE id = ? AND disabled = 0',
      [accountId],
    );
    return rows.isNotEmpty;
  }

  @override
  Future<bool> areFriends(String visitorId, String hostOwnerId) async {
    if (visitorId == hostOwnerId) return false;
    if (!await _active(visitorId) || !await _active(hostOwnerId)) return false;
    if (await isBlocked(visitorId, hostOwnerId)) return false;
    final rows = await database.query(
      'SELECT 1 FROM friendships WHERE account_low = ? AND account_high = ?',
      _pair(visitorId, hostOwnerId),
    );
    return rows.isNotEmpty;
  }

  @override
  Future<bool> isBlocked(String visitorId, String hostOwnerId) async {
    // 阻断沿 AI→operator 继承：拉黑某人等于拉黑其名下 AI，反之亦然（C-5）。
    final rows = await database.query(
      '''
WITH left_ids(id) AS (
  SELECT ? UNION SELECT operator_id FROM ai_operator WHERE ai_id = ?
),
right_ids(id) AS (
  SELECT ? UNION SELECT operator_id FROM ai_operator WHERE ai_id = ?
)
SELECT 1 FROM account_blocks
WHERE (blocker IN (SELECT id FROM left_ids) AND target IN (SELECT id FROM right_ids))
   OR (blocker IN (SELECT id FROM right_ids) AND target IN (SELECT id FROM left_ids))
LIMIT 1
''',
      [visitorId, visitorId, hostOwnerId, hostOwnerId],
    );
    return rows.isNotEmpty;
  }

  @override
  Future<bool> isHostPresent(String hostOwnerId) async {
    // GAP: no online-presence signal; approximate with enabled account.
    return _active(hostOwnerId);
  }

  @override
  Future<bool> aiReceivesWhileAbsent(String hostOwnerId) async {
    // GAP: no persisted per-owner toggle; requirement default is "on".
    return true;
  }
}
