// Applied allocation: M01 1; M02 100; M03 200; M04 300–302;
// M05 500–504; opt-in M06 memory/persona/life 600–602.
// The earlier per-module range sketch did not match M05's actual versions.
// Check all registered and opt-in migrations before allocating further versions;
// published migration numbers and SQL are append-only, never renumbered.
class Migration {
  const Migration(this.version, this.name, this.sql);
  final int version;
  final String name;
  final String sql;
}

const List<Migration> allMigrations = [
  Migration(1, 'storage foundation', '''
CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY,
  name TEXT NOT NULL
);
CREATE TABLE key_store (
  id TEXT PRIMARY KEY,
  wrapped_dek TEXT NOT NULL
);
CREATE TABLE audit_log (
  id INTEGER PRIMARY KEY,
  at TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  action TEXT NOT NULL,
  target_kind TEXT NOT NULL,
  target_id TEXT NOT NULL,
  meta TEXT NOT NULL
);
CREATE INDEX audit_log_target ON audit_log(target_kind, target_id, id);
'''),
];
