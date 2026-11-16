/// CR-03/CR-07 真实适配器测试：owner 枚举/隔离、授权范围、时区、音色目录、
/// 活动来源、确定性信件与离线缓存文件。
library;

import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/creative/creative_adapters.dart';
import 'package:jingyu_host/src/creative/creative_migrations.dart';
import 'package:jingyu_host/src/creative/creative_time.dart';
import 'package:jingyu_host/src/creative/reports/reports_models.dart';
import 'package:jingyu_host/src/creative/reports/reports_service.dart';
import 'package:jingyu_host/src/creative/reports/reports_store.dart';
import 'package:jingyu_host/src/creative/reports/sqlite_reports_store.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host/src/voice/voice_migrations.dart';
import 'package:test/test.dart';

const UserTimeZone _zone = UserTimeZone(Duration(hours: 8));

void main() {
  late Directory dir;
  late SqliteDatabase database;

  Future<void> insertAccount(
    String id,
    String kind, {
    bool disabled = false,
  }) => database.execute(
    'INSERT INTO account(id, display_name, kind, is_admin, disabled, '
    'password_hash, failed_passwords, locked_until) '
    'VALUES(?,?,?,?,?,?,?,?)',
    [id, id, kind, 0, disabled ? 1 : 0, kind == 'human' ? 'x' : null, 0, 0],
  );

  Future<void> insertAi(String owner, String aiAccount, String profile) async {
    await insertAccount(aiAccount, 'ai');
    await database.execute(
      'INSERT INTO ai_operator(ai_id, operator_id) VALUES(?,?)',
      [aiAccount, owner],
    );
    await database.execute(
      'INSERT INTO ai_profile(id, account_id) VALUES(?,?)',
      [profile, aiAccount],
    );
  }

  Future<void> insertVoice(String aiAccount, String voiceId) => database.execute(
    'INSERT INTO voice_profiles(ai_id, provider, model, voice_id, params_json, '
    'revision, consent_ref, activated_at) VALUES(?,?,?,?,?,?,?,?)',
    [aiAccount, 'test', 'm', voiceId, '{}', 1, 'c', DateTime.utc(2026).toIso8601String()],
  );

  Future<void> insertActivity(
    String owner,
    String ai, {
    CreativeScope scope = CreativeScope.privateChat,
    required CreativeActivityKind kind,
    required String dayKey,
    String label = '',
    int value = 0,
  }) => database.execute(
    'INSERT INTO creative_activity(owner_account_id, ai_id, scope, kind, day_key, label, value) '
    'VALUES(?,?,?,?,?,?,?)',
    [owner, ai, scope.name, kind.name, dayKey, label, value],
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jingyu-creative-adapters-');
    database = await SqliteDatabase.open(
      '${dir.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        aiIdentityMigration,
        ...voiceProfileMigrations,
        ...creativeMigrations,
      ],
    );
    await insertAccount('u1', 'human');
    await insertAccount('u2', 'human');
    await insertAi('u1', 'aiA', 'pA');
    await insertAi('u2', 'aiB', 'pB');
    await insertVoice('aiA', 'voice-1');
  });

  tearDown(() async {
    await database.close();
    await dir.delete(recursive: true);
  });

  test('目标枚举：从 ai_profile/ai_operator/account 得到 (owner, aiProfile) 对', () async {
    final directory = CreativeTargetDirectory(
      database: database,
      authorization: InMemoryCreativeAuthorizationPolicy()
    );
    final pairs = await directory.pairs();
    expect(pairs, hasLength(2));
    expect(pairs[0].ownerAccountId, 'u1');
    expect(pairs[0].aiProfileId, 'pA');
    expect(pairs[1].ownerAccountId, 'u2');
    expect(pairs[1].aiProfileId, 'pB');
  });

  test('报告目标：只纳入已授权对象，未授权（空 scope）不进入调度', () async {
    final policy = InMemoryCreativeAuthorizationPolicy()
      ..grant('u1', 'pA', {CreativeScope.privateChat});
    final provider = SqliteReportTargetProvider(
      CreativeTargetDirectory(database: database, authorization: policy),
    );
    final targets = await provider.targets();
    expect(targets, hasLength(1));
    expect(targets.single.ownerAccountId, 'u1');
    expect(targets.single.aiId, 'pA');
    expect(targets.single.authorizedScopes, {CreativeScope.privateChat});
    // u2/pB 未授权，必须缺席。
    expect(targets.any((t) => t.ownerAccountId == 'u2'), isFalse);
  });

  test('电台目标：需要档案音色；无音色的 AI 不生成', () async {
    final voices = InMemoryCreativeVoiceDirectory()..set('u1', 'pA', 'voice-1');
    final provider = SqliteRadioTargetProvider(
      directory: CreativeTargetDirectory(
        database: database,
        authorization: InMemoryCreativeAuthorizationPolicy()
      ),
      voices: voices,
    );
    final targets = await provider.targets();
    expect(targets, hasLength(1));
    expect(targets.single.aiId, 'pA');
    expect(targets.single.profileVoiceId, 'voice-1');
  });

  test('SQLite 音色目录：从 voice_profiles 取档案音色，未知返回 null', () async {
    final voices = SqliteCreativeVoiceDirectory(database: database);
    expect(await voices.voiceIdFor(ownerAccountId: 'u1', aiProfileId: 'pA'), 'voice-1');
    expect(await voices.voiceIdFor(ownerAccountId: 'u1', aiProfileId: 'missing'), isNull);
    // 非本人（u2 查 u1 的 AI）拿不到音色。
    expect(await voices.voiceIdFor(ownerAccountId: 'u2', aiProfileId: 'pA'), isNull);
  });

  test('活动来源：只读本人窗口内数据，绝不跨用户', () async {
    await insertActivity(
      'u1',
      'pA',
      kind: CreativeActivityKind.topic,
      dayKey: '2026-11-15',
      label: '旅行',
      value: 3,
    );
    await insertActivity(
      'u2',
      'pB',
      kind: CreativeActivityKind.topic,
      dayKey: '2026-11-15',
      label: '机密话题',
    );
    final source = SqliteCreativeActivitySource(database: database);
    final mine = await source.collect(
      ownerAccountId: 'u1',
      aiId: 'pA',
      windowStartDay: '2026-11-09',
      windowEndDay: '2026-11-15',
    );
    expect(mine, hasLength(1));
    expect(mine.single.label, '旅行');
    expect(mine.single.value, 3);
    // 窗口外不返回。
    final outOfWindow = await source.collect(
      ownerAccountId: 'u1',
      aiId: 'pA',
      windowStartDay: '2026-11-16',
      windowEndDay: '2026-11-22',
    );
    expect(outOfWindow, isEmpty);
  });

  test('确定性信件：包含话题与统计字数，不含任何原文', () async {
    const writer = TemplateReportLetterWriter();
    final letter = await writer.writeLetter(
      const ReportLetterContext(
        kind: ReportKind.weekly,
        periodKey: '2026-11-15',
        commonTopics: [TopicCount('旅行', 3)],
        completedAgreements: 2,
        checkinDays: 4,
      ),
    );
    expect(letter, contains('旅行'));
    expect(letter, contains('2'));
    expect(letter, contains('4'));
  });

  test('离线缓存音色后端：写真实文件、回显音色、空脚本返回 null', () async {
    final synth = FileBackedVoiceSynthesizer(cacheDir: '${dir.path}/voice');
    final audio = await synth.synthesize(script: '晚安，慢慢呼吸。', voiceId: 'voice-1');
    expect(audio, isNotNull);
    expect(audio!.voiceId, 'voice-1');
    expect(File(audio.ref).existsSync(), isTrue);
    expect(await File(audio.ref).readAsString(), '晚安，慢慢呼吸。');
    expect(await synth.synthesize(script: '  ', voiceId: 'voice-1'), isNull);
  });

  test('适配器集成 + 时区：本地 21:30 前不生成、到点生成（owner 隔离）', () async {
    await insertActivity(
      'u1',
      'pA',
      kind: CreativeActivityKind.topic,
      dayKey: '2026-11-15',
      label: '旅行',
      value: 3,
    );
    final policy = InMemoryCreativeAuthorizationPolicy()
      ..grant('u1', 'pA', {CreativeScope.privateChat});
    final clock = FakeClock(DateTime.utc(2026, 11, 15, 12, 0)); // 周日 20:00 本地
    final service = ReportsService(
      store: SqliteReportsStore(database: database),
      activitySource: SqliteCreativeActivitySource(database: database),
      clock: clock,
      timeZone: _zone,
      targetProvider: SqliteReportTargetProvider(
        CreativeTargetDirectory(database: database, authorization: policy),
      ),
      letterWriter: const TemplateReportLetterWriter(),
    );
    // 20:00 未到本周 21:30：不生成本周报告（首次 tick 可能把上周记为 missed）。
    final before = await service.tick();
    expect(
      before.where((record) => record.status == ReportStatus.generated),
      isEmpty,
    );
    // 21:31 本地：生成，且只能读到本人报告。
    clock.set(DateTime.utc(2026, 11, 15, 13, 31));
    final changed = await service.tick();
    expect(
      changed.where((record) => record.status == ReportStatus.generated),
      hasLength(1),
    );
    expect(changed.single.periodKey, '2026-11-15');
    final mine = await service.getReport(
      ownerAccountId: 'u1',
      aiId: 'pA',
      kind: ReportKind.weekly,
      periodKey: '2026-11-15',
    );
    expect(mine.isOk, isTrue);
    expect(mine.value.commonTopics.first.label, '旅行');
    final foreign = await service.getReport(
      ownerAccountId: 'u2',
      aiId: 'pA',
      kind: ReportKind.weekly,
      periodKey: '2026-11-15',
    );
    expect(foreign.isErr, isTrue);
  });
}
