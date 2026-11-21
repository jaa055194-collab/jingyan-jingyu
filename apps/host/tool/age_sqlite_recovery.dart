/// Manual Windows-only, stopped-host operator commands (no HTTP surface).
/// See docs/testing/age-sqlite-operator.md before running on a closed host.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/key_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'age_recovery_tar.dart';
import 'age_recovery_windows.dart';

const _usage = '''Windows (same user and machine; stop the host first):
  dart run tool/age_sqlite_recovery.dart backup --host-stopped
      --data-dir <absolute directory> --output <fresh .age path>
      --recipient <age1 public key> --age <trusted age.exe> [--tar <trusted tar.exe>]
  dart run tool/age_sqlite_recovery.dart restore
      --archive <absolute .age path> --sha256 <trusted ciphertext digest>
      --target <nonexistent directory> --age <trusted age.exe>
Restore reads one native age X25519 identity via redirected stdin only.''';
const _ageHeader = 'age-encryption.org/v1\n';
final _publicKey = RegExp(r'^age1[0-9a-z]{58}$');
final _secretKey = RegExp(r'^AGE-SECRET-KEY-1[0-9A-Z]{58}$');
final _digest = RegExp(r'^[a-fA-F0-9]{64}$');

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--help') {
    stdout.writeln(_usage);
    return;
  }
  try {
    if (!Platform.isWindows) throw const RecoveryFailure('windows_required');
    final options = _parse(arguments);
    final digest = options.backup
        ? await _backup(options.values)
        : await _restore(options.values);
    stdout.writeln('integrity_check=ok');
    stdout.writeln('sha256=$digest');
  } on RecoveryFailure catch (error) {
    // Do not echo arguments, executable stderr, sqlite errors, archive names,
    // or any identity bytes, even when a child returns a failing diagnostic.
    stderr.writeln('error: ${error.code}');
    exitCode = 1;
  } catch (_) {
    stderr.writeln('error: local_io_or_validation_failed');
    exitCode = 1;
  }
}

({bool backup, Map<String, String> values}) _parse(List<String> arguments) {
  if (arguments.isEmpty ||
      (arguments.first != 'backup' && arguments.first != 'restore')) {
    throw const RecoveryFailure('usage_see_help');
  }
  final backup = arguments.first == 'backup';
  final allowed = backup
      ? const {'--data-dir', '--output', '--recipient', '--age', '--tar'}
      : const {'--archive', '--target', '--sha256', '--age'};
  final required = backup ? allowed.difference({'--tar'}) : allowed;
  final values = <String, String>{};
  var stopped = false;
  for (var i = 1; i < arguments.length; i++) {
    final option = arguments[i];
    if (backup && option == '--host-stopped' && !stopped) {
      stopped = true;
      continue;
    }
    if (!allowed.contains(option) ||
        values.containsKey(option) ||
        i + 1 >= arguments.length ||
        arguments[i + 1].startsWith('--')) {
      throw const RecoveryFailure('usage_see_help');
    }
    values[option] = arguments[++i];
  }
  if (backup && !stopped) throw const RecoveryFailure('host_stopped_required');
  if (!values.keys.toSet().containsAll(required)) {
    throw const RecoveryFailure('usage_see_help');
  }
  return (backup: backup, values: values);
}

Future<String> _backup(Map<String, String> options) async {
  final source = localAbsolutePath(options['--data-dir']!);
  requireDirectory(source);
  final destination = localAbsolutePath(options['--output']!);
  if (pathPresent(destination)) throw const RecoveryFailure('output_exists');
  if (!destination.toLowerCase().endsWith('.age')) {
    throw const RecoveryFailure('age_output_extension_required');
  }
  final recipient = options['--recipient']!;
  if (!_publicKey.hasMatch(recipient)) {
    throw const RecoveryFailure('native_age_recipient_required');
  }
  final databasePath = '$source\\$databaseMember';
  final keyPath = '$source\\$protectedKeyMember';
  _rejectSidecars(databasePath);
  final db = GuardedInput(
    databasePath,
    unavailable: 'source_open_or_unavailable',
  );
  try {
    final kek = GuardedInput(
      keyPath,
      unavailable: 'source_open_or_unavailable',
    );
    try {
      _rejectSidecars(databasePath);
      final age = _tool(options['--age']!);
      final tar = _tool(
        options['--tar'] ??
            '${Platform.environment['SystemRoot']}\\System32\\tar.exe',
      );
      final snapshot = db.read(databaseLimit);
      try {
        final protectedKey = kek.read(keyLimit);
        try {
          final scratch = localAbsolutePath(Directory.systemTemp.absolute.path);
          requireDirectory(scratch);
          return await _inStage(Directory(scratch), (stage) async {
            final pair = SnapshotPair(snapshot, protectedKey);
            await _writePair(stage, pair);
            await _checkPair(stage);
            final archive = await _checked(
              tar,
              [
                '--format',
                'ustar',
                '-cf',
                '-',
                '--',
                databaseMember,
                protectedKeyMember,
              ],
              error: 'tar_create_failed',
              limit: tarLimit,
              workingDirectory: stage.path,
            );
            try {
              final archived = decodeSnapshotTar(archive);
              if (sha256.convert(archived.database) !=
                      sha256.convert(snapshot) ||
                  sha256.convert(archived.protectedKey) !=
                      sha256.convert(protectedKey)) {
                throw const RecoveryFailure('archive_member_changed');
              }
              final encrypted = await _checked(
                age,
                ['--encrypt', '--recipient', recipient],
                error: 'age_encrypt_failed',
                limit: ageLimit,
                input: archive,
              );
              if (!_hasPrefix(encrypted, _ageHeader)) {
                throw const RecoveryFailure('age_encrypt_failed');
              }
              final digest = sha256.convert(encrypted).toString();
              // Remove the staged at-rest pair before publishing ciphertext.
              await _removeStage(stage);
              await _inStage(File(destination).parent, (outputStage) async {
                final temporary = File('${outputStage.path}\\archive.age');
                await temporary.writeAsBytes(encrypted, flush: true);
                if ((await sha256
                            .bind(temporary.openRead(0, ageLimit + 1))
                            .single)
                        .toString() !=
                    digest) {
                  throw const RecoveryFailure('ciphertext_write_mismatch');
                }
                _rejectSidecars(databasePath);
                publishNoReplace(temporary.path, destination);
              });
              return digest;
            } finally {
              archive.fillRange(0, archive.length, 0);
            }
          });
        } finally {
          protectedKey.fillRange(0, protectedKey.length, 0);
        }
      } finally {
        snapshot.fillRange(0, snapshot.length, 0);
      }
    } finally {
      kek.close();
    }
  } finally {
    db.close();
  }
}

Future<String> _restore(Map<String, String> options) async {
  final destination = localAbsolutePath(options['--target']!);
  if (pathPresent(destination)) throw const RecoveryFailure('target_exists');
  final expected = options['--sha256']!;
  if (!_digest.hasMatch(expected)) {
    throw const RecoveryFailure('sha256_required');
  }
  final source = localAbsolutePath(options['--archive']!);
  final age = _tool(options['--age']!);
  final file = GuardedInput(
    source,
    unavailable: 'archive_open_or_unavailable',
    shareRead: true,
  );
  try {
    // Keep the read/no-write/no-delete sharing handle through decryption so
    // that age opens the same bytes whose digest was verified here.
    final encrypted = file.read(ageLimit);
    final actual = sha256.convert(encrypted).toString();
    if (actual != expected.toLowerCase()) {
      throw const RecoveryFailure('digest_mismatch');
    }
    if (!_hasPrefix(encrypted, _ageHeader)) {
      throw const RecoveryFailure('age_decrypt_failed');
    }
    final identity = await _readIdentity();
    final Uint8List archive;
    try {
      archive = await _checked(
        age,
        ['--decrypt', '--identity', '-', source],
        error: 'age_decrypt_failed',
        limit: tarLimit,
        input: identity,
      );
    } finally {
      identity.fillRange(0, identity.length, 0);
    }
    try {
      final restored = decodeSnapshotTar(archive);
      await _inStage(Directory(destination).parent, (stage) async {
        await _writePair(stage, restored);
        await _checkPair(stage);
        publishNoReplace(stage.path, destination);
      });
      return actual;
    } finally {
      archive.fillRange(0, archive.length, 0);
    }
  } finally {
    file.close();
  }
}

String _tool(String input) {
  final path = localAbsolutePath(input);
  if (!path.toLowerCase().endsWith('.exe')) {
    throw const RecoveryFailure('trusted_executable_required');
  }
  requireOrdinaryFile(path, 'trusted_executable_required');
  return path;
}

void _rejectSidecars(String base) {
  for (final suffix in ['-wal', '-shm', '-journal']) {
    if (pathPresent('$base$suffix')) {
      throw const RecoveryFailure('sqlite_sidecar_present');
    }
  }
}

Future<T> _inStage<T>(
  Directory parent,
  Future<T> Function(Directory) action,
) async {
  final stage = await parent.createTemp('.jingyu-age-');
  try {
    return await action(stage);
  } finally {
    await _removeStage(stage);
  }
}

Future<void> _removeStage(Directory stage) async {
  // Only delete this unique, tool-owned temporary directory, not the source,
  // archive, destination, or any existing directory supplied by an operator.
  if (!pathPresent(stage.path)) return;
  requireDirectory(stage.path);
  for (final leaf in [
    databaseMember,
    protectedKeyMember,
    '$protectedKeyMember.lock',
    'archive.age',
  ]) {
    final path = '${stage.path}\\$leaf';
    if (!pathPresent(path)) continue;
    requireOrdinaryFile(path, 'unexpected_stage_contents');
    await File(path).delete();
  }
  // Intentionally not recursive: do not touch unrecognized stage entries.
  await stage.delete();
}

Future<void> _writePair(Directory directory, SnapshotPair pair) async {
  if (!_hasPrefix(pair.database, 'SQLite format 3\u0000')) {
    throw const RecoveryFailure('database_integrity_failed');
  }
  await File(
    '${directory.path}\\$databaseMember',
  ).writeAsBytes(pair.database, flush: true);
  await File(
    '${directory.path}\\$protectedKeyMember',
  ).writeAsBytes(pair.protectedKey, flush: true);
}

Future<void> _checkPair(Directory stage) async {
  final databasePath = '${stage.path}\\$databaseMember';
  final keyPath = '${stage.path}\\$protectedKeyMember';
  // Immutable read-only URI is safe on the private, fully materialized stage
  // and guarantees SQLite won't create WAL/SHM or alter the published files.
  final uri = Uri.file(
    databasePath,
    windows: true,
  ).replace(queryParameters: {'immutable': '1'});
  final String wrapped;
  try {
    final db = sqlite.sqlite3.open(
      uri.toString(),
      mode: sqlite.OpenMode.readOnly,
      uri: true,
    );
    try {
      db.execute('PRAGMA trusted_schema=OFF');
      final check = db.select('PRAGMA integrity_check(1)');
      if (check.length != 1 || check.single.values.single != 'ok') {
        throw const RecoveryFailure('database_integrity_failed');
      }
      if (db
              .select(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name IN ('key_store','schema_migrations')",
              )
              .length !=
          2) {
        throw const RecoveryFailure('not_host_database');
      }
      final rows = db.select(
        'SELECT wrapped_dek FROM key_store WHERE id = ? LIMIT 2',
        ['primary'],
      );
      final value = rows.length == 1 ? rows.single['wrapped_dek'] : null;
      if (value is! String || value.length > 160) {
        throw const RecoveryFailure('key_unavailable_or_mismatch');
      }
      wrapped = value;
    } finally {
      db.dispose();
    }
  } on sqlite.SqliteException {
    throw const RecoveryFailure('database_integrity_failed');
  }
  Uint8List? kek;
  Uint8List? decoded;
  AesGcmColumnCipher? cipher;
  try {
    kek = await DpapiKeyProvider(path: keyPath).loadKek();
    cipher = AesGcmColumnCipher(kek);
    final opened = cipher.decrypt(
      wrapped,
      aad: 'key_store:wrapped_dek:primary',
    );
    if (opened.isErr) throw const FormatException();
    decoded = base64Decode(opened.value);
    if (decoded.length != 32 || base64Encode(decoded) != opened.value) {
      throw const FormatException();
    }
  } catch (_) {
    throw const RecoveryFailure('key_unavailable_or_mismatch');
  } finally {
    cipher?.dispose();
    kek?.fillRange(0, kek.length, 0);
    decoded?.fillRange(0, decoded.length, 0);
  }
  // The existing DPAPI provider leaves a lock claim file in the checked copy.
  final claim = File('$keyPath.lock');
  if (await claim.exists()) await claim.delete();
  final inventory = await stage.list(followLinks: false).toList();
  if (inventory.length != 2) {
    throw const RecoveryFailure('unexpected_stage_contents');
  }
}

bool _hasPrefix(Uint8List bytes, String prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix.codeUnitAt(i)) return false;
  }
  return true;
}

Future<Uint8List> _readIdentity() async {
  if (stdin.hasTerminal) {
    throw const RecoveryFailure('redirect_age_identity_to_stdin');
  }
  final raw = await _collect(
    stdin,
    8 * 1024,
    'one_native_age_identity_required',
  );
  // Windows PowerShell 5.1 may prefix redirected native stdin with a
  // UTF-8 BOM. Strip exactly one leading marker; the identity remains ASCII.
  final identity =
      raw.length >= 3 && raw[0] == 0xef && raw[1] == 0xbb && raw[2] == 0xbf
      ? Uint8List.sublistView(raw, 3)
      : raw;
  try {
    final lines = const LineSplitter().convert(ascii.decode(identity));
    final identities = lines
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .toList();
    if (identities.length != 1 || !_secretKey.hasMatch(identities.single)) {
      throw const RecoveryFailure('one_native_age_identity_required');
    }
    return identity;
  } catch (_) {
    raw.fillRange(0, raw.length, 0);
    throw const RecoveryFailure('one_native_age_identity_required');
  }
}

Future<Uint8List> _collect(
  Stream<List<int>> input,
  int limit,
  String error,
) async {
  final chunks = BytesBuilder(copy: false);
  try {
    await for (final chunk in input) {
      if (chunk.length > limit - chunks.length) throw RecoveryFailure(error);
      chunks.add(chunk);
    }
    return chunks.takeBytes();
  } catch (_) {
    final partial = chunks.takeBytes();
    partial.fillRange(0, partial.length, 0);
    rethrow;
  }
}

Future<Uint8List> _checked(
  String executable,
  List<String> arguments, {
  required String error,
  required int limit,
  String? workingDirectory,
  Uint8List? input,
}) async {
  final child = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: {'SystemRoot': ?Platform.environment['SystemRoot']},
    includeParentEnvironment: false,
  );
  child.stdin.done.ignore();
  Uint8List? output;
  var accepted = false;
  try {
    final code = child.exitCode;
    await Future.wait<void>([
      _collect(child.stdout, limit, error).then((data) => output = data),
      child.stderr.drain<void>(),
      () async {
        if (input != null) child.stdin.add(input);
        await child.stdin.close();
      }(),
      code.then((_) {}),
    ], eagerError: true).timeout(const Duration(seconds: 90));
    if (await code != 0 || output == null || output!.isEmpty) {
      throw RecoveryFailure(error);
    }
    accepted = true;
    return output!;
  } catch (_) {
    throw RecoveryFailure(error);
  } finally {
    if (!accepted) {
      child.kill();
      try {
        await child.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        // The failed process cannot publish output; only the command can.
      }
      output?.fillRange(0, output!.length, 0);
    }
  }
}
