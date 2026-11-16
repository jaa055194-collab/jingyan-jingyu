/// M12 预留迁移的版本号段与内容检查（1200–1299）。
library;

import 'package:jingyu_host/src/lifecycle/lifecycle_migrations.dart';
import 'package:test/test.dart';

void main() {
  test('版本位于 1200–1299 且唯一', () {
    final versions = lifecycleMigrations.map((m) => m.version).toList();
    expect(versions, isNotEmpty);
    expect(versions.length, versions.toSet().length, reason: '版本号不可重复');
    for (final version in versions) {
      expect(version, inInclusiveRange(1200, 1299));
    }
  });

  test('每条迁移有名字与非空 SQL', () {
    for (final migration in lifecycleMigrations) {
      expect(migration.name.trim().isNotEmpty, isTrue);
      expect(migration.sql.toUpperCase(), contains('CREATE TABLE'));
    }
  });

  test('覆盖 quota/cleanup_log/export_jobs/deletion_receipts 四张表', () {
    final allSql = lifecycleMigrations
        .map((m) => m.sql)
        .join('\n')
        .toLowerCase();
    for (final table in <String>[
      'quota',
      'cleanup_log',
      'export_jobs',
      'deletion_receipts',
    ]) {
      expect(allSql, contains('create table $table'));
    }
  });
}
