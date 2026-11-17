import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/lifecycle/cleanup.dart';
import 'package:jingyu_host/src/lifecycle/lifecycle_module.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  late FakeClock clock;
  late InMemoryCleanupStore store;
  late Pipeline pipeline;

  setUp(() async {
    clock = FakeClock(DateTime.utc(2026, 3, 1));
    store = InMemoryCleanupStore();
    Future<void> add(
      String id,
      MediaKind kind,
      int ageDays,
      Map<String, String> holders,
    ) => store.addAsset(
      MediaAsset(
        id: id,
        kind: kind,
        createdAt: clock.now().subtract(Duration(days: ageDays)),
        holderMessageIds: holders,
      ),
    );
    await add('v-old', MediaKind.video, 91, {'owner': 'm1', 'other': 'm2'});
    await add('v-remind', MediaKind.video, 85, {'owner': 'm1'});
    await add('a-young', MediaKind.voice, 10, {'owner': 'm1'});
    await add('v-other', MediaKind.video, 91, {'other': 'm2'});

    final module = LifecycleModule(
      clock: clock,
      cleanup: CleanupService(store: store, clock: clock),
    );
    final router = Router();
    module.mount(router);
    pipeline = Pipeline(
      router: router,
      authenticate: (request) async {
        final header = request.headers['authorization'] ?? '';
        if (header == 'Bearer owner') {
          return const Principal(accountId: 'owner', deviceId: 'd');
        }
        if (header == 'Bearer other') {
          return const Principal(accountId: 'other', deviceId: 'd');
        }
        return null;
      },
    );
  });

  Future<HostResponse> call(
    String token, {
    Map<String, String> query = const {},
  }) => pipeline.handle(
    HostRequest(
      method: 'GET',
      path: Routes.lifecycleCleanupPreview,
      query: query,
      headers: {'authorization': 'Bearer $token'},
    ),
  );

  test('owner-scoped cleanup preview counts only own holders', () async {
    final response = await call('owner');
    expect(response.status, 200);
    final json = response.json! as Map<String, Object?>;
    expect(json['dayKey'], '2026-03-01');
    expect(json['remindSoon'], {'video': 1, 'voice': 0});
    expect(json['expiring'], {'video': 1, 'voice': 0});
    expect(json['totalHeld'], {'video': 2, 'voice': 1});
    // No other-owner object count leaks into this owner's preview.
    expect((json['totalHeld']! as Map)['video'], 2);
  });

  test('other owner sees a different isolated preview', () async {
    final response = await call('other');
    expect(response.status, 200);
    final json = response.json! as Map<String, Object?>;
    expect(json['totalHeld'], {'video': 2, 'voice': 0});
    expect(json['expiring'], {'video': 2, 'voice': 0});
    expect(json['remindSoon'], {'video': 0, 'voice': 0});
  });

  test('unauthenticated request is rejected', () async {
    expect((await call('')).status, 401);
  });

  test('query/body are rejected and the store stays unchanged', () async {
    expect((await call('owner', query: {'x': '1'})).status, 400);
    final assets = await store.expirableAssets();
    expect(assets.every((asset) => asset.blobPresent), isTrue);
    expect(await store.placeholdersFor('owner'), isEmpty);
    expect(await store.remindedAt('v-remind'), isNull);
  });
}
