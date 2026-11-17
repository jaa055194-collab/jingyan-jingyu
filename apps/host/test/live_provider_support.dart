/// Shared support for the env-gated live-provider tests.
///
/// Two host tests exercise the real model chain and must stay in sync:
///   - `provider_live_probe_test.dart` (single bounded completion)
///   - `worker_e2e_live_assembly_test.dart` (trusted worker end-to-end)
/// This file centralises the env gate, the SQLite migration set and the owner
/// chain fixtures (accounts + AI profile + provider + binding + budget + persona)
/// so the two tests cannot drift apart.
///
/// Local configuration (key only in the process environment, never committed):
/// ```powershell
/// $env:JINGYU_LIVE_BASE_URL = 'https://<openai-compatible-host>/v1'
/// $env:JINGYU_LIVE_API_KEY  = '<local only, never committed>'
/// $env:JINGYU_LIVE_MODEL    = 'auto'   # optional
/// dart test test/provider_live_probe_test.dart test/worker_e2e_live_assembly_test.dart
/// ```
/// When the variables are absent both suites SKIP; nothing is fabricated and no
/// key is ever printed, logged or written to disk.
library;

import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/ai/persona/persona_migrations.dart';
import 'package:jingyu_host/src/ai/persona/persona_service.dart';
import 'package:jingyu_host/src/brain/owner_ai_direct_source_migration.dart';
import 'package:jingyu_host/src/brain/owner_reply_attempts_migration.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/models/binding_matrix.dart';
import 'package:jingyu_host/src/models/binding_migrations.dart';
import 'package:jingyu_host/src/models/budget_configuration.dart';
import 'package:jingyu_host/src/models/budget_timezone_migration.dart';
import 'package:jingyu_host/src/models/models_migrations.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/models/usage_meter.dart';
import 'package:jingyu_host/src/models/usage_migrations.dart';
import 'package:jingyu_host/src/social/friendship_migrations.dart';
import 'package:jingyu_host/src/social/owner_ai_direct_migration.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/security/url_guard.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';

/// Union of the migrations both live tests need.
const List<Migration> liveProviderMigrations = [
  ...allMigrations,
  ...accountsMigrations,
  ...messagesMigrations,
  ownerReplyAttemptsMigration,
  ownerAiDirectSourceMigration,
  ...socialMigrations,
  friendshipMigration,
  privateConversationMigration,
  ownerAiDirectMigration,
  ...modelsMigrations,
  aiIdentityMigration,
  bindingMigration,
  ownerAiProfileInvalidationMigration,
  ...usageMigrations,
  budgetTimezoneMigration,
  ...personaMigrations,
];

/// The environment gate. Values are read once and never logged.
class LiveProviderEnv {
  const LiveProviderEnv._({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  factory LiveProviderEnv.fromEnvironment() {
    final baseUrl = Platform.environment['JINGYU_LIVE_BASE_URL']?.trim() ?? '';
    final apiKey = Platform.environment['JINGYU_LIVE_API_KEY'] ?? '';
    final modelRaw = Platform.environment['JINGYU_LIVE_MODEL']?.trim() ?? '';
    return LiveProviderEnv._(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: modelRaw.isEmpty ? 'auto' : modelRaw,
    );
  }

  final String baseUrl;
  final String apiKey;
  final String model;

  /// Presence only. A TTS-only key/endpoint will fail the call honestly.
  bool get hasCredentials => baseUrl.isNotEmpty && apiKey.trim().isNotEmpty;

  String get skipReason =>
      'live provider credentials absent (set JINGYU_LIVE_BASE_URL + '
      'JINGYU_LIVE_API_KEY, optional JINGYU_LIVE_MODEL); a TTS-only key cannot '
      'run this chat probe';
}

/// Seeds a human owner, their AI account, operator link and AI profile.
Future<void> seedOwnerAndAi(
  SqliteDatabase db, {
  String ownerId = 'owner',
  String aiAccountId = 'ai',
  String aiProfileId = 'profile',
}) async {
  await db.execute(
    "INSERT INTO account VALUES (?, ?, 'human', 0, 0, 'synthetic', 0, 0)",
    [ownerId, ownerId],
  );
  await db.execute(
    "INSERT INTO account VALUES (?, 'AI', 'ai', 0, 0, NULL, 0, 0)",
    [aiAccountId],
  );
  await db.execute('INSERT INTO ai_operator VALUES (?, ?)', [
    aiAccountId,
    ownerId,
  ]);
  await db.execute('INSERT INTO ai_profile VALUES (?, ?)', [
    aiProfileId,
    aiAccountId,
  ]);
}

/// Configures the same owner chain the PR#92 client write contracts use:
/// budget, provider (encrypted credential), chat binding, optional persona.
/// Returns the provider id.
Future<String> configureOwnerChain({
  required SqliteDatabase db,
  required AesGcmColumnCipher cipher,
  required Clock clock,
  required UrlGuard urlGuard,
  required AiId ai,
  required LiveProviderEnv env,
  required String ownerId,
  int dailyTokens = 1000000,
  int offsetMinutes = 480,
  bool withPersona = false,
}) async {
  await BudgetConfiguration.forOwner(
    ownerId: ownerId,
    db: db,
    clock: clock,
  ).configure(
    ai,
    UsageBudget(
      dailyTokens: dailyTokens,
      layerLimits: {
        for (final layer in BudgetLayer.values)
          layer: layer == BudgetLayer.b2DeepChat ? dailyTokens : 0,
      },
      capabilityLimits: {
        for (final cap in ProviderCapability.values)
          cap: cap == ProviderCapability.chat ? dailyTokens : 0,
      },
    ),
    offsetMinutes: offsetMinutes,
  );
  final providerId =
      (await ProviderRegistry.forOwner(
            ownerId: ownerId,
            db: db,
            cipher: cipher,
            urlGuard: urlGuard,
            clock: clock,
          ).create(
            name: 'Live',
            baseUrl: env.baseUrl,
            apiKey: env.apiKey,
            capabilities: const {ProviderCapability.chat},
          ))
          .value
          .id;
  final binding = await BindingMatrix.forOwner(
    ownerId,
    db,
  ).set(ai, ProviderCapability.chat, providerId: providerId, model: env.model);
  if (binding.isErr) {
    throw StateError(
      'chat binding failed: ${binding.failureOrNull!.code.name}',
    );
  }
  if (withPersona) {
    final persona =
        await SqlitePersonaService.forOwner(
          ownerId: ownerId,
          actorAccountId: ownerId,
          database: db,
          cipher: cipher,
          clock: clock,
        ).initialize(
          ai,
          initial: PersonaLayers(
            p0: const {'name': 'Nora'},
            p1: const {'style': 'warm and concise'},
            p2: const {'mood': 'calm'},
          ),
        );
    if (persona.isErr) {
      throw StateError(
        'persona initialize failed: ${persona.failureOrNull!.code.name}',
      );
    }
  }
  return providerId;
}
