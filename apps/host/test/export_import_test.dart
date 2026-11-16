/// M12 导出/导入（AC-29 / A-12 / NFR-11）。
///
/// 覆盖：完整导出再导入到空宿主后会话与记忆数量一致；仅人格导入不导聊天记录；
/// 导出包不含 T2 明文与 API key 明文；SHA256SUMS 防篡改；冲突不覆盖、生成新 id。
library;

import 'package:jingyu_host/src/lifecycle/export.dart';
import 'package:jingyu_host/src/lifecycle/import.dart';
import 'package:test/test.dart';

void main() {
  ExportMessage message(String id, String conv, int seq, String text) =>
      ExportMessage(
        messageId: id,
        conversationId: conv,
        seq: seq,
        senderId: 'u1',
        kind: 'text',
        body: {'text': text},
        sentAt: DateTime.utc(2026, 5, 1, 8, seq),
      );

  InMemoryExportSource seededSource() {
    final source = InMemoryExportSource();
    source.setPersona({
      'name': '小鲸',
      'model': 'model-x',
      'apiKey': 'sk-SECRET-abc',
      'nested': {'providerToken': 'tok-SECRET-xyz', 'label': 'ok'},
    });
    source.addConversation(
      ExportConversation(
        conversationId: 'c1',
        messages: [
          message('m1', 'c1', 1, '你好'),
          message('m2', 'c1', 2, '在吗'),
        ],
      ),
    );
    source.addConversation(
      ExportConversation(
        conversationId: 'c2',
        messages: [message('m3', 'c2', 1, '晚安')],
      ),
    );
    source.addMemory({'memoryId': 'mem1', 'tier': 'T0', 'text': '喜欢咖啡'});
    source.addMemory({'memoryId': 'mem2', 'tier': 'T1', 'text': '养了一只猫'});
    source.addMemory({'memoryId': 'mem3', 'tier': 'T2', 'text': 'T2-SECRET-BODY'});
    source.addAttachment({
      'attachmentId': 'a1',
      'name': 'cat.png',
      'sha256': 'deadbeef',
    });
    return source;
  }

  late ExportService exportService;
  setUp(() => exportService = ExportService(source: seededSource()));

  group('导出包结构', () {
    test('包含 manifest / SHA256SUMS / 会话 JSONL / 记忆 / 附件索引 / 人格', () async {
      final bundle = (await exportService.export('u1')).value;
      expect(bundle.files.containsKey('manifest.json'), isTrue);
      expect(bundle.files.containsKey('SHA256SUMS'), isTrue);
      expect(bundle.files.containsKey('persona.json'), isTrue);
      expect(bundle.files.containsKey('memories.json'), isTrue);
      expect(bundle.files.containsKey('attachments.json'), isTrue);
      expect(bundle.files.containsKey('conversations/c1.jsonl'), isTrue);
      expect(bundle.files.containsKey('conversations/c2.jsonl'), isTrue);

      final manifest = bundle.manifest();
      expect(manifest['ownerAccountId'], 'u1');
      expect((manifest['counts']! as Map)['conversations'], 2);
      expect((manifest['counts']! as Map)['messages'], 3);
      expect((manifest['counts']! as Map)['attachments'], 1);
      expect((manifest['excluded']! as Map)['t2Memories'], 1);
    });

    test('每个数据文件都有对应的 SHA256SUMS 行且校验匹配', () async {
      final bundle = (await exportService.export('u1')).value;
      final lines = bundle.sha256Sums().trim().split('\n');
      final listed = <String>{};
      for (final line in lines) {
        final parts = line.split('  ');
        expect(parts.length, 2);
        listed.add(parts[1]);
      }
      expect(
        listed,
        bundle.files.keys.where((k) => k != 'SHA256SUMS').toSet(),
      );
    });
  });

  group('NFR-11 不含明文密钥与 T2', () {
    test('导出包全文搜不到 API key 与 T2 明文', () async {
      final bundle = (await exportService.export('u1')).value;
      final all = bundle.allText();
      expect(all.contains('sk-SECRET-abc'), isFalse);
      expect(all.contains('tok-SECRET-xyz'), isFalse);
      expect(all.contains('T2-SECRET-BODY'), isFalse);
      // 非敏感字段仍保留
      expect(all.contains('小鲸'), isTrue);
      expect(all.contains('喜欢咖啡'), isTrue);
    });
  });

  group('AC-29 导出后再导入到空宿主', () {
    test('人格 + 聊天记录数量一致', () async {
      final bundle = (await exportService.export('u1')).value;
      final sink = InMemoryImportSink();
      final report = (await ImportService().import(
        bundle: bundle,
        mode: ImportMode.personaAndConversations,
        ownerAccountId: 'u1',
        sink: sink,
      )).value;

      expect(report.checksumVerified, isTrue);
      expect(report.importedPersona, 1);
      expect(report.importedConversations, 2);
      expect(report.importedMessages, 3);
      expect(report.importedMemories, 2);
      expect(report.importedAttachments, 1);
      expect(report.conflicts, isEmpty);

      expect(await sink.hasPersona('u1'), isTrue);
      expect(sink.conversationCount('u1'), 2);
      expect(sink.messageCount('u1'), 3);
      expect(sink.memoriesFor('u1').length, 2);
      expect(sink.attachmentsFor('u1').length, 1);
    });
  });

  group('A-12 仅人格导入', () {
    test('只导入人格，不导入聊天记录', () async {
      final bundle = (await exportService.export('u1')).value;
      final sink = InMemoryImportSink();
      final report = (await ImportService().import(
        bundle: bundle,
        mode: ImportMode.personaOnly,
        ownerAccountId: 'u1',
        sink: sink,
      )).value;

      expect(report.importedPersona, 1);
      expect(report.importedConversations, 0);
      expect(report.importedMessages, 0);
      expect(report.importedMemories, 0);
      expect(await sink.hasPersona('u1'), isTrue);
      expect(sink.conversationCount('u1'), 0);
    });
  });

  group('SHA256SUMS 防篡改', () {
    test('被篡改的会话文件导致导入被拒', () async {
      final bundle = (await exportService.export('u1')).value;
      final tampered = ExportBundle(
        ownerAccountId: bundle.ownerAccountId,
        files: {
          ...bundle.files,
          'conversations/c1.jsonl': '{"messageId":"evil"}\n',
        },
      );
      final result = await ImportService().import(
        bundle: tampered,
        mode: ImportMode.personaAndConversations,
        ownerAccountId: 'u1',
        sink: InMemoryImportSink(),
      );
      expect(result.isErr, isTrue);
      expect(result.failureOrNull, isNotNull);
    });

    test('缺少 SHA256SUMS 时拒绝导入', () async {
      final bundle = (await exportService.export('u1')).value;
      final noSums = ExportBundle(
        ownerAccountId: bundle.ownerAccountId,
        files: {...bundle.files}..remove('SHA256SUMS'),
      );
      final result = await ImportService().import(
        bundle: noSums,
        mode: ImportMode.personaAndConversations,
        ownerAccountId: 'u1',
        sink: InMemoryImportSink(),
      );
      expect(result.isErr, isTrue);
    });
  });

  group('冲突不覆盖、生成新 id', () {
    test('已有同 id 会话时生成新会话 id 并记录冲突', () async {
      final bundle = (await exportService.export('u1')).value;
      final sink = InMemoryImportSink();
      // 预先占用 c1
      await sink.putConversation('u1', 'c1', <ExportMessage>[]);
      final report = (await ImportService().import(
        bundle: bundle,
        mode: ImportMode.personaAndConversations,
        ownerAccountId: 'u1',
        sink: sink,
      )).value;

      final convConflicts = report.conflicts.where(
        (c) => c.kind == 'conversation',
      );
      expect(convConflicts.length, 1);
      expect(convConflicts.single.oldId, 'c1');
      expect(convConflicts.single.newId, isNot('c1'));
      // 原 c1 未被覆盖（仍为空），新会话承载 2 条消息
      expect(sink.conversationCount('u1'), 3);
      expect(sink.messageCount('u1'), 3);
      expect(sink.messagesFor('u1', 'c1'), isEmpty);
    });

    test('已有同人格时跳过并记录冲突，不覆盖原人格', () async {
      final bundle = (await exportService.export('u1')).value;
      final sink = InMemoryImportSink();
      await sink.putPersona('u1', {'name': '原人格'});
      final report = (await ImportService().import(
        bundle: bundle,
        mode: ImportMode.personaOnly,
        ownerAccountId: 'u1',
        sink: sink,
      )).value;
      expect(report.importedPersona, 0);
      expect(report.conflicts.any((c) => c.kind == 'persona'), isTrue);
      expect(sink.personaFor('u1')!['name'], '原人格');
    });
  });
}
