import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/lifecycle/chat_history_export_source.dart';
import 'package:jingyu_host/src/lifecycle/export.dart';
import 'package:jingyu_host/src/messages/message_store.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _UnreadableSource extends InMemoryExportSource {
  @override
  Future<List<ExportConversation>> conversations(String ownerAccountId) async {
    throw StateError('private message body from storage');
  }
}

StoredMessage _message(String conversationId, int seq) => StoredMessage(
  conversationId: conversationId,
  seq: seq,
  messageId: 'message-$seq',
  senderId: 'sender',
  clientMsgId: 'client-$seq',
  kind: MessageKind.text,
  body: {'text': 'message $seq: an apiKey example in chat'},
  sentAt: DateTime.utc(2026, 1, 1, 0, 0, seq),
);

Future<Map<String, int?>> _allVisible(
  String owner,
  Iterable<String> ids,
) async => {for (final id in ids) id: 1};

void main() {
  test(
    'exports a sorted, deduplicated visible suffix to a fixed head',
    () async {
      final pages = <(String, int, int)>[];
      final source = ChatHistoryExportSource(
        readVisibilitySnapshot: _allVisible,
        listConversationIds: (owner) async {
          expect(owner, 'owner');
          return ['visible', 'hidden', 'empty', 'visible'];
        },
        firstVisibleSeq: (owner, id) async {
          expect(owner, 'owner');
          return switch (id) {
            'visible' => 3,
            'empty' => 1,
            _ => null,
          };
        },
        headSeq: (id) async => switch (id) {
          'visible' => 5,
          'empty' => 0,
          _ => throw StateError('must not read unauthorized conversation'),
        },
        readPage:
            ({
              required conversationId,
              required afterSeq,
              int limit = 200,
            }) async {
              pages.add((conversationId, afterSeq, limit));
              // Sequence 6 arrived after the head snapshot.
              final messages = [
                for (var seq = 1; seq <= 6; seq++) _message('visible', seq),
              ];
              return Ok(
                SyncPage(
                  messages.skip(afterSeq).take(limit).toList(),
                  hasMore: afterSeq + limit < messages.length,
                ),
              );
            },
        pageSize: 2,
      );

      final bundle = (await ExportService(
        source: source,
      ).export('owner')).value;
      expect(pages, [('visible', 2, 2), ('visible', 4, 1)]);
      expect(
        bundle.files.keys.where((path) => path.startsWith('conversations/')),
        ['conversations/empty.jsonl', 'conversations/visible.jsonl'],
      );
      expect(bundle.file('conversations/empty.jsonl'), isEmpty);
      final rows = bundle
          .file('conversations/visible.jsonl')!
          .split('\n')
          .map(jsonDecode)
          .cast<Map<String, Object?>>();
      expect(rows.map((row) => row['seq']), [3, 4, 5]);
      expect(rows.first, {
        'messageId': 'message-3',
        'conversationId': 'visible',
        'seq': 3,
        'senderId': 'sender',
        'kind': 'text',
        'body': {'text': 'message 3: an apiKey example in chat'},
        'sentAt': '2026-01-01T00:00:03.000Z',
      });
      expect(bundle.manifest()['formatVersion'], 1);
      expect(bundle.manifest()['coverage'], {
        'scope': 'chatHistory',
        'completeAccountExport': false,
        'pendingDomains': ['persona', 'memories', 'attachments'],
      });
      expect(bundle.manifest()['counts'], {
        'conversations': 2,
        'messages': 3,
        'memories': 0,
        'attachments': 0,
        'persona': 0,
      });
      for (final path in ['manifest.json', 'conversations/visible.jsonl']) {
        final digest = sha256.convert(utf8.encode(bundle.file(path)!));
        expect(bundle.sha256Sums().split('\n'), contains('$digest  $path'));
      }
    },
  );

  test(
    'rechecks earlier conversations after later paging changes access',
    () async {
      final floors = <String, int>{'leaving': 1, 'rejoined': 1, 'trigger': 1};
      var snapshotRead = false;
      final source = ChatHistoryExportSource(
        readVisibilitySnapshot: (owner, ids) async {
          expect(owner, 'owner');
          expect(ids, ['leaving', 'rejoined', 'trigger']);
          expect(snapshotRead, isFalse);
          snapshotRead = true;
          final snapshot = {for (final id in ids) id: floors[id]};
          // Later policy changes cannot mix with this coherent observation.
          floors['leaving'] = 1;
          floors['rejoined'] = 1;
          return snapshot;
        },
        listConversationIds: (_) async => floors.keys.toList(),
        firstVisibleSeq: (_, id) async {
          if (snapshotRead) throw StateError('per-ID access after snapshot');
          return floors[id];
        },
        headSeq: (_) async => 2,
        readPage:
            ({
              required conversationId,
              required afterSeq,
              int limit = 200,
            }) async {
              if (conversationId == 'trigger') {
                floors.remove('leaving');
                floors['rejoined'] = 2;
              }
              return Ok(
                SyncPage([
                  _message(conversationId, 1),
                  _message(conversationId, 2),
                ], hasMore: false),
              );
            },
      );

      final bundle = (await ExportService(
        source: source,
      ).export('owner')).value;
      expect(bundle.file('conversations/leaving.jsonl'), isNull);
      final rejoined = bundle.file('conversations/rejoined.jsonl')!;
      expect(
        rejoined
            .split('\n')
            .map(jsonDecode)
            .cast<Map<String, Object?>>()
            .single['seq'],
        2,
      );
      expect((bundle.manifest()['counts']! as Map)['messages'], 3);
    },
  );

  for (final visibility in <String, Map<String, int?>>{
    'missing key': {},
    'foreign key': {'a': 1, 'foreign': 1},
    'nonpositive floor': {'a': 0},
  }.entries) {
    test('invalid final snapshot ${visibility.key} fails closed', () async {
      final source = ChatHistoryExportSource(
        readVisibilitySnapshot: (_, _) async => visibility.value,
        listConversationIds: (_) async => ['a'],
        firstVisibleSeq: (_, _) async => 1,
        headSeq: (_) async => 0,
        readPage:
            ({
              required conversationId,
              required afterSeq,
              int limit = 200,
            }) async => const Ok(SyncPage([], hasMore: false)),
      );
      final result = await ExportService(source: source).export('owner');
      expect(result.valueOrNull, isNull);
      expect(result.failureOrNull?.code, FailureCode.internal);
    });
  }

  final brokenPages = <String, Result<SyncPage>>{
    'foreign conversation': Ok(
      SyncPage([_message('elsewhere', 1)], hasMore: true),
    ),
    'sequence gap': Ok(SyncPage([_message('broken', 2)], hasMore: false)),
    'duplicate cursor': Ok(
      SyncPage([_message('broken', 1), _message('broken', 1)], hasMore: false),
    ),
    'no progress': const Ok(SyncPage([], hasMore: true)),
    'premature end': Ok(SyncPage([_message('broken', 1)], hasMore: false)),
    'unreadable body': err(FailureCode.internal, 'private data from storage'),
  };
  for (final entry in brokenPages.entries) {
    test('fails the whole export for ${entry.key}', () async {
      final source = ChatHistoryExportSource(
        readVisibilitySnapshot: _allVisible,
        listConversationIds: (_) async => ['already-read', 'broken'],
        firstVisibleSeq: (_, _) async => 1,
        headSeq: (id) async => id == 'already-read' ? 1 : 2,
        readPage:
            ({
              required conversationId,
              required afterSeq,
              int limit = 200,
            }) async => conversationId == 'broken'
            ? entry.value
            : Ok(SyncPage([_message(conversationId, 1)], hasMore: false)),
      );
      final result = await ExportService(source: source).export('owner');
      expect(result.valueOrNull, isNull);
      expect(result.failureOrNull?.code, FailureCode.internal);
      expect(result.failureOrNull?.message, isNot(contains('private')));
      expect(result.failureOrNull?.details, isEmpty);
    });
  }

  test(
    'invalid conversation IDs fail before they become bundle paths',
    () async {
      final source = ChatHistoryExportSource(
        readVisibilitySnapshot: _allVisible,
        listConversationIds: (_) async => ['../bad'],
        firstVisibleSeq: (_, _) async => 1,
        headSeq: (_) async => 0,
        readPage:
            ({
              required conversationId,
              required afterSeq,
              int limit = 200,
            }) async => const Ok(SyncPage([], hasMore: false)),
      );
      final result = await ExportService(source: source).export('owner');
      expect(result.valueOrNull, isNull);
      expect(result.failureOrNull?.code, FailureCode.internal);
    },
  );

  for (final kind in ['conversations', 'messages', 'encodedBytes']) {
    test('$kind cap fails without publishing a partial bundle', () async {
      final source = ChatHistoryExportSource(
        readVisibilitySnapshot: _allVisible,
        listConversationIds: (_) async => ['a', 'b'],
        firstVisibleSeq: (_, _) async => 1,
        headSeq: (_) async => 2,
        readPage:
            ({
              required conversationId,
              required afterSeq,
              int limit = 200,
            }) async => Ok(
              SyncPage([
                _message(conversationId, 1),
                _message(conversationId, 2),
              ], hasMore: false),
            ),
        maxConversations: kind == 'conversations' ? 1 : 10,
        maxMessages: kind == 'messages' ? 3 : 10,
        maxEncodedBytes: kind == 'encodedBytes' ? 1 : 10000,
      );
      final result = await ExportService(source: source).export('owner');
      expect(result.valueOrNull, isNull);
      expect(result.failureOrNull?.code, FailureCode.internal);
      expect(result.failureOrNull?.details, isEmpty);
    });
  }

  test('exact count and UTF-8 byte caps permit the complete payload', () async {
    final stored = StoredMessage(
      conversationId: 'a',
      seq: 1,
      messageId: 'message-1',
      senderId: 'sender',
      clientMsgId: 'client-1',
      kind: MessageKind.text,
      body: {'text': '你好'},
      sentAt: DateTime.utc(2026),
    );
    final jsonLine =
        '{"messageId":"message-1","conversationId":"a","seq":1,'
        '"senderId":"sender","kind":"text","body":{"text":"你好"},'
        '"sentAt":"2026-01-01T00:00:00.000Z"}';
    final source = ChatHistoryExportSource(
      readVisibilitySnapshot: _allVisible,
      listConversationIds: (_) async => ['a'],
      firstVisibleSeq: (_, _) async => 1,
      headSeq: (_) async => 1,
      readPage:
          ({
            required conversationId,
            required afterSeq,
            int limit = 200,
          }) async => Ok(SyncPage([stored], hasMore: false)),
      maxConversations: 1,
      maxMessages: 1,
      maxEncodedBytes: utf8.encode(jsonLine).length + 1,
    );
    final bundle = (await ExportService(source: source).export('owner')).value;
    expect(bundle.file('conversations/a.jsonl'), jsonLine);
  });

  for (final invalid in ['head', 'initialFloor', 'recheckedFloor']) {
    test(
      'invalid $invalid fails instead of reporting an empty success',
      () async {
        final source = ChatHistoryExportSource(
          readVisibilitySnapshot: (_, ids) async => {
            for (final id in ids) id: invalid == 'recheckedFloor' ? 0 : 1,
          },
          listConversationIds: (_) async => ['a'],
          firstVisibleSeq: (_, _) async => invalid == 'initialFloor' ? 0 : 1,
          headSeq: (_) async => invalid == 'head' ? -1 : 0,
          readPage:
              ({
                required conversationId,
                required afterSeq,
                int limit = 200,
              }) async => const Ok(SyncPage([], hasMore: false)),
        );
        final result = await ExportService(source: source).export('owner');
        expect(result.valueOrNull, isNull);
        expect(result.failureOrNull?.code, FailureCode.internal);
      },
    );
  }

  test(
    'import request cap counts escaped files and refuses partial export',
    () async {
      final source = InMemoryExportSource();
      source.addConversation(
        ExportConversation(
          conversationId: 'a',
          messages: [
            ExportMessage(
              messageId: 'm',
              conversationId: 'a',
              seq: 1,
              senderId: 'sender',
              kind: 'text',
              body: {'text': 'quoted "text"\\newline\n你好'},
              sentAt: DateTime.utc(2026),
            ),
          ],
        ),
      );
      final clock = FakeClock(DateTime.utc(2026));
      final original = (await ExportService(
        source: source,
        clock: clock,
      ).export('owner')).value;
      // The import request JSON escapes the already encoded file contents again.
      final requestBytes = utf8
          .encode(
            jsonEncode({
              'mode': 'personaAndConversations',
              'files': original.files,
            }),
          )
          .length;
      expect(
        requestBytes,
        greaterThan(
          original.files.values.fold<int>(
            0,
            (total, text) => total + utf8.encode(text).length,
          ),
        ),
      );
      final rejected = await ExportService(
        source: source,
        clock: clock,
        maxImportRequestBytes: requestBytes - 1,
      ).export('owner');
      expect(rejected.valueOrNull, isNull);
      expect(rejected.failureOrNull?.code, FailureCode.internal);
      expect(rejected.failureOrNull?.message, isNot(contains('quoted')));
      final accepted = await ExportService(
        source: source,
        clock: clock,
        maxImportRequestBytes: requestBytes,
      ).export('owner');
      expect(accepted.value.files, original.files);
    },
  );

  test('legacy sources keep the version 1 manifest shape', () async {
    final clock = FakeClock(DateTime.utc(2026, 1, 1));
    final bundle = (await ExportService(
      source: InMemoryExportSource(),
      clock: clock,
    ).export('owner')).value;
    expect(bundle.manifest(), {
      'formatVersion': 1,
      'ownerAccountId': 'owner',
      'generatedAt': '2026-01-01T00:00:00.000Z',
      'counts': {
        'conversations': 0,
        'messages': 0,
        'memories': 0,
        'attachments': 0,
        'persona': 0,
      },
      'excluded': {'t2Memories': 0, 'byokSecrets': 'stripped'},
    });
  });

  test('an unreadable source returns a sanitized failure', () async {
    final result = await ExportService(
      source: _UnreadableSource(),
    ).export('owner');

    expect(result.valueOrNull, isNull);
    expect(result.failureOrNull?.code, FailureCode.internal);
    expect(result.failureOrNull?.message, isNot(contains('private')));
    expect(result.failureOrNull?.details, isEmpty);
  });
}
