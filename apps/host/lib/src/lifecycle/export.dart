/// M12 用户导出（口径 A-12 / AC-29 / NFR-11）。
///
/// 按数据源的覆盖范围导出用户数据，形成可校验的数据包：
/// * `manifest.json`：格式版本、账号、生成时间、对象计数、已排除项；
/// * `SHA256SUMS`：每个数据文件的 sha256，供导入前校验；
/// * `conversations/<id>.jsonl`：每个会话的消息逐行 JSON；
/// * `memories.json`：记忆快照（**不含 T2 明文**）；
/// * `attachments.json`：附件索引；
/// * `persona.json`：AI 配置（**剥离 BYOK 明文密钥**）。
///
/// 本文件只做纯内存组装，不写真实文件系统；落盘/打包（tar + age）由宿主适配器负责。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

/// 导出用消息（与 StoredMessage.toPayload 同构）。
class ExportMessage {
  const ExportMessage({
    required this.messageId,
    this.conversationId = '',
    required this.seq,
    required this.senderId,
    required this.kind,
    required this.body,
    required this.sentAt,
  });

  final String messageId;
  final String conversationId;
  final int seq;
  final String senderId;
  final String kind;
  final Map<String, Object?> body;
  final DateTime sentAt;

  Map<String, Object?> toJson() => {
    'messageId': messageId,
    'conversationId': conversationId,
    'seq': seq,
    'senderId': senderId,
    'kind': kind,
    'body': body,
    'sentAt': sentAt.toUtc().toIso8601String(),
  };

  factory ExportMessage.fromJson(Map<String, Object?> json) => ExportMessage(
    messageId: json['messageId']! as String,
    conversationId: (json['conversationId'] as String?) ?? '',
    seq: (json['seq']! as num).toInt(),
    senderId: json['senderId']! as String,
    kind: json['kind']! as String,
    body: (json['body'] as Map).cast<String, Object?>(),
    sentAt: DateTime.parse(json['sentAt']! as String),
  );

  ExportMessage copyWith({String? messageId, String? conversationId}) =>
      ExportMessage(
        messageId: messageId ?? this.messageId,
        conversationId: conversationId ?? this.conversationId,
        seq: seq,
        senderId: senderId,
        kind: kind,
        body: body,
        sentAt: sentAt,
      );
}

/// 导出用会话。
class ExportConversation {
  const ExportConversation({
    required this.conversationId,
    required this.messages,
  });

  final String conversationId;
  final List<ExportMessage> messages;
}

/// 导出数据源契约。持久化实现（SQLite）按 owner 过滤后返回。
abstract class ExportSource {
  Future<Map<String, Object?>?> persona(String ownerAccountId);

  Future<List<ExportConversation>> conversations(String ownerAccountId);

  /// 每条记忆必须带 `tier` 字段（T0/T1/T2），导出会剔除 T2。
  Future<List<Map<String, Object?>>> memories(String ownerAccountId);

  Future<List<Map<String, Object?>>> attachments(String ownerAccountId);
}

/// Optional manifest metadata describing the domains a source covers.
abstract interface class ExportCoverage {
  Map<String, Object?> get coverage;
}

/// 内存数据源：测试与框架示例使用。
class InMemoryExportSource implements ExportSource {
  Map<String, Object?>? _persona;
  final List<ExportConversation> _conversations = <ExportConversation>[];
  final List<Map<String, Object?>> _memories = <Map<String, Object?>>[];
  final List<Map<String, Object?>> _attachments = <Map<String, Object?>>[];

  void setPersona(Map<String, Object?> persona) => _persona = persona;

  void addConversation(ExportConversation conversation) =>
      _conversations.add(conversation);

  void addMemory(Map<String, Object?> memory) => _memories.add(memory);

  void addAttachment(Map<String, Object?> attachment) =>
      _attachments.add(attachment);

  @override
  Future<Map<String, Object?>?> persona(String ownerAccountId) async =>
      _persona;

  @override
  Future<List<ExportConversation>> conversations(String ownerAccountId) async =>
      List<ExportConversation>.of(_conversations);

  @override
  Future<List<Map<String, Object?>>> memories(String ownerAccountId) async =>
      List<Map<String, Object?>>.of(_memories);

  @override
  Future<List<Map<String, Object?>>> attachments(String ownerAccountId) async =>
      List<Map<String, Object?>>.of(_attachments);
}

/// 不应进入导出包的敏感字段名（BYOK 明文密钥、token 等）。
const Set<String> exportSecretKeys = {
  'apiKey',
  'api_key',
  'key',
  'token',
  'secret',
  'refreshToken',
  'refresh_token',
  'accessToken',
  'access_token',
  'ak',
  'sk',
};

/// 字段名是否像密钥/口令（大小写不敏感，覆盖 apiKey、providerToken 等变体）。
bool isSecretKey(String key) {
  if (exportSecretKeys.contains(key)) return true;
  final lower = key.toLowerCase();
  return lower.contains('token') ||
      lower.contains('key') ||
      lower.contains('secret');
}

/// 递归剥离敏感字段，返回新结构（不修改入参）。
Map<String, Object?> sanitizeForExport(Map<String, Object?> input) {
  final output = <String, Object?>{};
  for (final entry in input.entries) {
    if (isSecretKey(entry.key)) continue;
    final value = entry.value;
    if (value is Map) {
      output[entry.key] = sanitizeForExport(value.cast<String, Object?>());
    } else if (value is List) {
      output[entry.key] = [
        for (final item in value)
          if (item is Map)
            sanitizeForExport(item.cast<String, Object?>())
          else
            item,
      ];
    } else {
      output[entry.key] = value;
    }
  }
  return output;
}

/// 导出包：文件路径 → 文本内容。
class ExportBundle {
  const ExportBundle({required this.ownerAccountId, required this.files});

  final String ownerAccountId;
  final Map<String, String> files;

  String? file(String path) => files[path];

  Map<String, Object?> manifest() =>
      (jsonDecode(files['manifest.json']!) as Map).cast<String, Object?>();

  String sha256Sums() => files['SHA256SUMS'] ?? '';

  /// 全包文本，用于 NFR-11 明文扫描测试。
  String allText() => files.values.join('\n');
}

/// 导出服务。
class ExportService {
  ExportService({
    required ExportSource source,
    this.clock = const SystemClock(),
    this.maxImportRequestBytes,
  }) : _source = source;

  final ExportSource _source;
  final Clock clock;

  /// Optional transport bound for the complete version-1 JSON import request.
  /// Null preserves legacy source behavior; exceeding a bound fails, never trims.
  final int? maxImportRequestBytes;

  static const String manifestFile = 'manifest.json';
  static const String checksumsFile = 'SHA256SUMS';
  static const String personaFile = 'persona.json';
  static const String memoriesFile = 'memories.json';
  static const String attachmentsFile = 'attachments.json';
  static const String conversationsPrefix = 'conversations/';
  static const int formatVersion = 1;

  Future<Result<ExportBundle>> export(String ownerAccountId) async {
    if (ownerAccountId.trim().isEmpty) {
      return err(FailureCode.invalidArgument, '账号标识不能为空');
    }

    try {
      return Ok(await _buildBundle(ownerAccountId));
    } catch (_) {
      // Source and serialization errors may include private storage data.
      return err(FailureCode.internal, 'Could not build export');
    }
  }

  Future<ExportBundle> _buildBundle(String ownerAccountId) async {
    final source = _source;
    final persona = sanitizeForExport(
      await _source.persona(ownerAccountId) ?? const <String, Object?>{},
    );
    final conversations = await _source.conversations(ownerAccountId);

    final memories = <Map<String, Object?>>[];
    var excludedT2 = 0;
    for (final memory in await _source.memories(ownerAccountId)) {
      if ((memory['tier'] as String?) == 'T2') {
        excludedT2++;
        continue;
      }
      memories.add(sanitizeForExport(memory));
    }

    final attachments = [
      for (final attachment in await _source.attachments(ownerAccountId))
        sanitizeForExport(attachment),
    ];

    final files = <String, String>{};
    files[personaFile] = jsonEncode(persona);
    files[memoriesFile] = jsonEncode({
      'memories': memories,
      'excludedT2Count': excludedT2,
    });
    files[attachmentsFile] = jsonEncode({'attachments': attachments});
    var messageCount = 0;
    for (final conversation in conversations) {
      messageCount += conversation.messages.length;
      files['$conversationsPrefix${conversation.conversationId}.jsonl'] =
          conversation.messages.map((m) => jsonEncode(m.toJson())).join('\n');
    }

    files[manifestFile] = jsonEncode({
      'formatVersion': formatVersion,
      'ownerAccountId': ownerAccountId,
      'generatedAt': clock.now().toUtc().toIso8601String(),
      'counts': {
        'conversations': conversations.length,
        'messages': messageCount,
        'memories': memories.length,
        'attachments': attachments.length,
        'persona': persona.isEmpty ? 0 : 1,
      },
      'excluded': {'t2Memories': excludedT2, 'byokSecrets': 'stripped'},
      if (source case ExportCoverage(:final coverage)) 'coverage': coverage,
    });

    final paths = files.keys.toList()..sort();
    files[checksumsFile] = paths
        .map((p) => '${sha256.convert(utf8.encode(files[p]!))}  $p')
        .join('\n');

    final requestLimit = maxImportRequestBytes;
    if (requestLimit != null) {
      final requestBytes = utf8
          .encode(
            jsonEncode({'mode': 'personaAndConversations', 'files': files}),
          )
          .length;
      if (requestBytes > requestLimit) {
        throw StateError('Export exceeds import transport limit');
      }
    }
    return ExportBundle(ownerAccountId: ownerAccountId, files: files);
  }
}
