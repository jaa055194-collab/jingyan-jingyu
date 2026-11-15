import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:client_flutter/data/account_snapshots.dart';

void main() {
  test(
    'same identity restores draft; host account device changes isolate it',
    () async {
      final root = await Directory.systemTemp.createTemp('m11-scopes-');
      addTearDown(() => root.delete(recursive: true));
      final scopes = AccountSnapshots(root);
      final a = await scopes.open(
        Uri.parse('https://host.example'),
        'alice',
        'phone',
      );
      await a.write({
        'draft': 'alice private',
        'outbox': ['stable-id'],
      });
      final again = await AccountSnapshots(root)
          .open(Uri.parse('https://host.example/'), 'alice', 'phone');
      expect(await again.read(), {
        'draft': 'alice private',
        'outbox': ['stable-id'],
      });
      for (final identity in [
        ['https://other.example', 'alice', 'phone'],
        ['https://host.example', 'bob', 'phone'],
        ['https://host.example', 'alice', 'desktop'],
      ]) {
        expect(
          await (await scopes.open(
            Uri.parse(identity[0]),
            identity[1],
            identity[2],
          )).read(),
          isEmpty,
        );
      }
      expect(await a.read(), {
        'draft': 'alice private',
        'outbox': ['stable-id'],
      });
    },
  );
  test(
    'legacy guest file is never attached and corrupt scope index fails closed',
    () async {
      final root = await Directory.systemTemp.createTemp('m11-legacy-');
      addTearDown(() => root.delete(recursive: true));
      final legacy = File('${root.path}/client.json');
      await legacy.writeAsString('{"draft":"legacy private"}');
      final scopes = AccountSnapshots(root);
      expect(
        await (await scopes.open(
          Uri.parse('https://host.example'),
          'alice',
          'phone',
        )).read(),
        isEmpty,
      );
      expect(await legacy.readAsString(), '{"draft":"legacy private"}');
      await File('${root.path}/accounts/index.json').writeAsString('bad');
      expect(
        () =>
            AccountSnapshots(root)
                .open(Uri.parse('https://host.example'), 'alice', 'phone'),
        throwsFormatException,
      );
    },
  );
}
