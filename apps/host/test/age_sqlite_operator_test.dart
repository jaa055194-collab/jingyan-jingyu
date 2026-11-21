import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host/src/storage/key_provider.dart';
import 'package:jingyu_host/src/storage/storage_module.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;
import 'package:test/test.dart';

import '../tool/age_recovery_tar.dart';
import '../tool/age_recovery_windows.dart'
    show RecoveryFailure, publishNoReplace;
import 'regression/hardening_support.dart';

final _tar = '${Platform.environment['SystemRoot']}\\System32\\tar.exe';
const _recipientShape =
    'age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq';

void main() {
  group(
    'offline operator guardrails',
    () {
      late Directory root;
      late Directory source;
      late File archive;

      setUp(() async {
        root = await Directory.systemTemp.createTemp('jingyu-age-guards-');
        source = await Directory('${root.path}/isolated source').create();
        archive = File('${root.path}/isolated archive.age');
        addTearDown(() => root.delete(recursive: true));
      });

      List<String> backupArguments({bool confirmed = true}) => [
        'backup',
        if (confirmed) '--host-stopped',
        '--data-dir', source.path,
        '--output', archive.path,
        '--recipient', _recipientShape,
        // These preflight cases refuse before executing either trusted tool.
        '--age', _tar,
      ];

      test('requires explicit stopped-host acknowledgment', () async {
        final result = await _operator(backupArguments(confirmed: false));
        _rejected(result, 'host_stopped_required');
        expect(await archive.exists(), isFalse);
      });

      test('rejects leftover WAL even when it has zero bytes', () async {
        final db = await File(
          '${source.path}/host.sqlite',
        ).writeAsString('fixture');
        final kek = await File('${db.path}.kek').writeAsString('fixture kek');
        final wal = await File('${db.path}-wal').create();
        final result = await _operator(backupArguments());
        _rejected(result, 'sqlite_sidecar_present');
        expect(await archive.exists(), isFalse);
        expect(await _entries(root), ['isolated source']);
        expect(await kek.readAsString(), 'fixture kek');
        expect(await wal.length(), 0);
      });

      test(
        'refuses concurrently open SQLite even without WAL or journal',
        () async {
          final path = '${source.path}/host.sqlite';
          final db = sqlite3.open(path);
          addTearDown(db.dispose);
          db.execute('CREATE TABLE fixture (id INTEGER)');
          await File('$path.kek').writeAsString('fixture kek');
          expect(await _entries(source), ['host.sqlite', 'host.sqlite.kek']);
          final result = await _operator(backupArguments());
          _rejected(result, 'source_open_or_unavailable');
          expect(await archive.exists(), isFalse);
          expect(
            db.select('PRAGMA integrity_check').single.values.single,
            'ok',
          );
        },
      );

      test('does not overwrite a previous encrypted archive', () async {
        await archive.writeAsString('prior backup');
        final result = await _operator(backupArguments());
        _rejected(result, 'output_exists');
        expect(await archive.readAsString(), 'prior backup');
        expect(await _entries(root), [
          'isolated archive.age',
          'isolated source',
        ]);
      });

      test(
        'requires a nonexistent restore path, even if existing dir is empty',
        () async {
          final target = await Directory(
            '${root.path}/already exists',
          ).create();
          final result = await _operator(
            _restoreArguments(
              age: _tar,
              archive: archive,
              target: target,
              digest: '0' * 64,
            ),
          );
          _rejected(result, 'target_exists');
          expect(await _entries(target), isEmpty);
        },
      );

      test(
        'refuses to publish over a destination created after preflight',
        () async {
          final stagedFile = await File(
            '${root.path}/cipher stage.age',
          ).writeAsString('new encrypted bytes');
          await archive.writeAsString('existing encrypted bytes');
          expect(
            () => publishNoReplace(stagedFile.path, archive.path),
            throwsA(isA<RecoveryFailure>()),
          );
          expect(await archive.readAsString(), 'existing encrypted bytes');
          expect(await stagedFile.readAsString(), 'new encrypted bytes');

          final stagedDirectory = await Directory(
            '${root.path}/restore stage',
          ).create();
          final occupied = await Directory(
            '${root.path}/restore occupied',
          ).create();
          final sentinel = await File(
            '${occupied.path}/sentinel',
          ).writeAsString('keep');
          expect(
            () => publishNoReplace(stagedDirectory.path, occupied.path),
            throwsA(isA<RecoveryFailure>()),
          );
          expect(await sentinel.readAsString(), 'keep');
          expect(await stagedDirectory.exists(), isTrue);
        },
      );

      test(
        'failed encryption publishes no output and leaves the source intact',
        () async {
          final storage = StorageModule(
            databasePath: '${source.path}/host.sqlite',
          );
          await storage.start();
          await storage.stop();
          final sourceDigests = await _pairDigests(source);
          final result = await _operator(backupArguments());
          // bsdtar was explicitly supplied instead of age, so its age operation
          // fails only after the real, valid DB/KEK pair was staged and checked.
          _rejected(result, 'age_encrypt_failed');
          expect(await _entries(root), ['isolated source']);
          expect(await _pairDigests(source), sourceDigests);
        },
      );

      test(
        'tar reader accepts two fixed regular members, not paths or links',
        () async {
          await File('${source.path}/host.sqlite').writeAsBytes([1, 2]);
          await File('${source.path}/host.sqlite.kek').writeAsBytes([3, 4]);
          final bytes = await _checked(_tar, [
            '--format',
            'ustar',
            '-cf',
            '-',
            '--',
            'host.sqlite',
            'host.sqlite.kek',
          ], directory: source.path);
          final pair = decodeSnapshotTar(bytes);
          expect(pair.database, [1, 2]);
          expect(pair.protectedKey, [3, 4]);

          final traversing = Uint8List.fromList(bytes)
            ..fillRange(0, 100, 0)
            ..setAll(0, ascii.encode('../escape'));
          final symbolicLink = Uint8List.fromList(bytes)..[156] = 0x32;
          final appended = Uint8List(bytes.length + 512)
            ..setAll(0, bytes)
            ..[bytes.length] = 1;
          for (final candidate in [traversing, symbolicLink, appended]) {
            // Recompute the standard header checksum so changed headers fail
            // inventory/type checks rather than just digest validation.
            candidate.fillRange(148, 156, 0x20);
            final checksum = candidate
                .take(512)
                .fold(0, (sum, next) => sum + next);
            candidate.setAll(
              148,
              ascii.encode(
                '${checksum.toRadixString(8).padLeft(6, '0')}\u0000 ',
              ),
            );
            expect(
              () => decodeSnapshotTar(candidate),
              throwsA(isA<RecoveryFailure>()),
            );
          }
        },
      );
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'operator round-trip preserves the actual closed host and refuses invalid restores',
    () async {
      final age = Platform.environment['JINGYU_TEST_AGE']!;
      final keygen = Platform.environment['JINGYU_TEST_AGE_KEYGEN']!;
      final tar = Platform.environment['JINGYU_TEST_TAR'] ?? _tar;
      final root = await Directory.systemTemp.createTemp(
        'jingyu-age-operator-',
      );
      addTearDown(() => root.delete(recursive: true));
      final h = await Harness.boot();
      var stopped = false;
      addTearDown(() async {
        if (!stopped) await h.host.shutdown();
        await h.dataDir.delete(recursive: true);
      });
      final owner = await h.seedAccount(
        displayName: 'Synthetic operator fixture',
        id: 'age-fixture-owner',
        token: syntheticToken('r'),
        isAdmin: true,
      );
      final group = await h.handle(
        'POST',
        Routes.conversations,
        token: owner.token,
        body: {
          'name': 'Synthetic operator recovery',
          'historyVisibility': 'all',
        },
      );
      expect(group.status, 200);
      final id = asMap(group)['id'] as String;
      const text = 'Synthetic offline recovery fixture message';
      final stored = (await h.host.registry.services.get<MessageStore>().append(
        conversationId: id,
        senderId: owner.id,
        clientMsgId: 'age-fixture-message',
        kind: MessageKind.text,
        body: {'text': text},
      )).value.message;
      expect(await h.host.shutdown(), isEmpty);
      stopped = true;
      final source = h.dataDir;
      final original = await _pairDigests(source);
      final identity = await _checked(keygen, const []);
      final wrongIdentity = await _checked(keygen, const []);
      addTearDown(() => identity.fillRange(0, identity.length, 0));
      addTearDown(() => wrongIdentity.fillRange(0, wrongIdentity.length, 0));
      final recipient = ascii
          .decode(await _checked(keygen, ['-y'], input: identity))
          .trim();
      final archive = File('${root.path}/fixture archive.age');
      final creation = await _operator([
        'backup',
        '--host-stopped',
        '--data-dir',
        source.path,
        '--output',
        archive.path,
        '--recipient',
        recipient,
        '--age',
        age,
        '--tar',
        tar,
      ]);
      expect(creation.exitCode, 0, reason: creation.report);
      expect(creation.text, contains('integrity_check=ok'));
      final encrypted = await archive.readAsBytes();
      final digest = sha256.convert(encrypted).toString();
      expect(creation.text, contains('sha256=$digest'));
      expect(encrypted.take(22), ascii.encode('age-encryption.org/v1\n'));
      expect(latin1.decode(encrypted), isNot(contains('SQLite format 3')));
      expect(latin1.decode(encrypted), isNot(contains(text)));
      expect(await _pairDigests(source), original);
      expect(
        (await _entries(source)).where((name) => name.endsWith('-wal')),
        isEmpty,
      );

      final suffixes = [
        'wrong',
        'digest',
        'tampered',
        'truncated',
        'extra',
        'transplant',
      ];
      final tampered = Uint8List.fromList(encrypted)
        ..[encrypted.length - 1] ^= 1;
      final alteredFile = await File(
        '${root.path}/altered.age',
      ).writeAsBytes(tampered);
      final truncatedBytes = Uint8List.sublistView(
        encrypted,
        0,
        encrypted.length - 1,
      );
      final truncatedFile = await File(
        '${root.path}/truncated.age',
      ).writeAsBytes(truncatedBytes);
      final malformed = await Directory(
        '${root.path}/unpacked test fixtures',
      ).create();
      final db = await File(
        '${source.path}/host.sqlite',
      ).copy('${malformed.path}/host.sqlite');
      final protected = await File(
        '${source.path}/host.sqlite.kek',
      ).copy('${db.path}.kek');
      await File(
        '${malformed.path}/extra',
      ).writeAsString('unexpected fixture member');
      final extraFile = await _encryptFixture(
        age,
        tar,
        recipient,
        malformed,
        File('${root.path}/extra.age'),
        ['host.sqlite', 'host.sqlite.kek', 'extra'],
      );
      // A valid DPAPI file from the same user is not enough: it must unwrap
      // this database's primary DEK, not the independent fixture's key.
      final unrelated = await DpapiKeyProvider(
        path: '${root.path}/unrelated.kek',
      ).loadKek();
      unrelated.fillRange(0, unrelated.length, 0);
      await File('${root.path}/unrelated.kek').copy(protected.path);
      final transplantFile = await _encryptFixture(
        age,
        tar,
        recipient,
        malformed,
        File('${root.path}/transplant.age'),
        ['host.sqlite', 'host.sqlite.kek'],
      );
      final cases = [
        (archive, digest, wrongIdentity, 'age_decrypt_failed'),
        (alteredFile, digest, identity, 'digest_mismatch'),
        (
          alteredFile,
          sha256.convert(tampered).toString(),
          identity,
          'age_decrypt_failed',
        ),
        (
          truncatedFile,
          sha256.convert(truncatedBytes).toString(),
          identity,
          'age_decrypt_failed',
        ),
        (extraFile, await _digest(extraFile), identity, 'archive_members'),
        (
          transplantFile,
          await _digest(transplantFile),
          identity,
          'key_unavailable_or_mismatch',
        ),
      ];
      final beforeRejections = await _entries(root);
      for (final (i, item) in cases.indexed) {
        final (input, expected, key, reason) = item;
        final target = Directory('${root.path}/rejected ${suffixes[i]}');
        final result = await _operator(
          _restoreArguments(
            age: age,
            archive: input,
            target: target,
            digest: expected,
          ),
          input: key,
        );
        _rejected(result, reason);
        expect(await target.exists(), isFalse);
        expect(await _entries(root), beforeRejections);
      }

      final target = Directory('${root.path}/fresh restore');
      final restore = await _operator(
        _restoreArguments(
          age: age,
          archive: archive,
          target: target,
          digest: digest,
        ),
        input: identity,
      );
      expect(restore.exitCode, 0, reason: restore.report);
      expect(restore.text, contains('integrity_check=ok'));
      expect(await _entries(target), ['host.sqlite', 'host.sqlite.kek']);
      expect(
        await _entries(root),
        [...beforeRejections, 'fresh restore']..sort(),
      );
      expect(await _pairDigests(target), original);

      // Windows PowerShell's native stdin pipeline can prefix UTF-8 with a
      // BOM. Accept one that frames this one native identity, not arbitrary
      // non-ASCII data or more than one identity.
      final bom = [0xef, 0xbb, 0xbf];
      final framed = Uint8List.fromList([...bom, ...identity]);
      final malformedFrame = Uint8List.fromList([...bom, ...framed]);
      try {
        final extraBomTarget = Directory('${root.path}/refused extra BOM');
        _rejected(
          await _operator(
            _restoreArguments(
              age: age,
              archive: archive,
              target: extraBomTarget,
              digest: digest,
            ),
            input: malformedFrame,
          ),
          'one_native_age_identity_required',
        );
        expect(await extraBomTarget.exists(), isFalse);
        final psTarget = Directory('${root.path}/fresh PowerShell restore');
        final psRestore = await _operator(
          _restoreArguments(
            age: age,
            archive: archive,
            target: psTarget,
            digest: digest,
          ),
          input: framed,
        );
        expect(psRestore.exitCode, 0, reason: psRestore.report);
        expect(psRestore.text, contains('integrity_check=ok'));
        expect(await _pairDigests(psTarget), original);
      } finally {
        framed.fillRange(0, framed.length, 0);
        malformedFrame.fillRange(0, malformedFrame.length, 0);
      }
      final restored = await buildHost(
        config: HostConfig(dataDir: target.path),
        clock: h.clock,
      );
      try {
        final db = restored.registry.services.get<Database>();
        expect(await db.integrityCheck(), 'ok');
        expect(
          (await db.query('SELECT count(*) AS n FROM messages')).single['n'],
          1,
        );
        final page = await restored.pipeline.handle(
          HostRequest(
            method: 'GET',
            path: Routes.sync.replaceFirst('{conversationId}', id),
            query: const {'afterSeq': '0'},
            headers: h.bearer(owner.token),
          ),
        );
        expect(page.status, 200);
        expect(asMap(page)['messages'], [stored.toPayload()]);
      } finally {
        expect(await restored.shutdown(), isEmpty);
      }
      expect(await _pairDigests(source), original);
      print(
        'Operator drill: backup/restore integrity_check=ok; both member digests preserved; authenticated message count=1; six invalid restores published nothing.',
      );
    },
    skip:
        !Platform.isWindows ||
            Platform.environment['JINGYU_RUN_AGE_OPERATOR_DRILL'] != '1'
        ? 'requires Windows and trusted opt-in age binaries'
        : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

List<String> _restoreArguments({
  required String age,
  required File archive,
  required Directory target,
  required String digest,
}) => [
  'restore',
  '--archive',
  archive.path,
  '--target',
  target.path,
  '--sha256',
  digest,
  '--age',
  age,
];

void _rejected(_Result result, String reason) {
  expect(result.exitCode, isNot(0), reason: result.report);
  expect(result.text, isEmpty);
  expect(result.error, contains('error: $reason'));
  expect(result.error, isNot(contains('AGE-SECRET-KEY-')));
}

Future<List<String>> _entries(Directory dir) async =>
    (await dir
          .list()
          .map(
            (entry) =>
                entry.uri.pathSegments.where((part) => part.isNotEmpty).last,
          )
          .toList())
      ..sort();

Future<List<String>> _pairDigests(Directory dir) async => [
  for (final name in ['host.sqlite', 'host.sqlite.kek'])
    await _digest(File('${dir.path}/$name')),
];

Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).single).toString();

Future<File> _encryptFixture(
  String age,
  String tar,
  String recipient,
  Directory source,
  File target,
  List<String> names,
) async {
  final archive = await _checked(tar, [
    '--format',
    'ustar',
    '-cf',
    '-',
    '--',
    ...names,
  ], directory: source.path);
  await target.writeAsBytes(
    await _checked(age, [
      '--encrypt',
      '--recipient',
      recipient,
    ], input: archive),
  );
  return target;
}

Future<_Result> _operator(List<String> arguments, {List<int>? input}) => _run(
  Platform.resolvedExecutable,
  ['tool/age_sqlite_recovery.dart', ...arguments],
  input: input,
);

Future<Uint8List> _checked(
  String executable,
  List<String> args, {
  List<int>? input,
  String? directory,
}) async {
  final result = await _run(
    executable,
    args,
    input: input,
    directory: directory,
  );
  // Never expose raw output of keygen, even on failure.
  expect(result.exitCode, 0, reason: 'fixture tool exited nonzero');
  return result.bytes;
}

Future<_Result> _run(
  String executable,
  List<String> args, {
  List<int>? input,
  String? directory,
}) async {
  final child = await Process.start(
    executable,
    args,
    workingDirectory: directory,
  );
  final output = child.stdout.fold(
    BytesBuilder(copy: false),
    (buffer, data) => buffer..add(data),
  );
  final stderr = utf8.decoder.bind(child.stderr).join();
  child.stdin.done.ignore();
  try {
    if (input != null) child.stdin.add(input);
    await child.stdin.close();
    final code = await child.exitCode.timeout(const Duration(seconds: 100));
    return _Result(code, (await output).takeBytes(), await stderr);
  } finally {
    child.kill();
  }
}

final class _Result {
  _Result(this.exitCode, this.bytes, this.error);
  final int exitCode;
  final Uint8List bytes;
  final String error;
  String get text => utf8.decode(bytes);
  String get report => 'exit=$exitCode; stderr=$error';
}
