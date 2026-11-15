import 'dart:convert';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

CachedMessage _msg(
  String conversationId,
  int seq, {
  String? id,
  String text = 'hello',
  String kind = 'text',
}) => CachedMessage(
  messageId: id ?? 'm$seq',
  conversationId: conversationId,
  seq: seq,
  senderId: 'acct-a',
  kind: kind,
  body: {'text': text},
  sentAt: DateTime.utc(2026, 11, 15, 0, 0, seq),
);

void main() {
  late LocalMessageCache cache;

  setUp(() => cache = LocalMessageCache());

  test('upsert keeps seq order and reports new seqs', () {
    expect(cache.upsert('a', _msg('c1', 2)), isTrue);
    expect(cache.upsert('a', _msg('c1', 1)), isTrue);
    expect(cache.upsert('a', _msg('c1', 3)), isTrue);
    final list = cache.list('a', 'c1');
    expect(list.map((m) => m.seq), [1, 2, 3]);
    expect(cache.headSeq('a', 'c1'), 3);
  });

  test('same seq replaces content (edit) and is not new', () {
    cache.upsert('a', _msg('c1', 1, text: 'old'));
    final isNew = cache.upsert('a', _msg('c1', 1, text: 'new'));
    expect(isNew, isFalse);
    expect(cache.list('a', 'c1').single.body['text'], 'new');
    expect(cache.list('a', 'c1'), hasLength(1));
  });

  test('recall keeps placeholder at same seq and clears body', () {
    cache.upsert('a', _msg('c1', 1, text: 'secret'));
    cache.applyRecall('a', 'c1', 'm1');
    final message = cache.list('a', 'c1').single;
    expect(message.seq, 1);
    expect(message.recalled, isTrue);
    expect(message.body.containsKey('text'), isFalse);
    expect(message.body['recalled'], isTrue);
  });

  test('pagination honours afterSeq and limit', () {
    for (var seq = 1; seq <= 5; seq++) {
      cache.upsert('a', _msg('c1', seq));
    }
    expect(cache.list('a', 'c1', afterSeq: 2, limit: 2).map((m) => m.seq), [
      3,
      4,
    ]);
    expect(cache.list('a', 'c1', limit: 0), isEmpty);
  });

  test('accounts and conversations are isolated', () {
    cache.upsert('a', _msg('c1', 1));
    cache.upsert('b', _msg('c1', 1));
    cache.upsert('a', _msg('c2', 1, id: 'other-message'));
    expect(cache.list('a', 'c1'), hasLength(1));
    expect(cache.list('b', 'c1'), hasLength(1));
    expect(cache.list('a', 'c2'), hasLength(1));
    expect(cache.list('b', 'c2'), isEmpty);
  });

  test('export/import round-trips messages', () {
    cache.upsert('a', _msg('c1', 1, text: 'one'));
    cache.upsert('a', _msg('c1', 2, text: 'two'));
    cache.applyRecall('a', 'c1', 'm2');
    final snapshot = cache.exportAccount('a');
    final restored = LocalMessageCache()..importAccount('a', snapshot);
    final list = restored.list('a', 'c1');
    expect(list.map((m) => m.seq), [1, 2]);
    expect(list.first.body['text'], 'one');
    expect(list.last.recalled, isTrue);
  });

  test('caller body mutations cannot change a cached message', () {
    final body = <String, Object?>{
      'parts': <Object?>[
        <String, Object?>{'text': 'original'},
      ],
    };
    cache.upsert(
      'a',
      CachedMessage(
        messageId: 'm1',
        conversationId: 'c1',
        seq: 1,
        senderId: 'sender',
        kind: 'text',
        body: body,
        sentAt: DateTime.utc(2026),
      ),
    );
    ((body['parts'] as List).single as Map)['text'] = 'mutated';
    expect(
      jsonEncode(cache.list('a', 'c1').single.body),
      '{"parts":[{"text":"original"}]}',
    );
  });

  test('read results cannot mutate nested cached body values', () {
    cache.upsert(
      'a',
      CachedMessage(
        messageId: 'm1',
        conversationId: 'c1',
        seq: 1,
        senderId: 'sender',
        kind: 'text',
        body: {
          'parts': [
            {'text': 'original'},
          ],
        },
        sentAt: DateTime.utc(2026),
      ),
    );
    final result = cache.list('a', 'c1').single;
    expect(
      () => ((result.body['parts'] as List).single as Map)['text'] = 'bad',
      throwsUnsupportedError,
    );
    expect(
      jsonEncode(cache.list('a', 'c1').single.body),
      '{"parts":[{"text":"original"}]}',
    );
  });

  test('stale replay cannot restore recalled plaintext', () {
    final stale = _msg('c1', 1, text: 'secret');
    cache.upsert('a', stale);
    cache.applyRecall('a', 'c1', 'm1');
    cache.upsert('a', stale);
    final result = cache.list('a', 'c1').single;
    expect(result.recalled, isTrue);
    expect(result.body, {'recalled': true});
  });

  test('recalled input normalizes away any attached plaintext', () {
    cache.upsert(
      'a',
      CachedMessage(
        messageId: 'm1',
        conversationId: 'c1',
        seq: 1,
        senderId: 'sender',
        kind: 'text',
        body: {'text': 'secret'},
        sentAt: DateTime.utc(2026),
        recalled: true,
      ),
    );
    expect(cache.list('a', 'c1').single.body, {'recalled': true});
  });

  test('snapshot round trip retains immutable bodies and recall state', () {
    cache.upsert('a', _msg('c1', 1));
    cache.applyRecall('a', 'c1', 'm1');
    final decoded = (jsonDecode(jsonEncode(cache.exportAccount('a'))) as Map)
        .cast<String, Object?>();
    final restored = LocalMessageCache()..importAccount('a', decoded);
    restored.upsert('a', _msg('c1', 1, text: 'stale secret'));
    expect(restored.list('a', 'c1').single.body, {'recalled': true});
  });

  test('malformed snapshots leave existing account data intact', () {
    cache.upsert('a', _msg('c1', 1, text: 'keep'));
    expect(
      () => cache.importAccount('a', {'version': 2, 'messages': []}),
      throwsFormatException,
    );
    expect(cache.list('a', 'c1').single.body['text'], 'keep');
    expect(
      () => cache.importAccount('a', {
        'version': 1,
        'messages': [
          _msg('c2', 1).toJson(),
          {'messageId': 'broken'},
        ],
      }),
      throwsFormatException,
    );
    expect(cache.list('a', 'c1').single.body['text'], 'keep');
    expect(cache.list('a', 'c2'), isEmpty);
  });

  test('conflicting sequence identity cannot replace a cached message', () {
    cache.upsert('a', _msg('c1', 1, id: 'original'));
    expect(
      () => cache.upsert('a', _msg('c1', 1, id: 'different')),
      throwsArgumentError,
    );
    expect(cache.list('a', 'c1').single.messageId, 'original');
    expect(
      () => cache.upsert('a', _msg('c1', 2, id: 'original')),
      throwsArgumentError,
    );
    expect(cache.headSeq('a', 'c1'), 1);
  });

  test('restoring an older snapshot cannot revive a current recall', () {
    cache.upsert('a', _msg('c1', 1, text: 'secret'));
    final older = cache.exportAccount('a');
    cache.applyRecall('a', 'c1', 'm1');
    cache.importAccount('a', older);
    expect(cache.list('a', 'c1').single.recalled, isTrue);
    expect(cache.list('a', 'c1').single.body, {'recalled': true});
  });

  test('local timestamps survive snapshot restore and recall replay', () {
    final local = CachedMessage(
      messageId: 'm1',
      conversationId: 'c1',
      seq: 1,
      senderId: 'sender',
      kind: 'text',
      body: {'text': 'secret'},
      sentAt: DateTime.utc(2026, 11, 15).toLocal(),
    );
    cache.upsert('a', local);
    final older = cache.exportAccount('a');
    cache.applyRecall('a', 'c1', 'm1');
    cache.importAccount('a', older);
    expect(cache.list('a', 'c1').single.body, {'recalled': true});

    final restored = LocalMessageCache()..importAccount('a', older);
    expect(restored.upsert('a', local), isFalse);
    expect(restored.list('a', 'c1').single.body['text'], 'secret');
  });

  test('nonpositive sequences are rejected without cache writes', () {
    expect(() => cache.upsert('a', _msg('c1', 0)), throwsArgumentError);
    expect(cache.list('a', 'c1'), isEmpty);
  });

  test('clearConversation and clearAccount drop caches', () {
    cache.upsert('a', _msg('c1', 1));
    cache.upsert('a', _msg('c2', 1, id: 'other-message'));
    cache.clearConversation('a', 'c1');
    expect(cache.list('a', 'c1'), isEmpty);
    expect(cache.list('a', 'c2'), hasLength(1));
    cache.clearAccount('a');
    expect(cache.list('a', 'c2'), isEmpty);
  });
}
