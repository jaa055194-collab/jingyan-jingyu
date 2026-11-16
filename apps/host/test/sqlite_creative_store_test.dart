/// 创意模块 SQLite 存储：复用内存实现相同的契约测试，并校验完整对象往返。
///
/// [SqliteReportsStore] 与 [SqliteRadioStore] 必须与内存实现一样通过契约测试
/// （内存与 SQLite 共用 `creative_*_store_contract.dart`）。
library;

import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/creative/creative_migrations.dart';
import 'package:jingyu_host/src/creative/creative_time.dart';
import 'package:jingyu_host/src/creative/radio/radio_models.dart';
import 'package:jingyu_host/src/creative/radio/radio_service.dart';
import 'package:jingyu_host/src/creative/radio/sqlite_radio_store.dart';
import 'package:jingyu_host/src/creative/reports/reports_models.dart';
import 'package:jingyu_host/src/creative/reports/reports_service.dart';
import 'package:jingyu_host/src/creative/reports/reports_store.dart';
import 'package:jingyu_host/src/creative/reports/sqlite_reports_store.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

import 'creative_radio_store_contract.dart';
import 'creative_reports_store_contract.dart';

const UserTimeZone _zone = UserTimeZone(Duration(hours: 8));

class _FakeVoice implements VoiceSynthesizer {
  @override
  Future<RadioAudio?> synthesize({
    required String script,
    required String voiceId,
  }) async => RadioAudio(voiceId: voiceId, ref: 'cache-ref-$voiceId');
}

void main() {
  late Directory dir;
  late SqliteDatabase database;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jingyu-creative-');
    database = await SqliteDatabase.open(
      '${dir.path}/host.sqlite',
      migrations: [...allMigrations, ...creativeMigrations],
    );
  });

  tearDown(() async {
    await database.close();
    await dir.delete(recursive: true);
  });

  reportsStoreContract(
    'SQLite',
    () => SqliteReportsStore(database: database),
  );
  radioStoreContract('SQLite', () => SqliteRadioStore(database: database));

  test('SQLite ReportsStore：完整周报对象往返（含的话题/心情/信件）', () async {
    final clock = FakeClock(DateTime.utc(2026, 11, 15, 13, 31)); // 周日 21:31
    final source = InMemoryCreativeActivitySource([
      const CreativeActivity(
        ownerAccountId: 'u1',
        aiId: 'ai1',
        scope: CreativeScope.privateChat,
        kind: CreativeActivityKind.topic,
        dayKey: '2026-11-15',
        label: '旅行',
        value: 3,
      ),
      const CreativeActivity(
        ownerAccountId: 'u1',
        aiId: 'ai1',
        scope: CreativeScope.privateChat,
        kind: CreativeActivityKind.mood,
        dayKey: '2026-11-11',
        value: 4,
      ),
      const CreativeActivity(
        ownerAccountId: 'u1',
        aiId: 'ai1',
        scope: CreativeScope.privateChat,
        kind: CreativeActivityKind.agreementCompleted,
        dayKey: '2026-11-12',
        value: 1,
      ),
    ]);
    final store = SqliteReportsStore(database: database);
    final service = ReportsService(
      store: store,
      activitySource: source,
      clock: clock,
      timeZone: _zone,
      targetProvider: InMemoryReportTargetProvider([
        const ReportTarget(
          ownerAccountId: 'u1',
          aiId: 'ai1',
          authorizedScopes: {CreativeScope.privateChat},
        ),
      ]),
    );
    final changed = await service.tick();
    expect(changed.single.status, ReportStatus.generated);

    // 用新的 store 实例读取，验证真的落到了 SQLite 并可反序列化。
    final reloaded = SqliteReportsStore(database: database);
    final result = await reloaded.find(
      ownerAccountId: 'u1',
      aiId: 'ai1',
      kind: ReportKind.weekly,
      periodKey: '2026-11-15',
    );
    expect(result, isNotNull);
    final report = result!.report!;
    expect(report.commonTopics.first.label, '旅行');
    expect(report.commonTopics.first.count, 3);
    expect(report.moodCurve['2026-11-11'], 4);
    expect(report.completedAgreements, 1);
    expect(report.letter, isNotEmpty);
    expect(report.sourceScopes, {CreativeScope.privateChat});
    expect(report.shareCard.watermark, contains('鲸言鲸语'));
  });

  test('SQLite RadioStore：完整电台期次往返（脚本/离线/音色）', () async {
    final clock = FakeClock(DateTime.utc(2026, 11, 16, 14, 50)); // 本地 22:50
    final store = SqliteRadioStore(database: database);
    final service = RadioService(
      store: store,
      scriptSource: const TemplateRadioScriptSource(),
      voice: _FakeVoice(),
      clock: clock,
      timeZone: _zone,
      targetProvider: InMemoryRadioTargetProvider([
        const RadioTarget(
          ownerAccountId: 'u1',
          aiId: 'ai1',
          profileVoiceId: 'voice-1',
        ),
      ]),
    );
    final generated = await service.tick();
    expect(generated.single.dateKey, '2026-11-16');

    final reloaded = SqliteRadioStore(database: database);
    final episode = await reloaded.find(
      ownerAccountId: 'u1',
      aiId: 'ai1',
      dateKey: '2026-11-16',
    );
    expect(episode, isNotNull);
    expect(episode!.voiceId, 'voice-1');
    expect(episode.playableOffline, isTrue);
    expect(episode.offlineCacheKey, 'cache-ref-voice-1');
    expect(episode.script.segments, hasLength(3));
    expect(episode.script.text, isNotEmpty);
  });

  test('创意迁移 800–899 生效：版本推进且表就绪', () async {
    expect(await database.schemaVersion(), greaterThanOrEqualTo(801));
    final tables = await database.query(
      "SELECT name FROM sqlite_master WHERE type='table' AND name IN "
      "('creative_reports','creative_radio_episodes')",
    );
    expect(tables.map((row) => row['name']).toSet(), {
      'creative_reports',
      'creative_radio_episodes',
    });
  });
}
