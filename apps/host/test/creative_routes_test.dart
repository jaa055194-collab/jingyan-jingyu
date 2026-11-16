/// CR-03/CR-07 只读 HTTP 路由测试：list/get、owner 隔离 404、未登录 401、
/// 非法 kind 400。路由通过真实 [Router] + [Pipeline] 调用，不依赖传输层。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/creative/creative_time.dart';
import 'package:jingyu_host/src/creative/reports/reports_models.dart';
import 'package:jingyu_host/src/creative/reports/reports_module.dart';
import 'package:jingyu_host/src/creative/reports/reports_service.dart';
import 'package:jingyu_host/src/creative/reports/reports_store.dart';
import 'package:jingyu_host/src/creative/radio/radio_models.dart';
import 'package:jingyu_host/src/creative/radio/radio_module.dart';
import 'package:jingyu_host/src/creative/radio/radio_service.dart';
import 'package:jingyu_host/src/creative/radio/radio_store.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

const UserTimeZone _zone = UserTimeZone(Duration(hours: 8));

class _EchoVoice implements VoiceSynthesizer {
  @override
  Future<RadioAudio?> synthesize({
    required String script,
    required String voiceId,
  }) async => RadioAudio(voiceId: voiceId, ref: 'cache/$voiceId');
}

void main() {
  late Pipeline pipeline;

  Future<HostResponse> get(String path, {String? token}) => pipeline.handle(
    HostRequest(
      method: 'GET',
      path: path,
      headers: {if (token != null) 'authorization': 'Bearer $token'},
    ),
  );

  setUp(() async {
    final router = Router();
    final services = HostServices();

    // --- CR-03 预置一份 u1 的周报 ---
    final reportClock = FakeClock(DateTime.utc(2026, 11, 15, 13, 31));
    final reportsService = ReportsService(
      store: InMemoryReportsStore(),
      activitySource: InMemoryCreativeActivitySource([
        const CreativeActivity(
          ownerAccountId: 'u1',
          aiId: 'ai1',
          scope: CreativeScope.privateChat,
          kind: CreativeActivityKind.topic,
          dayKey: '2026-11-15',
          label: '旅行',
          value: 3,
        ),
      ]),
      clock: reportClock,
      timeZone: _zone,
      targetProvider: InMemoryReportTargetProvider([
        const ReportTarget(
          ownerAccountId: 'u1',
          aiId: 'ai1',
          authorizedScopes: {CreativeScope.privateChat},
        ),
      ]),
    );
    await reportsService.tick();
    final reportsModule = ReportsModule(
      service: reportsService,
      enableTimer: false,
    );
    await reportsModule.configure(services);
    reportsModule.mount(router);

    // --- CR-07 预置一期 u1 的电台 ---
    final radioClock = FakeClock(DateTime.utc(2026, 11, 16, 14, 50));
    final radioService = RadioService(
      store: InMemoryRadioStore(),
      scriptSource: const TemplateRadioScriptSource(),
      voice: _EchoVoice(),
      clock: radioClock,
      timeZone: _zone,
      targetProvider: InMemoryRadioTargetProvider([
        const RadioTarget(
          ownerAccountId: 'u1',
          aiId: 'ai1',
          profileVoiceId: 'voice-1',
        ),
      ]),
    );
    await radioService.tick();
    final radioModule = RadioModule(service: radioService, enableTimer: false);
    await radioModule.configure(services);
    radioModule.mount(router);

    Future<Principal?> authenticate(HostRequest request) async {
      final header = request.headers['authorization'];
      if (header == 'Bearer t-u1') {
        return const Principal(accountId: 'u1', deviceId: 'd1');
      }
      if (header == 'Bearer t-u2') {
        return const Principal(accountId: 'u2', deviceId: 'd2');
      }
      return null;
    }

    pipeline = Pipeline(router: router, authenticate: authenticate);
  });

  String reportPath() => Routes.creativeReport
      .replaceFirst('{aiId}', 'ai1')
      .replaceFirst('{kind}', 'weekly')
      .replaceFirst('{periodKey}', '2026-11-15');
  String radioPath() => Routes.creativeRadioEpisode
      .replaceFirst('{aiId}', 'ai1')
      .replaceFirst('{dateKey}', '2026-11-16');

  test('GET /creative/reports 只返回本人报告', () async {
    final response = await get(Routes.creativeReports, token: 't-u1');
    expect(response.status, 200);
    final reports = (response.json! as Map)['reports'] as List;
    expect(reports, hasLength(1));
    expect((reports.single as Map)['periodKey'], '2026-11-15');
    expect((reports.single as Map)['status'], 'generated');
  });

  test('GET 单份报告：本人 200，他人 404，未登录 401，非法 kind 400', () async {
    final mine = await get(reportPath(), token: 't-u1');
    expect(mine.status, 200);
    expect((mine.json! as Map)['periodKey'], '2026-11-15');

    final foreign = await get(reportPath(), token: 't-u2');
    expect(foreign.status, 404);

    final anonymous = await get(reportPath());
    expect(anonymous.status, 401);

    final badKind = await get(
      Routes.creativeReport
          .replaceFirst('{aiId}', 'ai1')
          .replaceFirst('{kind}', 'nope')
          .replaceFirst('{periodKey}', '2026-11-15'),
      token: 't-u1',
    );
    expect(badKind.status, 400);
  });

  test('GET /creative/reports 他人为空列表', () async {
    final response = await get(Routes.creativeReports, token: 't-u2');
    expect(response.status, 200);
    expect((response.json! as Map)['reports'] as List, isEmpty);
  });

  test('GET 电台：本人 200（离线可听），他人 404，未登录 401', () async {
    final list = await get(Routes.creativeRadio, token: 't-u1');
    expect(list.status, 200);
    expect((list.json! as Map)['episodes'] as List, hasLength(1));

    final mine = await get(radioPath(), token: 't-u1');
    expect(mine.status, 200);
    final episode = mine.json! as Map;
    expect(episode['dateKey'], '2026-11-16');
    expect(episode['playableOffline'], isTrue);

    final foreign = await get(radioPath(), token: 't-u2');
    expect(foreign.status, 404);

    final anonymous = await get(radioPath());
    expect(anonymous.status, 401);
  });
}
