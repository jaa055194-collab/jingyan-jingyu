import 'dart:async';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'database.dart';
import 'migrations.dart';

/// Owns one serialized connection. Use the supplied Tx inside callbacks;
/// calling the outer Database there is rejected rather than deadlocking.
class SqliteDatabase implements Database {
  SqliteDatabase._(this._db);
  final sqlite.Database _db;
  final Object _transactionZone = Object();
  Future<void> _tail = Future.value();
  bool _closing = false;
  Future<void>? _close;

  static Future<SqliteDatabase> open(
    String path, {
    List<Migration> migrations = allMigrations,
  }) async {
    final ordered = [...migrations]
      ..sort((a, b) => a.version.compareTo(b.version));
    final seen = <int>{};
    for (final migration in ordered) {
      if (migration.version < 1 || !seen.add(migration.version)) {
        throw ArgumentError('Migration versions must be positive and unique');
      }
    }
    if (path != ':memory:') await File(path).parent.create(recursive: true);
    final raw = sqlite.sqlite3.open(path);
    try {
      raw.execute('PRAGMA busy_timeout=5000');
      raw.execute('PRAGMA journal_mode=WAL');
      raw.execute('PRAGMA foreign_keys=ON');
      for (final migration in ordered) {
        raw.execute('BEGIN IMMEDIATE');
        try {
          final exists = raw.select(
            "SELECT 1 FROM sqlite_master WHERE type = ? AND name = ?",
            ['table', 'schema_migrations'],
          ).isNotEmpty;
          final done =
              exists &&
              raw.select('SELECT 1 FROM schema_migrations WHERE version = ?', [
                migration.version,
              ]).isNotEmpty;
          if (!done) {
            raw.execute(migration.sql);
            raw.execute(
              'INSERT INTO schema_migrations (version, name) VALUES (?, ?)',
              [migration.version, migration.name],
            );
          }
          raw.execute('COMMIT');
        } catch (_) {
          raw.execute('ROLLBACK');
          rethrow;
        }
      }
      return SqliteDatabase._(raw);
    } catch (_) {
      raw.dispose();
      rethrow;
    }
  }

  Future<T> _serial<T>(FutureOr<T> Function() body) {
    if (Zone.current[_transactionZone] == true) {
      return Future.error(
        StateError('Use the supplied Tx inside a transaction'),
      );
    }
    if (_closing) return Future.error(StateError('Database is closed'));
    final result = _tail.then((_) => body());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> close() {
    if (Zone.current[_transactionZone] == true) {
      return Future.error(StateError('Cannot close inside a transaction'));
    }
    if (_close != null) return _close!;
    _closing = true;
    return _close = _tail.then((_) => _db.dispose());
  }

  @override
  Future<T> transaction<T>(Future<T> Function(Tx tx) body) => _serial(() async {
    _db.execute('BEGIN IMMEDIATE');
    final tx = _SqliteTx(_db);
    try {
      final value = await runZoned(
        () => body(tx),
        zoneValues: {_transactionZone: true},
      );
      tx.active = false;
      _db.execute('COMMIT');
      return value;
    } catch (_) {
      tx.active = false;
      _db.execute('ROLLBACK');
      rethrow;
    }
  });

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) => _serial(() => _query(_db, sql, args));
  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) =>
      _serial(() => _execute(_db, sql, args));
  @override
  Future<int> schemaVersion() async =>
      (await query(
            'SELECT COALESCE(MAX(version), 0) AS version FROM schema_migrations',
          )).single['version']
          as int;
  @override
  Future<String> integrityCheck() async => (await query(
    'PRAGMA integrity_check',
  )).map((r) => r.values.single).join('\n');
}

List<Map<String, Object?>> _query(
  sqlite.Database db,
  String sql,
  List<Object?> args,
) {
  final statement = db.prepare(sql);
  try {
    return [
      for (final row in statement.select(args)) Map<String, Object?>.from(row),
    ];
  } finally {
    statement.dispose();
  }
}

int _execute(sqlite.Database db, String sql, List<Object?> args) {
  final statement = db.prepare(sql);
  try {
    statement.execute(args);
    return db.updatedRows;
  } finally {
    statement.dispose();
  }
}

class _SqliteTx implements Tx {
  _SqliteTx(this.db);
  final sqlite.Database db;
  bool active = true;
  void _check() {
    if (!active) throw StateError('Transaction is complete');
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    _check();
    return _query(db, sql, args);
  }

  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) async {
    _check();
    return _execute(db, sql, args);
  }
}
