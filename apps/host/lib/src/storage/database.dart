/// SQL values are always passed as bound [args], never interpolated.
abstract class Database {
  Future<T> transaction<T>(Future<T> Function(Tx tx) body);
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]);
  Future<int> execute(String sql, [List<Object?> args = const []]);
  Future<int> schemaVersion();
  Future<String> integrityCheck();
}

abstract class Tx {
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]);
  Future<int> execute(String sql, [List<Object?> args = const []]);
}
