/// 鲸言鲸语宿主应用装配。
///
/// [buildHost] 是唯一的装配入口：测试与 `bin/server.dart` 都从这里取，
/// 新模块只需在 [defaultModules] 里追加一行（或由插件清单注入）。
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'src/brain/group_rules_module.dart';
import 'src/ai/social_level/social_level_service.dart';
import 'src/models/budget_configuration.dart';
import 'src/models/usage_meter.dart';
import 'src/models/provider_registry.dart';
import 'src/social/group_ai_policy.dart';
import 'src/messages/message_store.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';

import 'src/ai/persona/persona_migrations.dart';
import 'src/ai/persona/persona_module.dart';
import 'src/ai/social_level/social_level_migrations.dart';
import 'src/ai/social_level/social_level_module.dart';
import 'src/ai/social_level/sqlite_social_level_store.dart';
import 'src/audit/admin_audit_module.dart';
import 'src/audit/admin_audit_reader.dart';
import 'src/accounts/accounts_module.dart';
import 'src/accounts/db_authenticator.dart';
import 'src/accounts/password_hasher.dart';
import 'src/accounts/accounts_sql_store.dart';
import 'src/accounts/accounts_migrations.dart';
import 'src/messages/messages_migrations.dart';
import 'src/models/models_migrations.dart';
import 'src/models/admin_usage_module.dart';
import 'src/models/admin_usage_reader.dart';
import 'src/models/ai_identity.dart';
import 'src/models/binding_migrations.dart';
import 'src/models/usage_migrations.dart';
import 'src/models/budget_timezone_migration.dart';
import 'src/models/model_runtime.dart';
import 'src/models/models_module.dart';
import 'src/security/url_guard.dart';
import 'src/security/process_http.dart';
import 'src/messages/sqlite_message_store.dart';
import 'src/social/conversation_service.dart';
import 'src/social/social_migrations.dart';
import 'src/social/conversation_preferences_migration.dart';
import 'src/social/group_ai_migrations.dart';
import 'src/social/topic_migrations.dart';
import 'src/social/friendship_migrations.dart';
import 'src/social/private_conversations.dart';
import 'src/social/private_conversation_migration.dart';
import 'src/social/social_module.dart';
import 'src/storage/migrations.dart';
import 'src/storage/storage_module.dart';
import 'src/config.dart';
import 'src/messages/blind_index.dart';
import 'src/messages/favorite_blind_index.dart';
import 'src/messages/favorites.dart';
import 'src/messages/attachments.dart';
import 'src/messages/attachments_module.dart';
import 'src/messages/messages_module.dart';
import 'src/messages/pins.dart';
import 'src/messages/reactions.dart';
import 'src/messages/scheduled.dart';
import 'src/messages/search.dart';
import 'src/creative/creative_activity_writer.dart';
import 'src/creative/creative_adapters.dart';
import 'src/creative/creative_authorization_module.dart';
import 'src/creative/creative_migrations.dart';
import 'src/creative/sqlite_creative_authorization_store.dart';
import 'src/creative/creative_time.dart';
import 'src/creative/radio/radio_models.dart';
import 'src/creative/radio/radio_module.dart';
import 'src/creative/radio/radio_service.dart';
import 'src/creative/radio/sqlite_radio_store.dart';
import 'src/creative/reports/reports_module.dart';
import 'src/creative/reports/reports_service.dart';
import 'src/creative/reports/sqlite_reports_store.dart';
import 'src/voice/voice_migrations.dart';
import 'src/voice/voice_module.dart';
import 'src/world/world_migrations.dart';
import 'src/world/world_module.dart';
import 'src/world/sqlite_avatar_registry.dart';
import 'src/world/sqlite_presence_service.dart';
import 'src/world/sqlite_space_layout_store.dart';
import 'src/lifecycle/cleanup.dart';
import 'src/lifecycle/departure.dart';
import 'src/lifecycle/lifecycle_migrations.dart';
import 'src/lifecycle/lifecycle_module.dart';
import 'src/lifecycle/quota_service.dart';
import 'src/lifecycle/sqlite_cleanup_store.dart';
import 'src/lifecycle/sqlite_departure_store.dart';
import 'src/lifecycle/sqlite_quota_store.dart';
import 'src/system/system_module.dart';

export 'src/audit/audit_log.dart';
export 'src/accounts/accounts_module.dart';
export 'src/accounts/db_authenticator.dart';
export 'src/config.dart';
export 'src/http_server.dart';
export 'src/messages/message_store.dart';
export 'src/messages/messages_module.dart';
export 'src/security/url_guard.dart';
export 'src/system/system_module.dart';

/// 已装配好的宿主。
class Host {
  Host._(this.registry, this.pipeline, this.auth);

  final Registry registry;
  final Pipeline pipeline;
  final AccountsDomain auth;

  Future<List<Object>> shutdown() => registry.shutdown();
}

/// 框架阶段默认模块。后续模块按 docs/modules 的编号追加。
List<HostModule> defaultModules(HostConfig config, Clock clock) {
  final storage = StorageModule(
    databasePath: '${config.dataDir}/host.sqlite',
    migrations: [
      ...allMigrations,
      ...accountsMigrations,
      ...messagesMigrations,
      ...socialMigrations,
      friendshipMigration,
      privateConversationMigration,
      groupAiMigration,
      topicMigration,
      conversationPreferencesMigration,
      ...modelsMigrations,
      aiIdentityMigration,
      bindingMigration,
      ...usageMigrations,
      budgetTimezoneMigration,
      ...personaMigrations,
      socialLevelMigration,
      ...creativeMigrations,
      ...voiceMigrations,
      ...worldMigrations,
      ...lifecycleMigrations,
    ],
  );
  final messages = SqliteMessageStore(
    database: storage.database,
    cipher: storage.cipher,
    clock: clock,
  );
  final scheduledMessages = ScheduledMessageService(
    database: storage.database,
    cipher: storage.cipher,
    store: messages,
    clock: clock,
  );
  final reactions = ReactionsService(database: storage.database, clock: clock);
  final blindIndex = BlindIndexService(
    database: storage.database,
    cipher: storage.cipher,
  );
  final messageSearch = MessageSearchService(
    database: storage.database,
    store: messages,
    blind: blindIndex,
  );
  final pins = PinsService(database: storage.database, clock: clock);
  final favoriteBlindIndex = FavoriteBlindIndexService(
    database: storage.database,
    cipher: storage.cipher,
  );
  final favorites = FavoritesService(
    database: storage.database,
    cipher: storage.cipher,
    clock: clock,
    blind: favoriteBlindIndex,
  );
  final attachments = AttachmentService(
    database: storage.database,
    cipher: storage.cipher,
    mediaDir: '${config.dataDir}/media',
    clock: clock,
  );
  final conversations = ConversationService(
    database: storage.database,
    clock: clock,
    cipher: storage.cipher,
    headSeq: messages.headSeqInTransaction,
    accountExists: (tx, id) async => (await tx.query(
      'SELECT id FROM account WHERE id = ? AND disabled = 0',
      [id],
    )).isNotEmpty,
  );
  final accounts = AccountsDomain(
    store: SqlAccountsStore(storage.database),
    clock: clock,
    hasher: PasswordHasher(),
  );
  final urlGuard = UrlGuard();
  final executable = config.modelWorkerExecutable;
  final workerPath = config.modelWorkerPath;
  if ((executable == null) != (workerPath == null)) {
    throw ArgumentError('Both model worker executable and path are required');
  }
  final runtime = executable == null
      ? null
      : ModelRuntime.withProcess(
          db: storage.database,
          cipher: storage.cipher,
          urlGuard: urlGuard,
          clock: clock,
          executable: executable,
          workerPath: workerPath!,
        );
  final levels = SqliteSocialLevelStore(
    database: storage.database,
    clock: clock,
  );
  // Local-only sequential gates. Admission is atomic in GroupAiPolicy, but a
  // later append failure may consume its slot; no crash replay/queue is promised.
  Future<({String owner, AiId profile})?> resolve(
    StoredMessage incoming,
    String target,
  ) async {
    final rows = await storage.database.query(
      '''
SELECT o.operator_id AS owner,p.id AS profile FROM messages m
JOIN account human ON human.id=m.sender_id AND human.kind='human' AND human.disabled=0
JOIN social_conversations g ON g.id=m.conversation_id
JOIN social_members source ON source.conversation_id=g.id AND source.account_id=human.id AND source.first_visible_seq<=m.seq
JOIN account ai ON ai.id=? AND ai.kind='ai' AND ai.disabled=0
JOIN ai_operator o ON o.ai_id=ai.id
JOIN account owner ON owner.id=o.operator_id AND owner.kind='human' AND owner.disabled=0
JOIN ai_profile p ON p.account_id=ai.id
JOIN social_members member ON member.conversation_id=g.id AND member.account_id=ai.id AND member.first_visible_seq<=m.seq
WHERE m.message_id=? AND m.conversation_id=? AND m.sender_id=? AND m.seq=? AND m.kind='text' AND m.recalled_at IS NULL
AND NOT EXISTS(SELECT 1 FROM message_edits e WHERE e.message_id=m.message_id)
AND NOT EXISTS(SELECT 1 FROM direct_conversations d WHERE d.id=g.id)
''',
      [
        target,
        incoming.messageId,
        incoming.conversationId,
        incoming.senderId,
        incoming.seq,
      ],
    );
    if (rows.length != 1) return null;
    final owner = rows.single['owner'] as String,
        profile = AiId.parse(rows.single['profile'] as String);
    final level = await levels.get(owner: AccountId.parse(owner), ai: profile);
    if (level.valueOrNull?.level == null ||
        level.valueOrNull!.level == AiSocialLevel.l0) {
      return null;
    }
    return (owner: owner, profile: profile);
  }

  Future<BudgetDay?> budget(({String owner, AiId profile}) target) async {
    final config = await BudgetConfiguration.forOwner(
      ownerId: target.owner,
      db: storage.database,
      clock: clock,
    ).get(target.profile);
    if (config.isErr) return null;
    final gate =
        await UsageMeter.forOwner(
          ownerId: target.owner,
          db: storage.database,
          clock: clock,
          dayForClock: (c) =>
              BudgetDay.fromClock(c, offsetMinutes: config.value.offsetMinutes),
        ).inspect(
          target.profile,
          layer: BudgetLayer.b1FastBrain,
          capability: ProviderCapability.chatFast,
        );
    return gate.valueOrNull?.day;
  }

  final groupRules = GroupRulesModule(
    dispatch: (incoming, target, reply) async {
      final first = await resolve(incoming, target);
      if (first == null || await budget(first) == null) return;
      final current = await resolve(incoming, target);
      if (current == null || current != first) return;
      final day = await budget(current);
      if (day == null) return;
      final gate =
          await GroupAiPolicy(
            actorId: AccountId.parse(target),
            database: storage.database,
            clock: clock,
            budgetDay: (_) => day,
          ).tryConsumePost(
            ConversationId.parse(incoming.conversationId),
            roundId: incoming.messageId,
            mentioned: true,
          );
      if (gate.isErr) return;
      final id =
          's1_${sha256.convert(utf8.encode('${incoming.messageId}:$target')).toString().substring(0, 48)}';
      final sent = await messages.append(
        conversationId: incoming.conversationId,
        senderId: target,
        clientMsgId: id,
        kind: MessageKind.text,
        body: {'text': reply.text, 'source': 's1', 'activityRefs': <String>[]},
      );
      if (sent.isOk && !sent.value.duplicate) {
        try {
          await blindIndex.indexMessage(
            messageId: sent.value.message.messageId,
            conversationId: incoming.conversationId,
            body: sent.value.message.body,
          );
        } catch (_) {}
      }
    },
  );
  final providerDiscoveryRequest = executable == null
      ? null
      : ProcessHttpTransport(
          executable: executable,
          workerPath: workerPath!,
        ).request;
  final creativeAuthorization = SqliteCreativeAuthorizationStore(
    database: storage.database,
    clock: clock,
  );
  final creativeActivityWriter = SqliteCreativeActivityWriter(
    database: storage.database,
  );
  final creativeDirectory = CreativeTargetDirectory(
    database: storage.database,
    authorization: creativeAuthorization,
  );
  final creativeActivity = SqliteCreativeActivitySource(
    database: storage.database,
  );
  final creativeTimeZone = const UserTimeZone(Duration.zero);
  final reportsService = ReportsService(
    store: SqliteReportsStore(database: storage.database),
    activitySource: creativeActivity,
    clock: clock,
    timeZone: creativeTimeZone,
    targetProvider: SqliteReportTargetProvider(creativeDirectory),
    letterWriter: const TemplateReportLetterWriter(),
    generationEnabled: false,
  );
  final radioService = RadioService(
    store: SqliteRadioStore(database: storage.database),
    scriptSource: const TemplateRadioScriptSource(),
    voice: const UnavailableCreativeVoiceSynthesizer(),
    generationEnabled: false,
    clock: clock,
    timeZone: creativeTimeZone,
    targetProvider: SqliteRadioTargetProvider(
      directory: creativeDirectory,
      voices: SqliteCreativeVoiceDirectory(database: storage.database),
    ),
  );
  return [
    SystemModule(
      config: config,
      clock: clock,
      audit: storage.auditLog,
      urlGuard: urlGuard,
    ),
    storage,
    AccountsModule(domain: accounts),
    AdminAuditModule(
      reader: AdminAuditReader(database: storage.database, clock: clock),
    ),
    AdminUsageModule(
      reader: AdminUsageReader(database: storage.database, clock: clock),
    ),
    MessagesModule(
      store: messages,
      authenticate: DbAuthenticator(accounts).call,
      scheduled: scheduledMessages,
      reactions: reactions,
      search: messageSearch,
      pins: pins,
      blind: blindIndex,
      favorites: favorites,
      attachments: attachments,
      clock: clock,
    ),
    AttachmentsModule(attachments: attachments),
    SocialModule(
      direct: PrivateConversations(db: storage.database, clock: clock),
      conversations: conversations,
      database: storage.database,
      clock: clock,
    ),
    WorldModule(
      layouts: SqliteSpaceLayoutStore(database: storage.database, clock: clock),
      presence: SqlitePresenceService(database: storage.database, clock: clock),
      avatars: SqliteAvatarRegistry(database: storage.database, clock: clock),
      clock: clock,
    ),
    ModelsModule(
      runtime: runtime,
      providerDiscoveryRequest: providerDiscoveryRequest,
      db: storage.database,
      cipher: storage.cipher,
      urlGuard: urlGuard,
      clock: clock,
    ),
    VoiceModule.persistent(database: storage.database, clock: clock),
    SocialLevelModule(
      service: levels,
      authenticate: DbAuthenticator(accounts).call,
      clock: clock,
    ),
    groupRules,
    PersonaModule(
      database: storage.database,
      cipher: storage.cipher,
      clock: clock,
      authenticate: DbAuthenticator(accounts).call,
    ),
    CreativeAuthorizationModule(
      store: creativeAuthorization,
      activityWriter: creativeActivityWriter,
    ),
    ReportsModule(service: reportsService, enableTimer: false),
    RadioModule(service: radioService, enableTimer: false),
    LifecycleModule(
      clock: clock,
      audit: storage.auditLog,
      quota: QuotaService(
        store: SqliteQuotaStore(database: storage.database, clock: clock),
      ),
      cleanup: CleanupService(
        store: SqliteCleanupStore(database: storage.database, clock: clock),
        clock: clock,
        audit: storage.auditLog,
      ),
      departure: DepartureService(
        store: SqliteDepartureStore(database: storage.database),
        clock: clock,
        audit: storage.auditLog,
      ),
    ),
  ];
}

/// 装配并启动宿主（不监听端口）。
Future<Host> buildHost({
  HostConfig config = const HostConfig(),
  Clock clock = const SystemClock(),
  List<HostModule>? modules,
  void Function(Object error, StackTrace stack)? onError,
}) async {
  final registry = Registry();
  final list = modules ?? defaultModules(config, clock);
  for (final module in list) {
    registry.register(module);
  }
  for (final module in list.whereType<SystemModule>()) {
    module.moduleNames = () => registry.moduleNames;
  }
  await registry.boot();

  final auth = registry.services.get<AccountsDomain>();
  final pipeline = Pipeline(
    router: registry.router,
    authenticate: DbAuthenticator(auth).call,
    onError: (error, stack, _) => onError?.call(error, stack),
  );
  return Host._(registry, pipeline, auth);
}
