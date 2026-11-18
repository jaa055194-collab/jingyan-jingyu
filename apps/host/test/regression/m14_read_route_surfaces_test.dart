/// M14 regression: the merged read-only route surfaces must be mounted in the
/// DEFAULT host assembly (not only in isolated module tests).
///
/// Covers:
///  - `GET /api/v1/friends`                (owner-scoped friends list)
///  - `GET /api/v1/lifecycle/cleanup/preview` (owner-scoped retention preview)
///  - `GET /api/v1/attachments` (owner-scoped attachment metadata list)
library;

import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('M14 read route surfaces (default host assembly)', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('m14-routes-');
    });

    tearDown(() async {
      await directory.delete(recursive: true);
    });

    Future<Host> boot() => buildHost(
      config: HostConfig(dataDir: directory.path),
      clock: FakeClock(DateTime.utc(2026, 11, 18, 1)),
    );

    test(
      'friends list and cleanup preview are mounted as authenticated GETs',
      () async {
        final host = await boot();
        try {
          final described = host.registry.router.describe();
          bool has(String method, String path) =>
              described.any((line) => line.startsWith('$method $path '));

          expect(
            has('GET', Routes.friends),
            isTrue,
            reason: 'friends list route must be in default assembly',
          );
          expect(
            has('GET', Routes.lifecycleCleanupPreview),
            isTrue,
            reason: 'cleanup preview route must be in default assembly',
          );

          // Both must require authentication (never public).
          final friendsLine = described.singleWhere(
            (l) => l.startsWith('GET ${Routes.friends} '),
          );
          expect(friendsLine, contains('[authenticated]'));
          final previewLine = described.singleWhere(
            (l) => l.startsWith('GET ${Routes.lifecycleCleanupPreview} '),
          );
          expect(previewLine, contains('[authenticated]'));
        } finally {
          await host.shutdown();
        }
      },
    );

    test(
      'attachments collection list is mounted as an authenticated GET',
      () async {
        final host = await boot();
        try {
          final routes = host.registry.router.describe().where(
            (line) => line.startsWith('GET /api/v1/attachments '),
          );
          expect(routes, hasLength(1));
          expect(routes.single, contains('[authenticated]'));
        } finally {
          await host.shutdown();
        }
      },
    );
  });
}
