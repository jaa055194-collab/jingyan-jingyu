import 'dart:async';

import 'package:jingyu_host/src/audit/audit_log.dart';
import 'package:test/test.dart';

/// Shared observable contract; factory may open persistent storage.
void storageAuditContract(String label, FutureOr<AuditLog> Function() create) {
  group('M01-8 AuditLog contract [$label]', () {
    late AuditLog log;
    setUp(() async => log = await create());
    test(
      'isolates targets by kind and id and preserves insertion order',
      () async {
        AuditEntry entry(String kind, String id, int seq) => AuditEntry(
          at: DateTime.parse('2026-11-13T06:00:00.123456Z'),
          actorId: 'u$seq',
          action: 'message.edit',
          targetKind: kind,
          targetId: id,
          meta: {
            'seq': seq,
            'ok': true,
            'ratio': 1.5,
            'ref': 'edit-$seq',
            'empty': null,
          },
        );
        expect(await log.forTarget('message', 'a'), isEmpty);
        await log.record(entry('message', 'a', 1));
        await log.record(entry('message', 'b', 2));
        await log.record(entry('memory', 'a', 3));
        await log.record(entry('message', 'a', 4));
        final found = await log.forTarget('message', 'a');
        expect(found.map((e) => e.actorId), ['u1', 'u4']);
        expect(
          found.first.at.toUtc(),
          DateTime.parse('2026-11-13T06:00:00.123456Z'),
        );
        expect(found.first.action, 'message.edit');
        expect(found.first.meta, {
          'seq': 1,
          'ok': true,
          'ratio': 1.5,
          'ref': 'edit-1',
          'empty': null,
        });
        expect((await log.forTarget('message', 'b')).single.actorId, 'u2');
        expect(await log.forTarget("message' OR 1=1 --", 'a'), isEmpty);
      },
    );
    test('rejects content, secrets and nested metadata before recording', () {
      for (final meta in [
        {'body': 'private'},
        {'key': 'secret'},
        {'nested': <String, Object?>{}},
      ]) {
        expect(
          () => AuditEntry(
            at: DateTime.utc(2026),
            actorId: 'u',
            action: 'edit',
            targetKind: 'message',
            targetId: 'a',
            meta: meta,
          ),
          throwsArgumentError,
        );
      }
    });
  });
}
