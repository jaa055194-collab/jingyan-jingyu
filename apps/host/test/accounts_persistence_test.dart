import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

bool _containsBytes(List<int> haystack, List<int> needle) {
  for (var offset = 0; offset <= haystack.length - needle.length; offset++) {
    var matches = true;
    for (var index = 0; index < needle.length; index++) {
      if (haystack[offset + index] != needle[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

void _expectNoPlaintext(Directory directory, List<String> secrets) {
  // Read raw bytes: decoding SQLite as text can discard or alter byte sequences.
  // Include every file so the WAL and SHM cannot accidentally escape the scan.
  final files = directory
      .listSync(followLinks: false)
      .whereType<File>()
      .toList();
  expect(files, isNotEmpty);
  for (final file in files) {
    final bytes = file.readAsBytesSync();
    for (var index = 0; index < secrets.length; index++) {
      // Boolean assertions deliberately keep credentials out of failure output.
      expect(
        _containsBytes(bytes, utf8.encode(secrets[index])),
        isFalse,
        reason: 'Credential $index must not occur in persisted file bytes',
      );
    }
  }
}

void main() {
  test(
    'M02 credential secrecy in database WAL and SHM survives restart and revocation',
    () async {
      final directory = await Directory.systemTemp.createTemp('m02-secrecy-');
      final absoluteDirectory = directory.absolute.path;
      final temporaryRoot = Directory.systemTemp.absolute.path;
      final databaseFile = File('$absoluteDirectory/host.sqlite');
      SqliteDatabase? database;
      try {
        database = await SqliteDatabase.open(databaseFile.path);
        var store = SqlAccountsStore(database);
        await store.start();
        final clock = FakeClock(DateTime.utc(2026));
        var domain = AccountsDomain(
          store: store,
          clock: clock,
          hasher: PasswordHasher(),
        );
        final random = Random.secure();
        final password = base64Url.encode(
          List.generate(32, (_) => random.nextInt(256)),
        );
        final admin = (await domain.bootstrapAdmin(
          displayName: 'Persistence administrator',
          password: password,
        )).value;
        final original = (await domain.login(
          admin,
          password,
          deviceName: 'Before restart',
        )).value;
        final session = (await domain.scope(original.accessToken)).value;
        final invite = (await session.invites.issue(
          expiresAt: clock.now().add(const Duration(days: 1)),
        )).value;
        final secrets = [
          password,
          original.accessToken,
          original.refreshToken,
          invite,
        ];
        final hash =
            (await store.snapshot()).accounts[admin.value]!['passwordHash']
                as String;
        final hashParts = hash.split(r'$');
        expect(hashParts.length, 6);
        expect(hashParts[1], 'v1');
        expect(hashParts[3], '600000');
        expect(base64Url.decode(base64Url.normalize(hashParts[4])).length, 16);
        expect(base64Url.decode(base64Url.normalize(hashParts[5])).length, 32);
        expect(await database.schemaVersion(), 101);
        expect(File('${databaseFile.path}-wal').existsSync(), isTrue);
        expect(File('${databaseFile.path}-shm').existsSync(), isTrue);
        _expectNoPlaintext(directory, secrets);

        await database.close();
        database = null;
        _expectNoPlaintext(directory, secrets);
        database = await SqliteDatabase.open(databaseFile.path);
        store = SqlAccountsStore(database);
        await store.start();
        domain = AccountsDomain(
          store: store,
          clock: clock,
          hasher: PasswordHasher(),
        );
        expect(await database.schemaVersion(), 101);
        expect(
          (await store.snapshot()).accounts[admin.value]!['passwordHash'] ==
              hash,
          isTrue,
        );
        expect(
          (await domain.authenticate(original.accessToken))?.accountId,
          admin.value,
        );
        final refreshed = (await domain.refresh(original.refreshToken)).value;
        secrets.addAll([refreshed.accessToken, refreshed.refreshToken]);
        expect((await domain.refresh(original.refreshToken)).isErr, isTrue);
        expect(await domain.authenticate(original.accessToken), isNull);
        final afterRestart = (await domain.login(
          admin,
          password,
          deviceName: 'After restart',
        )).value;
        secrets.addAll([afterRestart.accessToken, afterRestart.refreshToken]);
        final restartedSession = (await domain.scope(
          afterRestart.accessToken,
        )).value;
        expect((await restartedSession.inviteMetadata()).value.length, 1);
        expect(
          (await restartedSession.devices.revoke(
            admin,
            refreshed.deviceId,
          )).isOk,
          isTrue,
        );
        expect(await domain.authenticate(refreshed.accessToken), isNull);
        expect((await domain.refresh(refreshed.refreshToken)).isErr, isTrue);
        expect(
          (await domain.authenticate(afterRestart.accessToken))?.isAdmin,
          isTrue,
        );
        _expectNoPlaintext(directory, secrets);
        await database.close();
        database = null;
        _expectNoPlaintext(directory, secrets);
      } finally {
        try {
          await database?.close();
        } finally {
          // Only remove the exact absolute temporary directory created above.
          final separator = Platform.pathSeparator;
          if (directory.absolute.path != absoluteDirectory ||
              !absoluteDirectory.startsWith('$temporaryRoot$separator') ||
              !directory.uri.pathSegments
                  .where((segment) => segment.isNotEmpty)
                  .last
                  .startsWith('m02-secrecy-')) {
            throw StateError('Refusing to delete an unexpected temporary path');
          }
          if (directory.existsSync()) await directory.delete(recursive: true);
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
