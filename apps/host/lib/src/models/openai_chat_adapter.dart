import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';

import '../security/guarded_http.dart';

/// Trusted injection boundary with exactly the guarded transport request shape.
/// Production callers should use [OpenAiCompatibleChatAdapter] with a transport.
typedef GuardedChatRequest =
    Future<Result<GuardedResponse>> Function(
      String method,
      Uri uri, {
      Map<String, String> headers,
      List<int>? body,
    });

final class ChatTurn {
  const ChatTurn({required this.role, required this.content});

  final String role;
  final String content;
}

/// Internal response with validated usage, but not necessarily a usable reply.
sealed class MeteredChatResponse {
  const MeteredChatResponse({
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
  });

  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
}

/// Normalized completion only; no provider response or credential is retained.
final class ChatCompletion extends MeteredChatResponse {
  const ChatCompletion({
    required this.text,
    required super.inputTokens,
    required super.outputTokens,
    required super.totalTokens,
  });

  final String text;
}

/// A blank assistant string conveys usage only and cannot be published.
final class BlankChatReply extends MeteredChatResponse {
  const BlankChatReply._({
    required super.inputTokens,
    required super.outputTokens,
    required super.totalTokens,
  });
}

/// Single non-streaming OpenAI-compatible request. No retry, fallback, binding
/// selection (including chat.fast), or product budget policy belongs here.
final class OpenAiCompatibleChatAdapter {
  OpenAiCompatibleChatAdapter(GuardedHttpTransport transport)
    : _request = transport.request;

  /// Trusted dependency injection; the callback must enforce guarded transport
  /// policy. Intended for offline tests and trusted composition only.
  OpenAiCompatibleChatAdapter.withRequest(GuardedChatRequest request)
    : _request = request;

  final GuardedChatRequest _request;

  /// Strict chat entry point: a reply is required even if usage is known.
  /// Shares the guarded request and parsing path with [chatWithUsage].
  Future<Result<ChatCompletion>> chat({
    required Uri baseUrl,
    required String apiKey,
    required String model,
    required List<ChatTurn> messages,
    int? maxTokens,
  }) async {
    final result = await chatWithUsage(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      messages: messages,
      maxTokens: maxTokens,
    );
    if (result case Err<MeteredChatResponse>(:final failure)) {
      return Err(failure);
    }
    return switch (result.value) {
      ChatCompletion completion => Ok(completion),
      BlankChatReply() => _unavailable(),
    };
  }

  /// Internal trusted gateway entry point. The caller must authenticate owner
  /// access and retrieve the enabled provider credential before calling this.
  /// A successful outcome includes validated usage and may have no reply.
  /// [maxTokens] is an optional explicit request limit, never a default budget.
  /// Valid input performs exactly one guarded request; invalid input performs
  /// none. Transport failures never expose their original message or details.
  Future<Result<MeteredChatResponse>> chatWithUsage({
    required Uri baseUrl,
    required String apiKey,
    required String model,
    required List<ChatTurn> messages,
    int? maxTokens,
  }) async {
    if ((baseUrl.scheme != 'https' && baseUrl.scheme != 'http') ||
        baseUrl.host.isEmpty ||
        baseUrl.userInfo.isNotEmpty ||
        baseUrl.authority.contains('@') ||
        baseUrl.hasQuery ||
        baseUrl.hasFragment ||
        apiKey.isEmpty ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(apiKey) ||
        model.trim().isEmpty ||
        model.trim() != model ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(model) ||
        messages.isEmpty ||
        messages.any(
          (turn) =>
              !const {'system', 'user', 'assistant'}.contains(turn.role) ||
              turn.content.trim().isEmpty,
        ) ||
        (maxTokens != null && maxTokens <= 0)) {
      return err(FailureCode.invalidArgument, 'Invalid chat request');
    }

    try {
      final path = baseUrl.path.replaceFirst(RegExp(r'/+$'), '');
      final endpoint = baseUrl.replace(path: '$path/chat/completions');
      final result = await _request(
        'POST',
        endpoint,
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer $apiKey',
        },
        body: utf8.encode(
          jsonEncode({
            'model': model,
            'messages': [
              for (final turn in messages)
                {'role': turn.role, 'content': turn.content},
            ],
            'stream': false,
            'max_tokens': ?maxTokens,
          }),
        ),
      );
      if (result case Err<GuardedResponse>(:final failure)) {
        return failure.code == FailureCode.forbidden
            ? err(FailureCode.forbidden, 'Provider request blocked')
            : _unavailable();
      }
      final response = result.value;
      if (response.statusCode == 401 || response.statusCode == 403) {
        return err(FailureCode.forbidden, 'Provider authorization failed');
      }
      if (response.statusCode == 429) {
        return err(FailureCode.rateLimited, 'Provider rate limit reached');
      }
      if (response.statusCode != 200) return _unavailable();

      final payload = jsonDecode(utf8.decode(response.body));
      if (payload is! Map<String, dynamic>) return _unavailable();
      final choices = payload['choices'];
      final usage = payload['usage'];
      if (choices is! List || choices.isEmpty || usage is! Map) {
        return _unavailable();
      }
      final choice = choices.first;
      if (choice is! Map) return _unavailable();
      final message = choice['message'];
      if (message is! Map || message['role'] != 'assistant') {
        return _unavailable();
      }
      final text = message['content'];
      final input = usage['prompt_tokens'];
      final output = usage['completion_tokens'];
      final total = usage['total_tokens'];
      if (text is! String ||
          input is! int ||
          input < 0 ||
          output is! int ||
          output < 0 ||
          total is! int ||
          total < 0) {
        return _unavailable();
      }
      // BigInt prevents native integer overflow from validating a false total.
      if (BigInt.from(input) + BigInt.from(output) != BigInt.from(total)) {
        return _unavailable();
      }
      if (text.trim().isEmpty) {
        // Non-text outputs and malformed envelopes are not blank text replies.
        final toolCalls = message['tool_calls'];
        final finishReason = choice['finish_reason'];
        if ((toolCalls != null &&
                (toolCalls is! List || toolCalls.isNotEmpty)) ||
            message['function_call'] != null ||
            message['audio'] != null ||
            (finishReason != null &&
                (finishReason is! String ||
                    finishReason.isEmpty ||
                    finishReason.trim() != finishReason ||
                    finishReason == 'tool_calls' ||
                    finishReason == 'function_call'))) {
          return _unavailable();
        }
        return Ok(
          BlankChatReply._(
            inputTokens: input,
            outputTokens: output,
            totalTokens: total,
          ),
        );
      }
      return Ok(
        ChatCompletion(
          text: text,
          inputTokens: input,
          outputTokens: output,
          totalTokens: total,
        ),
      );
    } catch (_) {
      // Exceptions, JSON fragments, URLs, and upstream error bodies may contain
      // credentials or prompts. Never interpolate or retain them in a Failure.
      return _unavailable();
    }
  }

  Result<T> _unavailable<T>() =>
      err(FailureCode.modelUnavailable, 'Provider chat unavailable');
}
