import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:client_flutter/data/file_persistence.dart';

void main() {
  test(
    'draft and outbox snapshot survive closing and reopening storage',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'jingyu-storage-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final first = FilePersistence(File('${directory.path}/snapshot.json'));
      await first.write({
        'shell': {
          'drafts': {'friend': '未发送'},
          'outbox': [
            {'clientMsgId': 'stable-id'},
          ],
        },
      });
      final restored = await FilePersistence(
        File('${directory.path}/snapshot.json'),
      ).read();
      expect((restored['shell'] as Map)['drafts'], {'friend': '未发送'});
      expect(
        ((restored['shell'] as Map)['outbox'] as List).single['clientMsgId'],
        'stable-id',
      );
    },
  );
  test('corrupt primary snapshot restores last durable backup', () async {
    final directory = await Directory.systemTemp.createTemp('jingyu-recovery-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/snapshot.json');
    final store = FilePersistence(file);
    await store.write({'draft': 'first'});
    await store.write({'draft': 'second'});
    await file.writeAsString('{invalid');
    expect(await FilePersistence(file).read(), {'draft': 'first'});
  });
}
