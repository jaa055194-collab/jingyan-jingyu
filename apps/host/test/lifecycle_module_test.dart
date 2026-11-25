/// [LifecycleModule] 装配测试：服务登记、依赖、后台清理调度生命周期。
library;

import 'dart:async';
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
  _StubModule(this.name, {this.onStop});

  @override
  final String name;
  final void Function()? onStop;

  @override
  Future<void> stop() async => onStop?.call();
}

class _BlockingCleanupStore extends InMemoryCleanupStore {
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<List<MediaAsset>> expirableAssets() async {
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return super.expirableAssets();
  }
}

class _ManualTimer implements Timer {
  _ManualTimer(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _tick++;
    _callback();
  }
}

Future<void> _withManualTimers(Future<void> Function(List<_ManualTimer>) body) {
  final timers = <_ManualTimer>[];
  return runZoned(
    () => body(timers),
    zoneSpecification: ZoneSpecification(
      createTimer: (_, parent, zone, delay, callback) {
        // A zero-delay event lets queued microtasks drain without a real wait.
        if (delay == Duration.zero) {
          return parent.createTimer(zone, delay, callback);
        }
        final timer = _ManualTimer(delay, callback);
        timers.add(timer);
        return timer;
      },
    ),
  );
}

const _untilCleanup = Duration(seconds: 1);

FakeClock _beforeCleanup() => FakeClock(DateTime.utc(2026, 1, 1, 3, 29, 59));

Registry _cleanupRegistry({
  required FakeClock clock,
  required CleanupStore store,
  required void Function() onStorageStop,
}) => Registry()
  ..register(_StubModule('storage', onStop: onStorageStop))
  ..register(_StubModule('messages'))
  ..register(
    LifecycleModule(
      clock: clock,
      cleanup: CleanupService(store: store, clock: clock),
    ),
  );

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

  group('scheduled cleanup', () {
    for (final fails in [false, true]) {
      test(
        fails
            ? 'shutdown waits for a running cleanup that fails'
            : 'shutdown waits before stopping storage during cleanup',
        () => _withManualTimers((timers) async {
          final clock = _beforeCleanup();
          final store = _BlockingCleanupStore();
          final storageStopped = Completer<bool>();
          final registry = _cleanupRegistry(
            clock: clock,
            store: store,
            onStorageStop: () =>
                storageStopped.complete(store.ranOn('2026-01-01')),
          );
          await registry.boot();

          Future<List<Object>>? shutdown;
          try {
            expect(timers.single.delay, _untilCleanup);
            clock.advance(_untilCleanup);
            timers.single.fire();
            await Future<void>.delayed(Duration.zero);
            expect(store.entered.isCompleted, isTrue);

            shutdown = registry.shutdown();
            await Future<void>.delayed(Duration.zero);
            expect(
              storageStopped.isCompleted,
              isFalse,
              reason: 'storage must stay open while cleanup is blocked',
            );
          } finally {
            if (fails && store.entered.isCompleted) {
              store.release.completeError(
                StateError('synthetic store failure'),
              );
            } else {
              store.release.complete();
            }
            final errors = await (shutdown ?? registry.shutdown());
            expect(errors, isEmpty);
          }

          expect(storageStopped.isCompleted, isTrue);
          expect(await storageStopped.future, !fails);
          expect(timers, hasLength(1));
        }),
      );
    }

    test('shutdown cancels a pending cleanup without starting it', () {
      return _withManualTimers((timers) async {
        final clock = _beforeCleanup();
        final store = _BlockingCleanupStore();
        var storageStopped = false;
        final registry = _cleanupRegistry(
          clock: clock,
          store: store,
          onStorageStop: () => storageStopped = true,
        );
        await registry.boot();
        store.release.complete();
        expect(await registry.shutdown(), isEmpty);
        expect(storageStopped, isTrue);
        expect(timers.single.isActive, isFalse);

        clock.advance(_untilCleanup);
        timers.single.fire();
        await Future<void>.delayed(Duration.zero);
        expect(store.entered.isCompleted, isFalse);
      });
    });

    test('failure while running still schedules cleanup the next day', () {
      return _withManualTimers((timers) async {
        final clock = _beforeCleanup();
        final store = _BlockingCleanupStore();
        final registry = _cleanupRegistry(
          clock: clock,
          store: store,
          onStorageStop: () {},
        );
        await registry.boot();

        try {
          clock.advance(_untilCleanup);
          timers.single.fire();
          await Future<void>.delayed(Duration.zero);
          expect(store.entered.isCompleted, isTrue);
          store.release.completeError(StateError('synthetic store failure'));
          await Future<void>.delayed(Duration.zero);
          expect(timers, hasLength(2));
          expect(timers.last.delay, const Duration(days: 1));

          clock.advance(const Duration(days: 1));
          timers.last.fire();
          await Future<void>.delayed(Duration.zero);
          expect(await store.ranOn('2026-01-02'), isTrue);
        } finally {
          if (!store.release.isCompleted) store.release.complete();
          final errors = await registry.shutdown();
          expect(errors, isEmpty);
        }
      });
    });
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
