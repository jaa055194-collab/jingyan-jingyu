import 'package:jingyu_client_kit/src/draft_store.dart';
import 'package:test/test.dart';

final DateTime t0 = DateTime.utc(2026, 11, 15, 10);
final DateTime t1 = DateTime.utc(2026, 11, 15, 11);

void main() {
  group('DraftStore basics', () {
    test('save then read a draft per conversation', () {
      final DraftStore store = DraftStore();
      store.save('acc-1', 'conv-1', '你好，草稿', updatedAt: t0);
      expect(store.draftText('acc-1', 'conv-1'), '你好，草稿');
      final ConversationDraft? d = store.draft('acc-1', 'conv-1');
      expect(d, isNotNull);
      expect(d!.conversationId, 'conv-1');
      expect(d.updatedAt, t0);
      expect(store.hasDraft('acc-1', 'conv-1'), isTrue);
    });

    test('accounts and conversations are isolated', () {
      final DraftStore store = DraftStore();
      store.save('acc-1', 'conv-1', 'A1', updatedAt: t0);
      store.save('acc-2', 'conv-1', 'B1', updatedAt: t0);
      store.save('acc-1', 'conv-2', 'A2', updatedAt: t0);
      expect(store.draftText('acc-1', 'conv-1'), 'A1');
      expect(store.draftText('acc-2', 'conv-1'), 'B1');
      expect(store.draftText('acc-1', 'conv-2'), 'A2');
      expect(store.draftText('acc-2', 'conv-2'), isNull);
    });

    test('overwrite updates text and updatedAt', () {
      final DraftStore store = DraftStore();
      store.save('acc-1', 'conv-1', 'old', updatedAt: t0);
      store.save('acc-1', 'conv-1', 'new', updatedAt: t1);
      expect(store.draftText('acc-1', 'conv-1'), 'new');
      expect(store.draft('acc-1', 'conv-1')!.updatedAt, t1);
    });

    test('empty or whitespace-only text clears the draft', () {
      final DraftStore store = DraftStore();
      store.save('acc-1', 'conv-1', 'x', updatedAt: t0);
      store.save('acc-1', 'conv-1', '   ', updatedAt: t1);
      expect(store.draftText('acc-1', 'conv-1'), isNull);
      expect(store.hasDraft('acc-1', 'conv-1'), isFalse);
    });

    test('list is deterministic (updatedAt desc, then conversation id)', () {
      final DraftStore store = DraftStore();
      store.save('acc-1', 'b', 'B', updatedAt: t0);
      store.save('acc-1', 'a', 'A', updatedAt: t0);
      store.save('acc-1', 'c', 'C', updatedAt: t1);
      final List<String> ids = store
          .drafts('acc-1')
          .map((ConversationDraft d) => d.conversationId)
          .toList();
      expect(ids, <String>['c', 'a', 'b']);
    });

    test('clear and clearAccount scope correctly', () {
      final DraftStore store = DraftStore();
      store.save('acc-1', 'conv-1', 'x', updatedAt: t0);
      store.save('acc-1', 'conv-2', 'y', updatedAt: t0);
      store.save('acc-2', 'conv-1', 'z', updatedAt: t0);
      store.clear('acc-1', 'conv-1');
      expect(store.draftText('acc-1', 'conv-1'), isNull);
      store.clearAccount('acc-1');
      expect(store.drafts('acc-1'), isEmpty);
      expect(store.draftText('acc-2', 'conv-1'), 'z');
    });
  });

  group('DraftStore snapshot', () {
    test('export/import round-trips unicode and updatedAt (UTC)', () {
      final DraftStore store = DraftStore();
      store.save('acc-1', 'conv-1', '表情 😀 草稿\n第二行', updatedAt: t1);
      store.save('acc-1', 'conv-2', '二', updatedAt: t0);
      final Map<String, Object?> snap = store.exportAccount('acc-1');

      final DraftStore restored = DraftStore();
      restored.importAccount('acc-1', snap);
      expect(restored.draftText('acc-1', 'conv-1'), '表情 😀 草稿\n第二行');
      expect(restored.draft('acc-1', 'conv-1')!.updatedAt, t1);
      expect(restored.draftText('acc-1', 'conv-2'), '二');
    });

    test('corrupt snapshot fails closed and leaves current data intact', () {
      final DraftStore store = DraftStore();
      store.save('acc-1', 'conv-1', 'keep', updatedAt: t0);

      expect(
        () => store.importAccount('acc-1', <String, Object?>{
          'version': 2,
          'drafts': <Object?>[],
        }),
        throwsFormatException,
      );
      expect(
        () => store.importAccount('acc-1', <String, Object?>{
          'version': 1,
          'drafts': 'nope',
        }),
        throwsFormatException,
      );
      expect(
        () => store.importAccount('acc-1', <String, Object?>{
          'version': 1,
          'drafts': <Object?>[
            <String, Object?>{
              'conversationId': 'conv-1',
              'text': 'a',
              'updatedAt': 'not-a-date',
            },
          ],
        }),
        throwsFormatException,
      );
      // Duplicate conversation id in one snapshot is rejected.
      expect(
        () => store.importAccount('acc-1', <String, Object?>{
          'version': 1,
          'drafts': <Object?>[
            <String, Object?>{
              'conversationId': 'c',
              'text': 'a',
              'updatedAt': t0.toIso8601String(),
            },
            <String, Object?>{
              'conversationId': 'c',
              'text': 'b',
              'updatedAt': t0.toIso8601String(),
            },
          ],
        }),
        throwsFormatException,
      );
      expect(store.draftText('acc-1', 'conv-1'), 'keep');
    });

    test('invalid account or conversation id is rejected', () {
      final DraftStore store = DraftStore();
      expect(
        () => store.save('bad id', 'conv-1', 'x', updatedAt: t0),
        throwsFormatException,
      );
      expect(
        () => store.save('acc-1', 'bad id', 'x', updatedAt: t0),
        throwsFormatException,
      );
    });
  });
}
