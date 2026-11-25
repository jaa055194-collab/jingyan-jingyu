/// M12 用户导入（口径 A-12 / AC-29 / NFR-11）。
///
/// * 导入前用 `SHA256SUMS` 校验完整性，任何篡改/缺失即拒绝；
/// * 校验和通过不代表结构可导入：先完整解析本模式要消费的数据，
///   损坏的包在任何落点写入之前被整体拒绝（FR-65 / AC-29，无部分写入）；
/// * 支持"仅人格"与"人格 + 聊天记录"两种模式；
/// * 与既有数据冲突时不覆盖：生成新 id 并在报告中列出；
/// * 记忆里若混入 T2 也再次剔除（纵深防御）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

import 'export.dart';

/// 导入范围。
enum ImportMode { personaOnly, personaAndConversations }

/// 一条冲突（旧 id → 新 id）。
class ImportConflict {
  const ImportConflict({
    required this.kind,
    required this.oldId,
    required this.newId,
  });

  final String kind;
  final String oldId;
  final String newId;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'oldId': oldId,
    'newId': newId,
  };
}

/// 导入结果。
class ImportReport {
  const ImportReport({
    required this.mode,
    required this.checksumVerified,
    required this.importedPersona,
    required this.importedConversations,
    required this.importedMessages,
    required this.importedMemories,
    required this.importedAttachments,
    required this.conflicts,
  });

  final ImportMode mode;
  final bool checksumVerified;
  final int importedPersona;
  final int importedConversations;
  final int importedMessages;
  final int importedMemories;
  final int importedAttachments;
  final List<ImportConflict> conflicts;

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'checksumVerified': checksumVerified,
    'imported': {
      'persona': importedPersona,
      'conversations': importedConversations,
      'messages': importedMessages,
      'memories': importedMemories,
      'attachments': importedAttachments,
    },
    'conflicts': [for (final c in conflicts) c.toJson()],
  };
}

/// 导入落点契约：检查/写入一个 owner 的数据。
abstract class ImportSink {
  Future<bool> hasPersona(String ownerAccountId);

  Future<void> putPersona(String ownerAccountId, Map<String, Object?> persona);

  Future<bool> hasConversation(String ownerAccountId, String conversationId);

  Future<void> putConversation(
    String ownerAccountId,
    String conversationId,
    List<ExportMessage> messages,
  );

  Future<void> putMemories(
    String ownerAccountId,
    List<Map<String, Object?>> memories,
  );

  Future<void> putAttachments(
    String ownerAccountId,
    List<Map<String, Object?>> attachments,
  );
}

/// 内存落点：测试与框架示例使用，附只读查询便于断言。
class InMemoryImportSink implements ImportSink {
  final Map<String, Map<String, Object?>> _personas = {};
  final Map<String, Map<String, List<ExportMessage>>> _conversations = {};
  final Map<String, List<Map<String, Object?>>> _memories = {};
  final Map<String, List<Map<String, Object?>>> _attachments = {};

  @override
  Future<bool> hasPersona(String ownerAccountId) async =>
      _personas.containsKey(ownerAccountId);

  @override
  Future<void> putPersona(
    String ownerAccountId,
    Map<String, Object?> persona,
  ) async {
    _personas[ownerAccountId] = Map<String, Object?>.of(persona);
  }

  @override
  Future<bool> hasConversation(
    String ownerAccountId,
    String conversationId,
  ) async =>
      _conversations[ownerAccountId]?.containsKey(conversationId) ?? false;

  @override
  Future<void> putConversation(
    String ownerAccountId,
    String conversationId,
    List<ExportMessage> messages,
  ) async {
    (_conversations.putIfAbsent(
      ownerAccountId,
      () => <String, List<ExportMessage>>{},
    ))[conversationId] = List<ExportMessage>.of(
      messages,
    );
  }

  @override
  Future<void> putMemories(
    String ownerAccountId,
    List<Map<String, Object?>> memories,
  ) async {
    _memories
        .putIfAbsent(ownerAccountId, () => <Map<String, Object?>>[])
        .addAll(memories);
  }

  @override
  Future<void> putAttachments(
    String ownerAccountId,
    List<Map<String, Object?>> attachments,
  ) async {
    _attachments
        .putIfAbsent(ownerAccountId, () => <Map<String, Object?>>[])
        .addAll(attachments);
  }

  Map<String, Object?>? personaFor(String ownerAccountId) =>
      _personas[ownerAccountId];

  int conversationCount(String ownerAccountId) =>
      _conversations[ownerAccountId]?.length ?? 0;

  List<ExportMessage> messagesFor(
    String ownerAccountId,
    String conversationId,
  ) =>
      _conversations[ownerAccountId]?[conversationId] ??
      const <ExportMessage>[];

  int messageCount(String ownerAccountId) =>
      _conversations[ownerAccountId]?.values.fold<int>(
        0,
        (sum, list) => sum + list.length,
      ) ??
      0;

  List<Map<String, Object?>> memoriesFor(String ownerAccountId) =>
      _memories[ownerAccountId] ?? const <Map<String, Object?>>[];

  List<Map<String, Object?>> attachmentsFor(String ownerAccountId) =>
      _attachments[ownerAccountId] ?? const <Map<String, Object?>>[];
}

/// 解析后的会话：由 JSONL 路径推导出的原会话 id 与消息列表。
class _ParsedConversation {
  const _ParsedConversation({required this.oldId, required this.messages});

  final String oldId;
  final List<ExportMessage> messages;
}

/// 导入服务。
class ImportService {
  ImportService({String Function(String kind)? newId})
    : _newId = newId ?? _counterIds();

  final String Function(String kind) _newId;

  static String Function(String) _counterIds() {
    var n = 0;
    return (kind) => '$kind-imported-${++n}';
  }

  Future<Result<ImportReport>> import({
    required ExportBundle bundle,
    required ImportMode mode,
    required String ownerAccountId,
    required ImportSink sink,
  }) async {
    if (ownerAccountId.trim().isEmpty) {
      return err(FailureCode.invalidArgument, '账号标识不能为空');
    }
    final checksum = _verifyChecksums(bundle);
    if (checksum.isErr) return Err(checksum.failureOrNull!);

    final personaText = bundle.file(ExportService.personaFile);
    final memoriesText = bundle.file(ExportService.memoriesFile);
    if (personaText == null || memoriesText == null) {
      return err(FailureCode.invalidArgument, '导出包缺少必要文件');
    }

    // SHA256SUMS 只证明包未被篡改，不证明结构可导入。在任何落点写入
    // 之前，先完整解析本模式要消费的数据；损坏的包在此整体拒绝，
    // 不产生部分写入（FR-65 / AC-29）。
    final personaParsed = _parseJsonMap(ExportService.personaFile, personaText);
    if (personaParsed.isErr) return Err(personaParsed.failureOrNull!);
    final persona = personaParsed.value;

    final conversations = <_ParsedConversation>[];
    final memories = <Map<String, Object?>>[];
    List<Map<String, Object?>>? attachments;
    if (mode != ImportMode.personaOnly) {
      final conversationPaths =
          bundle.files.keys
              .where(
                (path) =>
                    path.startsWith(ExportService.conversationsPrefix) &&
                    path.endsWith('.jsonl'),
              )
              .toList()
            ..sort();
      for (final path in conversationPaths) {
        final parsed = _parseConversation(path, bundle.file(path)!);
        if (parsed.isErr) return Err(parsed.failureOrNull!);
        conversations.add(
          _ParsedConversation(
            oldId: path.substring(
              ExportService.conversationsPrefix.length,
              path.length - '.jsonl'.length,
            ),
            messages: parsed.value,
          ),
        );
      }

      final memoriesParsed = _parseMemories(
        ExportService.memoriesFile,
        memoriesText,
      );
      if (memoriesParsed.isErr) return Err(memoriesParsed.failureOrNull!);
      memories.addAll(
        memoriesParsed.value.where((memory) => memory['tier'] != 'T2').toList(),
      );

      final attachmentsText = bundle.file(ExportService.attachmentsFile);
      if (attachmentsText != null) {
        final attachmentsParsed = _parseAttachments(
          ExportService.attachmentsFile,
          attachmentsText,
        );
        if (attachmentsParsed.isErr) {
          return Err(attachmentsParsed.failureOrNull!);
        }
        attachments = attachmentsParsed.value;
      }
    }

    // 解析全部通过，开始写入；写入顺序与冲突语义保持不变。
    final conflicts = <ImportConflict>[];
    var importedPersona = 0;
    var importedConversations = 0;
    var importedMessages = 0;
    var importedMemories = 0;
    var importedAttachments = 0;

    if (await sink.hasPersona(ownerAccountId)) {
      conflicts.add(
        const ImportConflict(
          kind: 'persona',
          oldId: 'persona',
          newId: 'existing',
        ),
      );
    } else {
      await sink.putPersona(ownerAccountId, persona);
      if (persona.isNotEmpty) importedPersona = 1;
    }

    if (mode == ImportMode.personaOnly) {
      return Ok(
        ImportReport(
          mode: mode,
          checksumVerified: true,
          importedPersona: importedPersona,
          importedConversations: 0,
          importedMessages: 0,
          importedMemories: 0,
          importedAttachments: 0,
          conflicts: conflicts,
        ),
      );
    }

    for (final conversation in conversations) {
      final conflicting = await sink.hasConversation(
        ownerAccountId,
        conversation.oldId,
      );
      var targetConversationId = conversation.oldId;
      if (conflicting) {
        targetConversationId = _newId('conversation');
        conflicts.add(
          ImportConflict(
            kind: 'conversation',
            oldId: conversation.oldId,
            newId: targetConversationId,
          ),
        );
      }
      final stored = <ExportMessage>[];
      for (final message in conversation.messages) {
        if (conflicting) {
          final newMessageId = _newId('message');
          conflicts.add(
            ImportConflict(
              kind: 'message',
              oldId: message.messageId,
              newId: newMessageId,
            ),
          );
          stored.add(
            message.copyWith(
              messageId: newMessageId,
              conversationId: targetConversationId,
            ),
          );
        } else {
          stored.add(
            message.conversationId == targetConversationId
                ? message
                : message.copyWith(conversationId: targetConversationId),
          );
        }
      }
      await sink.putConversation(ownerAccountId, targetConversationId, stored);
      importedConversations++;
      importedMessages += stored.length;
    }

    await sink.putMemories(ownerAccountId, memories);
    importedMemories = memories.length;

    if (attachments != null) {
      await sink.putAttachments(ownerAccountId, attachments);
      importedAttachments = attachments.length;
    }

    return Ok(
      ImportReport(
        mode: mode,
        checksumVerified: true,
        importedPersona: importedPersona,
        importedConversations: importedConversations,
        importedMessages: importedMessages,
        importedMemories: importedMemories,
        importedAttachments: importedAttachments,
        conflicts: conflicts,
      ),
    );
  }

  Result<void> _verifyChecksums(ExportBundle bundle) {
    final sumsText = bundle.file(ExportService.checksumsFile);
    if (sumsText == null || sumsText.trim().isEmpty) {
      return err(FailureCode.invalidArgument, '缺少 SHA256SUMS');
    }
    final verified = <String>{};
    for (final line in sumsText.split('\n')) {
      if (line.trim().isEmpty) continue;
      final separator = line.indexOf('  ');
      if (separator <= 0) {
        return err(FailureCode.invalidArgument, 'SHA256SUMS 格式错误');
      }
      final expected = line.substring(0, separator);
      final path = line.substring(separator + 2);
      if (path == ExportService.checksumsFile) continue;
      final content = bundle.file(path);
      if (content == null) {
        return err(FailureCode.invalidArgument, '缺少导出文件 $path');
      }
      final actual = sha256.convert(utf8.encode(content)).toString();
      if (actual != expected) {
        return err(FailureCode.invalidArgument, 'SHA256 校验失败：$path');
      }
      verified.add(path);
    }
    if (bundle.files.keys.any(
      (path) => path != ExportService.checksumsFile && !verified.contains(path),
    )) {
      return err(FailureCode.invalidArgument, 'SHA256SUMS 未覆盖全部导出文件');
    }
    return const Ok<void>(null);
  }

  /// 解析一个 JSON 对象文件。语法或顶层结构损坏映射为安全 invalidArgument；
  /// 失败信息只含文件路径，不回显数据内容（NFR-06）。
  Result<Map<String, Object?>> _parseJsonMap(String path, String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return Ok(decoded.cast<String, Object?>());
      }
    } on FormatException {
      return err(FailureCode.invalidArgument, '导出包 JSON 损坏：$path');
    }
    return err(FailureCode.invalidArgument, '导出包数据结构损坏：$path');
  }

  /// 逐行解析会话 JSONL。损坏行（语法、顶层结构、字段类型）映射为安全
  /// invalidArgument，不在失败信息中回显行内容。
  Result<List<ExportMessage>> _parseConversation(String path, String text) {
    final messages = <ExportMessage>[];
    for (final line in text.split('\n')) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) {
          return err(FailureCode.invalidArgument, '导出包会话行结构损坏：$path');
        }
        messages.add(ExportMessage.fromJson(decoded.cast<String, Object?>()));
      } on FormatException {
        return err(FailureCode.invalidArgument, '导出包会话行损坏：$path');
      } on TypeError {
        return err(FailureCode.invalidArgument, '导出包会话字段类型损坏：$path');
      }
    }
    return Ok(messages);
  }

  /// 解析 memories.json。列表/条目/字段类型损坏映射为安全 invalidArgument。
  Result<List<Map<String, Object?>>> _parseMemories(String path, String text) {
    final root = _parseJsonMap(path, text);
    if (root.isErr) return Err(root.failureOrNull!);
    final rawList = root.value['memories'];
    if (rawList != null && rawList is! List) {
      return err(FailureCode.invalidArgument, '导出包记忆列表结构损坏：$path');
    }
    final memories = <Map<String, Object?>>[];
    for (final item in (rawList as List? ?? const [])) {
      if (item is! Map) {
        return err(FailureCode.invalidArgument, '导出包记忆条目结构损坏：$path');
      }
      final memory = item.cast<String, Object?>();
      final tier = memory['tier'];
      if (tier != null && tier is! String) {
        return err(FailureCode.invalidArgument, '导出包记忆字段类型损坏：$path');
      }
      memories.add(memory);
    }
    return Ok(memories);
  }

  /// 解析 attachments.json（可选文件）。列表/条目损坏映射为安全 invalidArgument。
  Result<List<Map<String, Object?>>> _parseAttachments(
    String path,
    String text,
  ) {
    final root = _parseJsonMap(path, text);
    if (root.isErr) return Err(root.failureOrNull!);
    final rawList = root.value['attachments'];
    if (rawList != null && rawList is! List) {
      return err(FailureCode.invalidArgument, '导出包附件列表结构损坏：$path');
    }
    final attachments = <Map<String, Object?>>[];
    for (final item in (rawList as List? ?? const [])) {
      if (item is! Map) {
        return err(FailureCode.invalidArgument, '导出包附件条目结构损坏：$path');
      }
      attachments.add(item.cast<String, Object?>());
    }
    return Ok(attachments);
  }
}
