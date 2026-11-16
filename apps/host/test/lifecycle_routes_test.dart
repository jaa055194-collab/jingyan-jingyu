/// M12 lifecycle HTTP 路由契约测试（认证 / owner 隔离 / 404 / 上传预检 / 导出导入 / 离开）。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/lifecycle/departure.dart';
import 'package:jingyu_host/src/lifecycle/export.dart';
import 'package:jingyu_host/src/lifecycle/import.dart';
import 'package:jingyu_host/src/lifecycle/lifecycle_module.dart';
import 'package:jingyu_host/src/lifecycle/quota_service.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _Stub extends HostModule {
  _Stub(this.name);
  @override
  final String name;
}

Principal? _principalFor(HostRequest request) {
  switch (request.headers['authorization']) {
    case 'Bearer token-a':
      return const Principal(accountId: 'a', deviceId: 'da');
    case 'Bearer token-b':
      return const Principal(accountId: 'b', deviceId: 'db');
    default:
      return null;
  }
}

void main() {
  final clock = FakeClock(DateTime.utc(2026, 8, 1, 9));
  late Registry registry;
  late Pipeline pipeline;
  late InMemoryQuotaStore quotaStore;
  late InMemoryImportSink importSink;

  setUp(() async {
    quotaStore = InMemoryQuotaStore();
    final exportSource = InMemoryExportSource()
      ..setPersona({'name': '小鲸', 'apiKey': 'sk-SECRET'})
      ..addConversation(
        ExportConversation(
          conversationId: 'c1',
          messages: [
            ExportMessage(
              messageId: 'm1',
              conversationId: 'c1',
              seq: 1,
              senderId: 'a',
              kind: 'text',
              body: const {'text': 'hi'},
              sentAt: DateTime.utc(2026, 1, 1),
            ),
          ],
        ),
      )
      ..addMemory({
        'memoryId': 'mem1',
        'tier': 'T0',
        'text': '喜欢咖啡',
      });
    importSink = InMemoryImportSink();
    final departureStore = InMemoryDepartureStore()
      ..seed('a', {'conversations': 2, 'messages': 10}, moments: 1);

    registry = Registry();
    registry.register(_Stub('storage'));
    registry.register(_Stub('messages'));
    registry.register(
      LifecycleModule(
        clock: clock,
        quota: QuotaService(store: quotaStore, quotaBytes: 1000),
        exportService: ExportService(source: exportSource, clock: clock),
        importService: ImportService(),
        departure: DepartureService(store: departureStore, clock: clock),
        importSink: importSink,
      ),
    );
    await registry.boot();
    pipeline = Pipeline(
      router: registry.router,
      authenticate: (request) async => _principalFor(request),
    );
  });

  tearDown(() async {
    await registry.shutdown();
  });

  Map<String, String> bearer(String token) => {
    'authorization': 'Bearer $token',
  };

  Future<HostResponse> get(String path, {String? token}) => pipeline.handle(
    HostRequest(
      method: 'GET',
      path: path,
      headers: token == null ? const {} : bearer(token),
    ),
  );

  Future<HostResponse> post(String path, {String? token, Object? body}) =>
      pipeline.handle(
        HostRequest(
          method: 'POST',
          path: path,
          headers: token == null ? const {} : bearer(token),
          body: body,
        ),
      );

  group('认证：缺 bearer 一律 401', () {
    final cases = <(String, String, Object?)>[
      ('GET', Routes.lifecycleQuota, null),
      ('POST', Routes.lifecycleUploadPreview, {
        'kind': 'file',
        'uploadBytes': 10,
      }),
      ('POST', Routes.lifecycleUploadCommit, {'permitId': 'x'}),
      ('POST', Routes.lifecycleExport, {}),
      ('POST', Routes.lifecycleImport, {'mode': 'personaOnly', 'files': {}}),
      ('GET', Routes.lifecycleDepartureSurvey, null),
      ('POST', Routes.lifecycleDepartureReceipt, {'aiDisposition': 'retain'}),
    ];
    for (final c in cases) {
      test('匿名 ${c.$2} → 401', () async {
        final res = c.$1 == 'GET'
            ? await get(c.$2)
            : await post(c.$2, body: c.$3);
        expect(res.status, 401, reason: c.$2);
      });
    }
  });

  group('quota 状态', () {
    test('返回当前账号用量与磁盘，owner 隔离', () async {
      await quotaStore.addUsage('a', 800);
      final a = await get(Routes.lifecycleQuota, token: 'token-a');
      expect(a.status, 200);
      final aj = a.json as Map;
      expect(aj['usedBytes'], 800);
      expect(aj['quotaBytes'], 1000);
      final b = await get(Routes.lifecycleQuota, token: 'token-b');
      expect((b.json as Map)['usedBytes'], 0);
    });
  });

  group('上传预检 / 记用量', () {
    test('预检返回 permit，记用量累加已用字节', () async {
      final preview = await post(
        Routes.lifecycleUploadPreview,
        token: 'token-a',
        body: {'kind': 'file', 'uploadBytes': 300},
      );
      expect(preview.status, 200);
      final permitId = (preview.json as Map)['permitId'] as String;
      expect(permitId, isNotEmpty);

      final commit = await post(
        Routes.lifecycleUploadCommit,
        token: 'token-a',
        body: {'permitId': permitId},
      );
      expect(commit.status, 200);
      expect((commit.json as Map)['countedBytes'], 300);

      final quota = await get(Routes.lifecycleQuota, token: 'token-a');
      expect((quota.json as Map)['usedBytes'], 300);
    });

    test('单账号第 4 个并发预检被限流 429', () async {
      for (var i = 0; i < 3; i++) {
        final ok = await post(
          Routes.lifecycleUploadPreview,
          token: 'token-a',
          body: {'kind': 'file', 'uploadBytes': 1},
        );
        expect(ok.status, 200);
      }
      final fourth = await post(
        Routes.lifecycleUploadPreview,
        token: 'token-a',
        body: {'kind': 'file', 'uploadBytes': 1},
      );
      expect(fourth.status, 429);
    });

    test('未知 permit → 404；跨账号 permit → 404', () async {
      final unknown = await post(
        Routes.lifecycleUploadCommit,
        token: 'token-a',
        body: {'permitId': 'nope'},
      );
      expect(unknown.status, 404);

      final preview = await post(
        Routes.lifecycleUploadPreview,
        token: 'token-a',
        body: {'kind': 'file', 'uploadBytes': 1},
      );
      final permitId = (preview.json as Map)['permitId'] as String;
      final cross = await post(
        Routes.lifecycleUploadCommit,
        token: 'token-b',
        body: {'permitId': permitId},
      );
      expect(cross.status, 404);
    });

    test('不存在生命周期的路径返回 404', () async {
      final res = await get('${Routes.prefix}/lifecycle/does-not-exist',
          token: 'token-a');
      expect(res.status, 404);
    });
  });

  group('导出 / 导入', () {
    test('导出按当前账号，manifest ownerAccountId 正确', () async {
      final a = await post(Routes.lifecycleExport, token: 'token-a', body: {});
      expect(a.status, 200);
      final aj = a.json as Map;
      expect(aj['ownerAccountId'], 'a');
      expect((aj['manifest'] as Map)['ownerAccountId'], 'a');
      expect((aj['files'] as Map).containsKey('manifest.json'), isTrue);
      expect(aj.toString(), isNot(contains('sk-SECRET')));

      final b = await post(Routes.lifecycleExport, token: 'token-b', body: {});
      expect((b.json as Map)['manifest']['ownerAccountId'], 'b');
    });

    test('导入落到当前账号并返回报告', () async {
      final exported = await post(Routes.lifecycleExport, token: 'token-a', body: {});
      final files = (exported.json as Map)['files'];
      final imported = await post(
        Routes.lifecycleImport,
        token: 'token-b',
        body: {'mode': 'personaAndConversations', 'files': files},
      );
      expect(imported.status, 200);
      final report = imported.json as Map;
      expect(report['checksumVerified'], true);
      expect(await importSink.hasPersona('b'), isTrue);
      expect(importSink.conversationCount('b'), 1);
      expect(await importSink.hasPersona('a'), isFalse);
    });
  });

  group('离开 survey / receipt', () {
    test('survey 按当前账号返回计数，owner 隔离', () async {
      final a = await get(Routes.lifecycleDepartureSurvey, token: 'token-a');
      expect(a.status, 200);
      expect((a.json as Map)['objectCounts']['conversations'], 2);
      final b = await get(Routes.lifecycleDepartureSurvey, token: 'token-b');
      expect((b.json as Map)['objectCounts'], <String, Object?>{});
    });

    test('receipt 生成并含轮转到期日与处置', () async {
      final res = await post(
        Routes.lifecycleDepartureReceipt,
        token: 'token-a',
        body: {'aiDisposition': 'transfer'},
      );
      expect(res.status, 200);
      final json = res.json as Map;
      expect(json['aiDisposition'], 'transfer');
      expect(json['backupRotationDueAt'], isNotNull);
      expect((json['totalObjects'] as int) > 0, isTrue);
    });

    test('非法 aiDisposition 返回 400', () async {
      final res = await post(
        Routes.lifecycleDepartureReceipt,
        token: 'token-a',
        body: {'aiDisposition': 'nonsense'},
      );
      expect(res.status, 400);
    });
  });
}
