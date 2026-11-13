import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';

import '../audit/audit_log.dart';
import 'cipher.dart';
import 'database.dart';
import 'key_provider.dart';
import 'migrations.dart';
import 'sqlite_audit_log.dart';
import 'sqlite_database.dart';

/// Registers stable interfaces without I/O; persistence is opened during start.
final class StorageModule extends HostModule {
  StorageModule({
    required this.databasePath,
    KeyProvider? keyProvider,
    List<Migration> migrations = allMigrations,
  }) : migrations = List.unmodifiable(migrations),
       keyProvider =
           keyProvider ?? DpapiKeyProvider(path: '$databasePath.kek') {
    database = _DatabaseProxy(() => _database);
    cipher = _CipherProxy(() => _cipher);
    auditLog = SqliteAuditLog(database);
  }

  final String databasePath;
  final List<Migration> migrations;
  final KeyProvider keyProvider;
  late final Database database;
  late final ColumnCipher cipher;
  late final AuditLog auditLog;
  SqliteDatabase? _database;
  AesGcmColumnCipher? _cipher;
  Future<void> _lifecycle = Future<void>.value();

  @override
  String get name => 'storage';
  @override
  List<String> get dependsOn => const ['system'];

  @override
  Future<void> configure(HostServices services) async {
    services
      ..provide<Database>(database, owner: name)
      ..provide<ColumnCipher>(cipher, owner: name);
  }

  Future<void> _serialize(Future<void> Function() action) {
    final operation = _lifecycle.then((_) => action());
    _lifecycle = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }

  @override
  Future<void> start() => _serialize(() async {
    if (_database != null) return;
    SqliteDatabase? db;
    Uint8List? kek;
    Uint8List? dek;
    AesGcmColumnCipher? wrapping;
    try {
      db = await SqliteDatabase.open(databasePath, migrations: migrations);
      kek = await keyProvider.loadKek();
      if (kek.length != 32) throw StateError('KEK must be exactly 32 bytes');
      wrapping = AesGcmColumnCipher(kek);
      final keyWrapping = wrapping;
      dek = await db.transaction((tx) async {
        final existing = await tx.query(
          'SELECT wrapped_dek FROM key_store WHERE id = ?',
          ['primary'],
        );
        if (existing.isNotEmpty) {
          final sealed = existing.single['wrapped_dek'];
          if (sealed is! String) {
            throw StateError('Stored DEK envelope is invalid');
          }
          final result = keyWrapping.decrypt(
            sealed,
            aad: 'key_store:wrapped_dek:primary',
          );
          if (result.isErr) throw StateError('Stored DEK envelope is invalid');
          final decoded = base64Decode(result.value);
          if (decoded.length != 32) {
            decoded.fillRange(0, decoded.length, 0);
            throw StateError('Stored DEK has invalid length');
          }
          return decoded;
        }
        final random = Random.secure();
        final generated = Uint8List.fromList(
          List.generate(32, (_) => random.nextInt(256)),
        );
        try {
          final wrapped = keyWrapping.encrypt(
            base64Encode(generated),
            aad: 'key_store:wrapped_dek:primary',
          );
          await tx.execute(
            'INSERT INTO key_store (id, wrapped_dek) VALUES (?, ?)',
            ['primary', wrapped],
          );
          return generated;
        } catch (_) {
          generated.fillRange(0, generated.length, 0);
          rethrow;
        }
      });
      final readyCipher = AesGcmColumnCipher(dek!);
      _cipher = readyCipher;
      _database = db;
    } catch (_) {
      wrapping?.dispose();
      await db?.close();
      rethrow;
    } finally {
      wrapping?.dispose();
      kek?.fillRange(0, kek.length, 0);
      dek?.fillRange(0, dek.length, 0);
    }
  });

  @override
  Future<void> stop() => _serialize(() async {
    final db = _database;
    _database = null;
    _cipher?.dispose();
    _cipher = null;
    await db?.close();
  });
}

final class _DatabaseProxy implements Database {
  _DatabaseProxy(this._resolve);
  final Database? Function() _resolve;
  Database get _database =>
      _resolve() ?? (throw StateError('Storage is not started'));

  @override
  Future<T> transaction<T>(Future<T> Function(Tx tx) body) async =>
      _database.transaction(body);
  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) async => _database.query(sql, args);
  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) async =>
      _database.execute(sql, args);
  @override
  Future<int> schemaVersion() async => _database.schemaVersion();
  @override
  Future<String> integrityCheck() async => _database.integrityCheck();
}

final class _CipherProxy implements ColumnCipher {
  _CipherProxy(this._resolve);
  final ColumnCipher? Function() _resolve;
  ColumnCipher get _cipher =>
      _resolve() ?? (throw StateError('Storage is not started'));

  @override
  String encrypt(String plaintext, {required String aad}) =>
      _cipher.encrypt(plaintext, aad: aad);
  @override
  Result<String> decrypt(String sealed, {required String aad}) =>
      _cipher.decrypt(sealed, aad: aad);
}
