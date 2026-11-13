// Version allocation: M01 1–99; M02 100–199; M03 200–299;
// M04 300–399; M05 400–499; M06 500–599; M07 600–699;
// M08 700–799; M09 800–899; M10 900–999; M11 1000–1099;
// M12 1100–1199; M13 1200–1299. Published migrations are append-only.
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
