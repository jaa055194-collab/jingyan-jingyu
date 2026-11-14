/// 鲸言鲸语宿主应用装配。
///
/// [buildHost] 是唯一的装配入口：测试与 `bin/server.dart` 都从这里取，
/// 新模块只需在 [defaultModules] 里追加一行（或由插件清单注入）。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';

import 'src/accounts/accounts_module.dart';
import 'src/accounts/db_authenticator.dart';
import 'src/accounts/password_hasher.dart';
import 'src/accounts/accounts_sql_store.dart';
import 'src/accounts/accounts_migrations.dart';
import 'src/messages/messages_migrations.dart';
import 'src/models/models_migrations.dart';
import 'src/models/ai_identity.dart';
import 'src/models/binding_migrations.dart';
import 'src/models/usage_migrations.dart';
import 'src/models/budget_timezone_migration.dart';
import 'src/models/model_runtime.dart';
import 'src/models/models_module.dart';
import 'src/security/url_guard.dart';
import 'src/messages/sqlite_message_store.dart';
import 'src/social/conversation_service.dart';
import 'src/social/social_migrations.dart';
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
import 'src/messages/favorites.dart';
import 'src/messages/messages_module.dart';
import 'src/messages/pins.dart';
import 'src/messages/reactions.dart';
import 'src/messages/scheduled.dart';
import 'src/messages/search.dart';
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
      ...modelsMigrations,
      aiIdentityMigration,
      bindingMigration,
      ...usageMigrations,
      budgetTimezoneMigration,
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
  final favorites = FavoritesService(
    database: storage.database,
    cipher: storage.cipher,
    clock: clock,
  );
  final conversations = ConversationService(
    database: storage.database,
    clock: clock,
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
  return [
    SystemModule(
      config: config,
      clock: clock,
      audit: storage.auditLog,
      urlGuard: urlGuard,
    ),
    storage,
    AccountsModule(domain: accounts),
    MessagesModule(
      store: messages,
      authenticate: DbAuthenticator(accounts).call,
      scheduled: scheduledMessages,
      reactions: reactions,
      search: messageSearch,
      pins: pins,
      blind: blindIndex,
      favorites: favorites,
      clock: clock,
    ),
    SocialModule(
      direct: PrivateConversations(db: storage.database, clock: clock),
      conversations: conversations,
      database: storage.database,
      clock: clock,
    ),
    ModelsModule(
      runtime: runtime,
      db: storage.database,
      cipher: storage.cipher,
      urlGuard: urlGuard,
      clock: clock,
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
