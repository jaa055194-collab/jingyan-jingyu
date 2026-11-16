import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';

import '../ai/persona/persona_service.dart';
import '../storage/cipher.dart';
import '../storage/database.dart';
import 'model_gateway.dart';
import 'model_runtime.dart';
import 'openai_chat_adapter.dart';

/// Trusted internal runtime boundary. Production uses ModelRuntime.chat; tests
/// may supply a deterministic port without credentials or outbound networking.
typedef StatelessChatPort =
    Future<Result<ChatCompletion>> Function({
      required String ownerId,
      required AiId ai,
      required List<ChatTurn> turns,
      required String requestId,
      required BudgetLayer layer,
      required TrustedChatContext context,
      int? maxTokens,
      String? expectedProviderId,
      String? expectedModel,
    });

/// Bounded stateless owner text capability, NOT consent or a live ACL boundary.
///
/// Trusted callers authenticate the owner, resolve the canonical direct ID and
/// enforce live relationship/visibility/consent checks. This helper rechecks the
/// active owner/persona identity and canonical direct pair, not friendship/block
/// policy. No HTTP, observer, history, memory, group data, persistence or retry.
///
/// Caps are slice engineering limits, not spec/tokenizer/model-window values.
/// Input cap counts both message contents including the separator/persona JSON;
/// encoded cap counts the complete OpenAI-compatible JSON request shape. Output
/// is checked AFTER runtime completion/usage settlement, never rolled back.
final class StatelessOwnerChat {
  StatelessOwnerChat({
    required Database db,
    required ColumnCipher cipher,
    required Clock clock,
    required StatelessChatPort chat,
    this.maxInputBytes = 4096,
    this.maxOutputBytes = 8192,
    this.maxEncodedRequestBytes = 8192,
    this.maxAllowedTokens = 2048,
  }) : _db = db,
       _cipher = cipher,
       _clock = clock,
       _chat = chat;

  factory StatelessOwnerChat.fromRuntime({
    required Database db,
    required ColumnCipher cipher,
    required Clock clock,
    required ModelRuntime runtime,
    int maxInputBytes = 4096,
    int maxOutputBytes = 8192,
    int maxEncodedRequestBytes = 8192,
    int maxAllowedTokens = 2048,
  }) => StatelessOwnerChat(
    db: db,
    cipher: cipher,
    clock: clock,
    chat: runtime.chat,
    maxInputBytes: maxInputBytes,
    maxOutputBytes: maxOutputBytes,
    maxEncodedRequestBytes: maxEncodedRequestBytes,
    maxAllowedTokens: maxAllowedTokens,
  );

  final Database _db;
  final ColumnCipher _cipher;
  final Clock _clock;
  final StatelessChatPort _chat;
  final int maxInputBytes,
      maxOutputBytes,
      maxEncodedRequestBytes,
      maxAllowedTokens;

  Future<Result<ChatCompletion>> chat({
    required String ownerId,
    required AiId ai,
    required String conversationId,
    required String requestId,
    required String system,
    required String input,
    required String expectedProviderId,
    required String expectedModel,
    required int maxTokens,
  }) async {
    Result<ChatCompletion> invalid() => err(
      FailureCode.invalidArgument,
      'Invalid or oversized stateless chat input',
    );
    try {
      validateId(ownerId, kind: 'owner');
      validateId(conversationId, kind: 'direct conversation');
      validateId(requestId, kind: 'request');
    } on FormatException {
      return invalid();
    }
    bool token(String value) =>
        value.isNotEmpty &&
        value.trim() == value &&
        !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value) &&
        _wellFormed(value);
    if (maxInputBytes <= 0 ||
        maxOutputBytes <= 0 ||
        maxEncodedRequestBytes <= 0 ||
        maxAllowedTokens <= 0 ||
        maxTokens <= 0 ||
        maxTokens > maxAllowedTokens ||
        !token(expectedProviderId) ||
        !token(expectedModel) ||
        system.trim().isEmpty ||
        input.trim().isEmpty ||
        !_wellFormed(system) ||
        !_wellFormed(input)) {
      return invalid();
    }
    // Avoid querying persona for already over-limit caller text. No truncation.
    if (utf8.encode(system).length + utf8.encode(input).length >
        maxInputBytes) {
      return invalid();
    }
    final persona = await SqlitePersonaService.forOwner(
      ownerId: ownerId,
      actorAccountId: ownerId,
      database: _db,
      cipher: _cipher,
      clock: _clock,
    ).current(ai);
    if (persona case Err<PersonaCard>(:final failure)) return Err(failure);
    final pair = await _db.query(
      '''
SELECT d.id FROM direct_conversations d
JOIN ai_profile p ON p.id=?
JOIN account a ON a.id=p.account_id AND a.kind='ai' AND a.disabled=0
JOIN ai_operator o ON o.ai_id=a.id AND o.operator_id=?
JOIN account h ON h.id=o.operator_id AND h.kind='human' AND h.disabled=0
WHERE d.id=? AND ((d.account_low=h.id AND d.account_high=a.id)
 OR (d.account_low=a.id AND d.account_high=h.id))
''',
      [ai.value, ownerId, conversationId],
    );
    if (pair.length != 1) {
      return err(FailureCode.notFound, 'Owner direct scope not found');
    }
    final layers = persona.value.layers;
    for (final layer in [layers.p0, layers.p1, layers.p2]) {
      if (layer.entries.any(
        (entry) => !_wellFormed(entry.key) || !_wellFormed(entry.value),
      )) {
        return err(FailureCode.internal, 'Invalid stored persona text');
      }
    }
    final combined =
        '$system\n\nSaved persona (JSON):\n${jsonEncode(layers.toJson())}';
    final turns = List<ChatTurn>.unmodifiable([
      ChatTurn(role: 'system', content: combined),
      ChatTurn(role: 'user', content: input),
    ]);
    if (utf8.encode(combined).length + utf8.encode(input).length >
        maxInputBytes) {
      return invalid();
    }
    final payload = jsonEncode({
      'model': expectedModel,
      'messages': [
        for (final turn in turns) {'role': turn.role, 'content': turn.content},
      ],
      'stream': false,
      'max_tokens': maxTokens,
    });
    if (utf8.encode(payload).length > maxEncodedRequestBytes) return invalid();
    final result = await _chat(
      ownerId: ownerId,
      ai: ai,
      turns: turns,
      requestId: requestId,
      layer: BudgetLayer.b2DeepChat,
      context: TrustedChatContext(
        initiator: AccountId.parse(ownerId),
        conversationKind: ChatConversationKind.private,
        scopeKey: conversationId,
      ),
      maxTokens: maxTokens,
      expectedProviderId: expectedProviderId,
      expectedModel: expectedModel,
    );
    if (result case Err<ChatCompletion>()) return result;
    // Runtime already settled usage when it returned Ok: never retry/undo usage.
    if (!_wellFormed(result.value.text) ||
        utf8.encode(result.value.text).length > maxOutputBytes) {
      return err(
        FailureCode.modelUnavailable,
        'Provider completion unavailable',
      );
    }
    return result;
  }
}

/// Dart UTF8 encoding otherwise silently replaces lone UTF16 surrogates.
bool _wellFormed(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= text.length) return false;
      final low = text.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}
