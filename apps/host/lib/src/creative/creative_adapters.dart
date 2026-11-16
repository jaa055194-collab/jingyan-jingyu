/// CR-03/CR-07 的可注入"真实"适配器（宿主侧最小实现）。
///
/// 目标：把创意模块从"只接受注入假源"推进到可以在真实宿主上跑的最小后端：
/// * [CreativeTargetDirectory] 从既有 `ai_profile` / `ai_operator` / `account`
///   枚举 (owner, aiProfile) 对，供 [SqliteReportTargetProvider] /
///   [SqliteRadioTargetProvider] 使用。
/// * [CreativeAuthorizationPolicy]：授权范围策略（授权配置的数据契约目前缺失，
///   见文件末尾"外部缺口"）。未授权（空集合）的对象不会进入调度，绝不读取。
/// * [SqliteCreativeActivitySource]：读 owner 私有的预聚合活动表
///   `creative_activity`（迁移 802），只按 owner/ai/窗口过滤，不读任何跨用户正文。
/// * [TemplateReportLetterWriter]：确定性一封信（无模型）；真实 AI 信件属 M07。
/// * [FileBackedVoiceSynthesizer]：把脚本落成离线缓存文件的最小后端（音色回显），
///   真实 TTS 厂商属 M08。
///
/// 外部缺口（未定接口，用可注入接口隔离，不在本切片伪造）：
/// * 授权配置持久化：谁的哪个 AI 向哪类数据（私聊/群/朋友圈）授权统计——
///   目前无表/无契约，由 [CreativeAuthorizationPolicy] 注入；默认拒绝。
/// * 活动采集写入方：`creative_activity` 由 M06/M07 在生成话题/打卡/心情时写入；
///   本切片只提供读取端。
/// * 真实 TTS / 音色目录由 M08 voice 提供；本切片用 [CreativeVoiceDirectory] 读取
///   已存在的 `voice_profiles.voice_id`（若装配了 voice 迁移）。
library;

import 'dart:convert';
import 'dart:io';

import '../storage/database.dart';
import 'reports/reports_models.dart';
import 'radio/radio_models.dart';

/// 授权范围策略。返回空集合表示"未授权任何数据域"，调用方据此跳过。
abstract class CreativeAuthorizationPolicy {
  Future<Set<CreativeScope>> scopesFor({
    required String ownerAccountId,
    required String aiProfileId,
  });
}

/// 内存授权配置（供装配/测试注入）。
class InMemoryCreativeAuthorizationPolicy implements CreativeAuthorizationPolicy {
  final Map<String, Set<CreativeScope>> _grants = <String, Set<CreativeScope>>{};

  String _key(String owner, String ai) => '$owner\u0000$ai';

  void grant(String ownerAccountId, String aiProfileId, Set<CreativeScope> scopes) {
    _grants[_key(ownerAccountId, aiProfileId)] = {...scopes};
  }

  @override
  Future<Set<CreativeScope>> scopesFor({
    required String ownerAccountId,
    required String aiProfileId,
  }) async => _grants[_key(ownerAccountId, aiProfileId)] ?? const <CreativeScope>{};
}

/// 音色目录：把 (owner, aiProfile) 映射到档案音色 id。
abstract class CreativeVoiceDirectory {
  Future<String?> voiceIdFor({
    required String ownerAccountId,
    required String aiProfileId,
  });
}

/// 内存音色目录（供装配/测试注入）。
class InMemoryCreativeVoiceDirectory implements CreativeVoiceDirectory {
  final Map<String, String> _voices = <String, String>{};

  String _key(String owner, String ai) => '$owner\u0000$ai';

  void set(String ownerAccountId, String aiProfileId, String voiceId) {
    _voices[_key(ownerAccountId, aiProfileId)] = voiceId;
  }

  @override
  Future<String?> voiceIdFor({
    required String ownerAccountId,
    required String aiProfileId,
  }) async => _voices[_key(ownerAccountId, aiProfileId)];
}

/// SQLite 音色目录：从 `ai_profile` 解析 AI 账号，再取 `voice_profiles.voice_id`。
///
/// 依赖 M08 的 voice 迁移已装配（`voice_profiles` 表存在）。
class SqliteCreativeVoiceDirectory implements CreativeVoiceDirectory {
  SqliteCreativeVoiceDirectory({required this.database});

  final Database database;

  @override
  Future<String?> voiceIdFor({
    required String ownerAccountId,
    required String aiProfileId,
  }) async {
    final rows = await database.query(
      '''
SELECT v.voice_id AS voice_id
FROM ai_profile p
JOIN account a ON a.id = p.account_id AND a.kind = 'ai' AND a.disabled = 0
JOIN ai_operator o ON o.ai_id = a.id AND o.operator_id = ?
JOIN voice_profiles v ON v.ai_id = a.id
WHERE p.id = ?
''',
      [ownerAccountId, aiProfileId],
    );
    return rows.isEmpty ? null : rows.single['voice_id'] as String;
  }
}

/// 从既有身份表枚举 (owner, aiProfile) 对。只读，不带任何正文。
class CreativeTargetDirectory {
  CreativeTargetDirectory({required this.database, required this.authorization});

  final Database database;
  final CreativeAuthorizationPolicy authorization;

  Future<List<({String ownerAccountId, String aiProfileId})>> pairs() async {
    final rows = await database.query('''
SELECT o.operator_id AS owner, p.id AS ai_profile
FROM ai_profile p
JOIN account a ON a.id = p.account_id AND a.kind = 'ai' AND a.disabled = 0
JOIN ai_operator o ON o.ai_id = a.id
JOIN account owner ON owner.id = o.operator_id AND owner.kind = 'human' AND owner.disabled = 0
ORDER BY o.operator_id, p.id
''');
    return [
      for (final row in rows)
        (
          ownerAccountId: row['owner'] as String,
          aiProfileId: row['ai_profile'] as String,
        ),
    ];
  }
}

/// 报告目标提供者（真实版）：按身份表枚举 + 授权策略过滤。
class SqliteReportTargetProvider implements ReportTargetProvider {
  SqliteReportTargetProvider(this.directory);

  final CreativeTargetDirectory directory;

  @override
  Future<List<ReportTarget>> targets() async {
    final result = <ReportTarget>[];
    for (final pair in await directory.pairs()) {
      final scopes = await directory.authorization.scopesFor(
        ownerAccountId: pair.ownerAccountId,
        aiProfileId: pair.aiProfileId,
      );
      if (scopes.isEmpty) continue; // 未授权 → 不进入调度，绝不读取
      result.add(
        ReportTarget(
          ownerAccountId: pair.ownerAccountId,
          aiId: pair.aiProfileId,
          authorizedScopes: scopes,
        ),
      );
    }
    return result;
  }
}

/// 电台目标提供者（真实版）：需要身份对 + 档案音色（音色一致要求）。
class SqliteRadioTargetProvider implements RadioTargetProvider {
  SqliteRadioTargetProvider({required this.directory, required this.voices});

  final CreativeTargetDirectory directory;
  final CreativeVoiceDirectory voices;

  @override
  Future<List<RadioTarget>> targets() async {
    final result = <RadioTarget>[];
    for (final pair in await directory.pairs()) {
      final voiceId = await voices.voiceIdFor(
        ownerAccountId: pair.ownerAccountId,
        aiProfileId: pair.aiProfileId,
      );
      if (voiceId == null || voiceId.isEmpty) continue; // 无档案音色不生成
      result.add(
        RadioTarget(
          ownerAccountId: pair.ownerAccountId,
          aiId: pair.aiProfileId,
          profileVoiceId: voiceId,
        ),
      );
    }
    return result;
  }
}

/// 从 owner 私有预聚合活动表读取（迁移 802）。只按 owner/ai/窗口过滤，
/// 不读取任何消息/日记正文（label 为上游已脱敏的话题/里程碑标签）。
class SqliteCreativeActivitySource implements CreativeActivitySource {
  SqliteCreativeActivitySource({required this.database});

  final Database database;

  @override
  Future<List<CreativeActivity>> collect({
    required String ownerAccountId,
    required String aiId,
    required String windowStartDay,
    required String windowEndDay,
  }) async {
    final rows = await database.query(
      '''
SELECT scope, kind, day_key, label, value
FROM creative_activity
WHERE owner_account_id = ? AND ai_id = ? AND day_key >= ? AND day_key <= ?
ORDER BY day_key, kind, label
''',
      [ownerAccountId, aiId, windowStartDay, windowEndDay],
    );
    return [
      for (final row in rows)
        CreativeActivity(
          ownerAccountId: ownerAccountId,
          aiId: aiId,
          scope: CreativeScope.values.byName(row['scope'] as String),
          kind: CreativeActivityKind.values.byName(row['kind'] as String),
          dayKey: row['day_key'] as String,
          label: (row['label'] as String?) ?? '',
          value: (row['value'] as int?) ?? 0,
        ),
    ];
  }
}

/// 确定性一封信（无模型）。真实 AI 手写信属 M07，注入本接口即可替换。
class TemplateReportLetterWriter implements ReportLetterWriter {
  const TemplateReportLetterWriter();

  @override
  Future<String> writeLetter(ReportLetterContext context) async {
    final scopeLabel = context.kind == ReportKind.weekly ? '这周' : '这一年';
    if (context.commonTopics.isEmpty) {
      return '$scopeLabel我们安安静静，也是一起走过的日子。';
    }
    final lead = context.commonTopics.first.label;
    return '$scopeLabel我们聊了很多关于「$lead」的事，'
        '一起完成了 ${context.completedAgreements} 个约定，'
        '打卡 ${context.checkinDays} 天。想和你继续这样走下去。';
  }
}

/// 把脚本落成离线缓存文件的最小 TTS 后端（音色回显，不接真实厂商）。
///
/// 真实 TTS（M08 厂商）未定；本实现保证 [RadioAudio.ref] 指向一个真实存在的缓存
/// 文件，从而"预生成可离线听"的存储侧契约可被验证。音色回显保证与档案一致。
class FileBackedVoiceSynthesizer implements VoiceSynthesizer {
  FileBackedVoiceSynthesizer({required this.cacheDir});

  final String cacheDir;

  @override
  Future<RadioAudio?> synthesize({
    required String script,
    required String voiceId,
  }) async {
    if (script.trim().isEmpty || voiceId.trim().isEmpty) return null;
    final directory = Directory(cacheDir);
    await directory.create(recursive: true);
    final name = '${_slug(voiceId)}-${_fnv1a(script)}.txt';
    final file = File('${directory.path}${Platform.pathSeparator}$name');
    await file.writeAsString(script, flush: true);
    return RadioAudio(voiceId: voiceId, ref: file.path);
  }

  static String _slug(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static String _fnv1a(String value) {
    var hash = 0x811c9dc5;
    for (final code in utf8.encode(value)) {
      hash ^= code;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
