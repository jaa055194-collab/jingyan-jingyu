import 'dart:convert';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _Custom {
  int calls = 0;
  Object toJson() {
    calls++;
    return {'custom': true};
  }
}

void main() {
  Outbox box() => Outbox(newClientMsgId: () => 'stable-id');

  test('enqueue detaches every nested JSON container from caller changes', () {
    final map = <String, Object?>{'text': 'original'};
    final inner = <Object?>[1, 2];
    final list = <Object?>[map, inner];
    final source = <String, Object?>{
      'list': list,
      'nested': map,
      'root': 'before',
    };
    final outbox = box();
    outbox.enqueue('c', MessageKind.card, source);
    final before = jsonEncode(outbox.items.single.body);
    source['root'] = 'after';
    map['text'] = 'changed';
    inner.add(3);
    list.clear();
    source['extra'] = true;
    expect(jsonEncode(outbox.items.single.body), before);
    expect(source['root'], 'after'); // Original inputs remain mutable.
  });

  test(
    'root maps nested maps and nested lists exposed by queue reject mutation',
    () {
      final outbox = box();
      outbox.enqueue('c', MessageKind.text, {
        'nested': {'text': 'hello'},
        'list': [
          {'n': 1},
          [2],
        ],
      });
      final body = outbox.items.single.body;
      expect(() => body['x'] = 1, throwsUnsupportedError);
      expect(
        () => (body['nested'] as Map)['text'] = 'bad',
        throwsUnsupportedError,
      );
      expect(() => (body['list'] as List).clear(), throwsUnsupportedError);
      expect(
        () => ((body['list'] as List).first as Map)['n'] = 2,
        throwsUnsupportedError,
      );
      expect(
        () => ((body['list'] as List).last as List).add(3),
        throwsUnsupportedError,
      );
      outbox.items.single.attempts = 3;
      expect(outbox.items.single.attempts, 3);
    },
  );

  test(
    'transient retry preserves captured body bytes and id after source mutation',
    () async {
      final nested = <String, Object?>{'text': 'queued'};
      final source = <String, Object?>{'nested': nested};
      final outbox = box();
      outbox.enqueue('c', MessageKind.text, source);
      final sent = <String>[];
      final ids = <String>[];
      final attempts = <int>[];
      final first = await outbox.flush((item) async {
        sent.add(jsonEncode(item.body));
        ids.add(item.clientMsgId);
        attempts.add(item.attempts);
        expect(() => item.body.clear(), throwsUnsupportedError);
        return err<void>(FailureCode.unavailable, 'offline');
      });
      expect(first.remaining, 1);
      nested['text'] = 'edited after attempt';
      source.clear();
      final second = await outbox.flush((item) async {
        sent.add(jsonEncode(item.body));
        ids.add(item.clientMsgId);
        attempts.add(item.attempts);
        return const Ok<void>(null);
      });
      expect(sent, [sent.first, sent.first]);
      expect(ids, ['stable-id', 'stable-id']);
      expect(attempts, [1, 2]);
      expect(second.sent, 1);
      expect(outbox.items, isEmpty);
    },
  );

  test(
    'normal restored item snapshots source but preserves item identity and metadata',
    () async {
      final source = <String, Object?>{
        'attachment': {'id': 'a1'},
        'parts': [1, 2],
      };
      final at = DateTime.utc(2026, 11, 15);
      final item = OutboxItem(
        conversationId: 'c',
        clientMsgId: 'restored',
        kind: MessageKind.file,
        body: source,
        queuedAt: at,
        attempts: 4,
      );
      (source['attachment'] as Map)['id'] = 'changed';
      (source['parts'] as List).clear();
      final outbox = box();
      outbox.restore([item]);
      expect(identical(outbox.items.single, item), true);
      expect(item.body, {
        'attachment': {'id': 'a1'},
        'parts': [1, 2],
      });
      expect(item.queuedAt, at);
      expect(item.kind, MessageKind.file);
      await outbox.flush((entry) async {
        expect(entry.attempts, 5);
        expect(entry.clientMsgId, 'restored');
        return const Ok<void>(null);
      });
    },
  );

  test(
    'generic JSON leaves unknown fields empty collections and Unicode stay wire encodable',
    () {
      final source = <String, Object?>{
        'unknown': [null, true, false, 42, 1.25, '鲸🐳', {}, []],
      };
      final outbox = box();
      outbox.enqueue('c', MessageKind.generatedImage, source);
      final item = outbox.items.single;
      final frame = SendMessageFrame(
        id: 'frame',
        at: DateTime.utc(2026),
        conversationId: 'c',
        clientMsgId: item.clientMsgId,
        kind: item.kind,
        body: item.body,
      );
      final decoded = decodeFrame(encodeFrame(frame));
      expect(decoded.isOk, true);
      expect((decoded.value as SendMessageFrame).body, source);
    },
  );

  test(
    'constructor does not invoke custom serialization or clone arbitrary leaves',
    () {
      final custom = _Custom();
      final item = OutboxItem(
        conversationId: 'c',
        clientMsgId: 'i',
        kind: MessageKind.card,
        body: {'leaf': custom},
        queuedAt: DateTime.utc(2026),
      );
      expect(custom.calls, 0);
      expect(identical(item.body['leaf'], custom), true);
      expect(jsonEncode(item.body), '{"leaf":{"custom":true}}');
      expect(custom.calls, 1);
    },
  );

  test(
    'container aliases and cycles stay detached readonly without eager validation',
    () {
      final shared = <Object?>[1];
      final source = <String, Object?>{'a': shared, 'b': shared};
      source['self'] = source;
      final item = OutboxItem(
        conversationId: 'c',
        clientMsgId: 'i',
        kind: MessageKind.card,
        body: source,
        queuedAt: DateTime.utc(2026),
      );
      expect(identical(item.body['self'], item.body), true);
      expect(identical(item.body['a'], item.body['b']), true);
      shared.add(2);
      expect(item.body['a'], [1]);
      expect(() => jsonEncode(item.body), throwsA(isA<JsonCyclicError>()));
      expect(() => (item.body['a'] as List).add(2), throwsUnsupportedError);
    },
  );
}
