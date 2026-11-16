/// [LifecycleModule] 装配测试：服务登记、依赖、后台清理调度生命周期。
library;

import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/lifecycle/cleanup.dart';
import 'package:jingyu_host/src/lifecycle/departure.dart';
import 'package:jingyu_host/src/lifecycle/export.dart';
import 'package:jingyu_host/src/lifecycle/import.dart';
import 'package:jingyu_host/src/lifecycle/lifecycle_migrations.dart';
import 'package:jingyu_host/src/lifecycle/lifecycle_module.dart';
import 'package:jingyu_host/src/lifecycle/quota_service.dart';
import 'package:jingyu_host/src/lifecycle/sqlite_cleanup_store.dart';
import 'package:jingyu_host/src/lifecycle/sqlite_departure_store.dart';
import 'package:jingyu_host/src/lifecycle/sqlite_quota_store.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

class _StubModule extends HostModule {
  _StubModule(this.name);

  @override
  final String name;
}

void main() {
  test('模块名与依赖声明正确', () {
    final module = LifecycleModule(clock: FakeClock(DateTime.utc(2026, 1, 1)));
    expect(module.name, 'lifecycle');
    expect(module.dependsOn, containsAll(<String>['storage', 'messages']));
  });

  test('boot 后登记 5 个服务，shutdown 取消后台调度', () async {
    final registry = Registry();
    registry.register(_StubModule('storage'));
    registry.register(_StubModule('messages'));
    registry.register(
      LifecycleModule(clock: FakeClock(DateTime.utc(2026, 1, 1))),
    );

    await registry.boot();
    final services = registry.services;
    expect(services.maybeGet<QuotaService>(), isNotNull);
    expect(services.maybeGet<CleanupService>(), isNotNull);
    expect(services.maybeGet<ExportService>(), isNotNull);
    expect(services.maybeGet<ImportService>(), isNotNull);
    expect(services.maybeGet<DepartureService>(), isNotNull);

    final errors = await registry.shutdown();
    expect(errors, isEmpty);
  });

  test('从容器取出的清理服务可端到端清理到期媒体', () async {
    final clock = FakeClock(DateTime.utc(2026, 1, 1));
    final cleanupStore = InMemoryCleanupStore();
    await cleanupStore.addAsset(
      MediaAsset(
        id: 'old',
        kind: MediaKind.video,
        createdAt: clock.now().subtract(const Duration(days: 91)),
        holderMessageIds: const {'u1': 'm1'},
      ),
    );
    final registry = Registry();
    registry.register(_StubModule('storage'));
    registry.register(_StubModule('messages'));
    registry.register(
      LifecycleModule(
        clock: clock,
        cleanup: CleanupService(store: cleanupStore, clock: clock),
      ),
    );
    await registry.boot();

    final cleanup = registry.services.get<CleanupService>();
    final report = (await cleanup.run()).value;
    expect(report.expiredCount, 1);
    expect((await cleanupStore.placeholdersFor('u1')).single.assetId, 'old');

    await registry.shutdown();
  });

  test('注入 SQLite 版 store 的 LifecycleModule 可端到端清理', () async {
    final dir = await Directory.systemTemp.createTemp('jingyu-lifecycle-mod-');
    final database = await SqliteDatabase.open(
      '${dir.path}/host.sqlite',
      migrations: [...allMigrations, ...lifecycleMigrations],
    );
    try {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final cleanupStore = SqliteCleanupStore(database: database, clock: clock);
      await cleanupStore.addAsset(
        MediaAsset(
          id: 'old',
          kind: MediaKind.video,
          createdAt: clock.now().subtract(const Duration(days: 91)),
          holderMessageIds: const {'u1': 'm1'},
        ),
      );
      final registry = Registry();
      registry.register(_StubModule('storage'));
      registry.register(_StubModule('messages'));
      registry.register(
        LifecycleModule(
          clock: clock,
          quota: QuotaService(store: SqliteQuotaStore(database: database)),
          cleanup: CleanupService(store: cleanupStore, clock: clock),
          departure: DepartureService(
            store: SqliteDepartureStore(database: database),
            clock: clock,
          ),
        ),
      );
      await registry.boot();

      final cleanup = registry.services.get<CleanupService>();
      final report = (await cleanup.run()).value;
      expect(report.expiredCount, 1);
      expect((await cleanupStore.placeholdersFor('u1')).single.assetId, 'old');

      await registry.shutdown();
    } finally {
      await database.close();
      await dir.delete(recursive: true);
    }
  });
}
