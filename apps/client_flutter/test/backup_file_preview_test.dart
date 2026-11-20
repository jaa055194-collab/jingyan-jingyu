import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/features/lifecycle/backup_file_preview.dart';
import 'package:client_flutter/net/lifecycle_api.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _owner = 'owner-fixture';
const _conversation = 'conversations/private-conversation.jsonl';
const _privateText = '合成聊天正文，不应出现在摘要';

Map<String, Object?> _package({String owner = _owner, bool chatOnly = true}) {
  final manifest = <String, Object?>{
    'formatVersion': 1,
    'ownerAccountId': owner,
    'generatedAt': '2026-03-01T11:45:12.000Z',
    'counts': {
      'conversations': 1,
      'messages': 1,
      'memories': 0,
      'attachments': 0,
      'persona': 0,
    },
    'excluded': {'t2Memories': 0, 'byokSecrets': 'stripped'},
    if (chatOnly)
      'coverage': {
        'scope': 'chatHistory',
        'completeAccountExport': false,
        'pendingDomains': ['persona', 'memories', 'attachments'],
      },
  };
  final envelope = <String, Object?>{
    'ownerAccountId': owner,
    'files': <String, String>{
      'persona.json': '{}',
      'memories.json': '{"memories":[],"excludedT2Count":0}',
      'attachments.json': '{"attachments":[]}',
      _conversation: jsonEncode({'seq': 1, 'text': _privateText}),
      // Key order does not change the manifest's JSON metadata.
      'manifest.json': jsonEncode({
        for (final key in manifest.keys.toList().reversed) key: manifest[key],
      }),
    },
    'manifest': manifest,
  };
  _rehash(envelope);
  return envelope;
}

Map<String, String> _files(Map<String, Object?> envelope) =>
    envelope['files']! as Map<String, String>;

void _setSums(Map<String, Object?> envelope, String sums) {
  envelope['sha256sums'] = sums;
  _files(envelope)['SHA256SUMS'] = sums;
}

void _rehash(Map<String, Object?> envelope) {
  final files = _files(envelope);
  final paths = files.keys.where((path) => path != 'SHA256SUMS').toList()
    ..sort();
  _setSums(
    envelope,
    [
      for (final path in paths)
        '${sha256.convert(utf8.encode(files[path]!))}  $path',
    ].join('\n'),
  );
}

Matcher _problem(BackupFilePreviewProblem problem) =>
    isA<BackupFilePreviewException>().having(
      (error) => error.problem,
      'problem',
      problem,
    );

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('jingyu-preview-test-');
    file = File(
      '${directory.path}${Platform.pathSeparator}private-export.json',
    );
  });
  tearDown(() => directory.delete(recursive: true));

  Future<BackupFilePreviewSummary> read() =>
      readBackupFilePreview(file, expectedOwnerAccountId: _owner);

  test(
    'app-written v1 file yields only checked summary and is left untouched',
    () async {
      final bytes = utf8.encode(
        LifecycleExportBundle.fromJson(_package()).exportFileContents(),
      );
      await file.writeAsBytes(bytes);
      final summary = await read();
      expect(summary.bytes, bytes.length);
      expect(summary.fileCount, 6);
      expect(summary.generatedAt, DateTime.utc(2026, 3, 1, 11, 45, 12));
      expect(summary.chatHistoryOnly, isTrue);
      expect(summary.counts, {
        'conversations': 1,
        'messages': 1,
        'memories': 0,
        'attachments': 0,
        'persona': 0,
      });
      expect(summary.toString(), isNot(contains(_privateText)));
      expect(summary.toString(), isNot(contains('private-conversation')));
      expect(await file.readAsBytes(), bytes);
      expect(await directory.list().map((entry) => entry.path).toList(), [
        file.path,
      ]);
    },
  );

  test(
    'legacy v1 manifest can omit coverage without asserting full export',
    () async {
      await file.writeAsString(jsonEncode(_package(chatOnly: false)));
      expect((await read()).chatHistoryOnly, isFalse);
    },
  );

  test(
    '4 MiB is inclusive; a real file with one more byte is refused',
    () async {
      final content = jsonEncode(_package());
      final bytes = utf8.encode(content);
      final limit = LifecycleExportBundle.maxFileBytes;
      await file.writeAsBytes([
        ...bytes,
        ...List<int>.filled(limit - bytes.length, 32),
      ]);
      expect((await read()).bytes, limit);
      // Still valid JSON, so parsing a truncated prefix could falsely succeed.
      await file.writeAsBytes([32], mode: FileMode.append);
      await expectLater(
        read(),
        throwsA(_problem(BackupFilePreviewProblem.tooLarge)),
      );
    },
  );

  test(
    'malformed UTF-8 is rejected rather than decoded with replacement',
    () async {
      await file.writeAsBytes([
        ...utf8.encode('{"ownerAccountId":"'),
        0xc3,
        0x28,
        34,
        125,
      ]);
      await expectLater(
        read(),
        throwsA(_problem(BackupFilePreviewProblem.invalid)),
      );
    },
  );

  test(
    'a missing file is reported without a local path in the error',
    () async {
      await expectLater(
        read(),
        throwsA(
          allOf(
            _problem(BackupFilePreviewProblem.unreadable),
            isNot(
              predicate<Object>(
                (error) => error.toString().contains(file.path),
              ),
            ),
          ),
        ),
      );
    },
  );

  test('a consistent package from a different owner is refused', () async {
    await file.writeAsString(jsonEncode(_package(owner: 'other-owner')));
    await expectLater(
      read(),
      throwsA(_problem(BackupFilePreviewProblem.wrongOwner)),
    );
  });

  test('duplicate top-level JSON names are not last-wins', () async {
    final json = jsonEncode(_package());
    await file.writeAsString(
      '{"ownerAccountId":"other-owner",${json.substring(1)}',
    );
    await expectLater(
      read(),
      throwsA(_problem(BackupFilePreviewProblem.invalid)),
    );
  });

  final invalid = <String, void Function(Map<String, Object?>)>{
    'extra envelope field': (envelope) => envelope['extra'] = true,
    'unsupported version': (envelope) {
      (envelope['manifest']! as Map)['formatVersion'] = 2;
    },
    'embedded owner disagrees even with fresh hashes': (envelope) {
      final files = _files(envelope);
      final embedded = jsonDecode(files['manifest.json']!) as Map;
      embedded['ownerAccountId'] = 'other-owner';
      files['manifest.json'] = jsonEncode(embedded);
      _rehash(envelope);
    },
    'outer counts disagree with embedded metadata': (envelope) {
      final manifest = envelope['manifest']! as Map;
      (manifest['counts'] as Map)['messages'] = 500;
    },
    'matching invalid counts are still invalid': (envelope) {
      final manifest = envelope['manifest']! as Map;
      (manifest['counts'] as Map)['messages'] = -1;
      _files(envelope)['manifest.json'] = jsonEncode(manifest);
      _rehash(envelope);
    },
    'tampered content': (envelope) =>
        _files(envelope)[_conversation] = 'changed',
    'unpaired surrogate cannot hash as a replacement character': (envelope) {
      _files(envelope)[_conversation] = String.fromCharCode(0xd800);
      _rehash(envelope);
    },
    'outer checksum text disagrees with embedded text': (envelope) {
      envelope['sha256sums'] = 'different';
    },
    'missing SHA256SUMS entry': (envelope) =>
        _files(envelope).remove('SHA256SUMS'),
    'missing checksum coverage': (envelope) {
      _setSums(
        envelope,
        (envelope['sha256sums']! as String).split('\n').skip(1).join('\n'),
      );
    },
    'duplicate checksum row': (envelope) {
      final sums = envelope['sha256sums']! as String;
      _setSums(envelope, '$sums\n${sums.split('\n').first}');
    },
    'extra checksum row': (envelope) {
      final sums = envelope['sha256sums']! as String;
      _setSums(envelope, '$sums\n${'0' * 64}  extra.json');
    },
    'checksum self-entry': (envelope) {
      final sums = envelope['sha256sums']! as String;
      _setSums(envelope, '$sums\n${'0' * 64}  SHA256SUMS');
    },
    'unexpected traversal entry even with matching hash': (envelope) {
      _files(envelope)['conversations/../outside.jsonl'] = 'opaque';
      _rehash(envelope);
    },
  };

  for (final entry in invalid.entries) {
    test('refuses ${entry.key}', () async {
      final envelope = _package();
      entry.value(envelope);
      await file.writeAsString(jsonEncode(envelope));
      await expectLater(
        read(),
        throwsA(_problem(BackupFilePreviewProblem.invalid)),
      );
    });
  }
}
