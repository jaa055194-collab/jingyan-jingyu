import 'package:jingyu_core/jingyu_core.dart';

import '../security/process_http.dart';
import '../security/url_guard.dart';
import '../storage/cipher.dart';
import '../storage/database.dart';
import 'budget_configuration.dart';
import 'model_gateway.dart';
import 'openai_chat_adapter.dart';
import 'usage_meter.dart';

/// Host service for chat calls using owner-persisted budget configuration.
///
/// The host resolves [TrustedChatContext] from authenticated conversation state.
/// This service has no HTTP entry point and accepts no caller-selected budget
/// day or timezone. The injected adapter is a trusted transport boundary.
final class ModelRuntime {
  ModelRuntime({
    required Database db,
    required ColumnCipher cipher,
    required UrlGuard urlGuard,
    required Clock clock,
    required OpenAiCompatibleChatAdapter adapter,
  }) : _db = db,
       _cipher = cipher,
       _guard = urlGuard,
       _clock = clock,
       _adapter = adapter;

  /// Production composition: deployer supplies both trusted absolute paths.
  /// Each outbound request runs through the bounded guarded worker process.
  factory ModelRuntime.withProcess({
    required Database db,
    required ColumnCipher cipher,
    required UrlGuard urlGuard,
    required Clock clock,
    required String executable,
    required String workerPath,
    Duration timeout = const Duration(seconds: 15),
    int maxResponseBytes = 4 * 1024 * 1024,
  }) => ModelRuntime(
    db: db,
    cipher: cipher,
    urlGuard: urlGuard,
    clock: clock,
    adapter: OpenAiCompatibleChatAdapter.withRequest(
      ProcessHttpTransport(
        executable: executable,
        workerPath: workerPath,
        timeout: timeout,
        maxResponseBytes: maxResponseBytes,
      ).request,
    ),
  );

  final Database _db;
  final ColumnCipher _cipher;
  final UrlGuard _guard;
  final Clock _clock;
  final OpenAiCompatibleChatAdapter _adapter;

  Future<Result<ChatCompletion>> chat({
    required String ownerId,
    required AiId ai,
    required List<ChatTurn> turns,
    required String requestId,
    required BudgetLayer layer,
    required TrustedChatContext context,
    int? maxTokens,
    String? expectedProviderId,
    String? expectedModel,
  }) async {
    final config = await BudgetConfiguration.forOwner(
      ownerId: ownerId,
      db: _db,
      clock: _clock,
    ).get(ai);
    if (config case Err<BudgetConfigurationView>(:final failure)) {
      return Err(failure);
    }
    return ModelGateway.forOwner(
      ownerId: ownerId,
      db: _db,
      cipher: _cipher,
      urlGuard: _guard,
      clock: _clock,
      dayForClock: (clock) =>
          BudgetDay.fromClock(clock, offsetMinutes: config.value.offsetMinutes),
      adapter: _adapter,
    ).chat(
      ai,
      turns,
      requestId: requestId,
      layer: layer,
      context: context,
      maxTokens: maxTokens,
      expectedProviderId: expectedProviderId,
      expectedModel: expectedModel,
    );
  }
}
