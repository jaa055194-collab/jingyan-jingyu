/// 语音模块的 AI 归属校验（M08）。
///
/// 路由必须确认「当前登录账号拥有该 AI」后才允许读取音色/签发票据/控制通话；
/// 否则一律按 404 回答，避免泄露他人 AI 是否存在（防探测）。
///
/// 生产实现直接查询 canonical `ai_profile` / `account` / `ai_operator` 表，
/// 不 import 其它模块的实现文件；测试可注入假实现。
library;

import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';

/// 归属判定接口。
abstract interface class VoiceOwnership {
  /// 当前 [owner] 是否拥有 [ai]（AI 账号有效、operator 有效）。
  Future<bool> ownsAi({required AccountId owner, required AiId ai});
}

/// 基于 canonical 账号表的归属实现。
class DatabaseVoiceOwnership implements VoiceOwnership {
  DatabaseVoiceOwnership(this.database);

  final Database database;

  @override
  Future<bool> ownsAi({required AccountId owner, required AiId ai}) async {
    final rows = await database.query(
      '''
SELECT 1 FROM ai_profile p
JOIN account a ON a.id=p.account_id AND a.kind='ai' AND a.disabled=0
JOIN ai_operator o ON o.ai_id=a.id
JOIN account owner ON owner.id=o.operator_id AND owner.kind='human' AND owner.disabled=0
WHERE p.id=? AND o.operator_id=?
''',
      [ai.value, owner.value],
    );
    return rows.isNotEmpty;
  }
}
