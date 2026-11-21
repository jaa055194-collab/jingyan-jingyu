import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

sealed class ChatPinsRead {
  const ChatPinsRead();
}

/// Transport returns identifiers only. The caller must intersect this with the
/// current canonical history; pin metadata alone is not source authorization.
final class ChatPinsLoaded extends ChatPinsRead {
  ChatPinsLoaded(Iterable<String> ids) : ids = List.unmodifiable(ids);
  final List<String> ids;
}

/// Denied, disconnected or malformed. None of these confirms an empty list.
final class ChatPinsUnavailable extends ChatPinsRead {
  const ChatPinsUnavailable();
}

/// Unknown means the host may have applied the request without a valid receipt.
/// Cancelled suppresses feedback belonging to a retired chat/view.
enum ChatPinWrite { confirmed, refused, unknown, cancelled }

class ChatPinsApi {
  const ChatPinsApi(this.connection);

  final HostConnection connection;
  static const _maxPins = 50;
  static const _limit = 16 * 1024;

  Future<ChatPinsRead> read(
    String conversationId, {
    HostReadCancellation? cancellation,
  }) async {
    try {
      ConversationId.parse(conversationId);
      final data = await connection.getBoundedJson(
        Routes.conversationPins.replaceFirst(
          '{conversationId}',
          conversationId,
        ),
        maxResponseBytes: _limit,
        cancellation: cancellation,
      );
      final rows = data['pins'];
      if (data.length != 1 || rows is! List || rows.length > _maxPins) {
        return const ChatPinsUnavailable();
      }
      final ids = <String>{};
      for (final row in rows) {
        if (row is! Map<String, Object?> || row.length != 3) {
          return const ChatPinsUnavailable();
        }
        final id = row['messageId'];
        final actor = row['pinnedBy'];
        final at = row['pinnedAt'];
        final time = at is String ? DateTime.tryParse(at) : null;
        if (id is! String ||
            actor is! String ||
            time == null ||
            !time.isUtc ||
            at != time.toIso8601String()) {
          return const ChatPinsUnavailable();
        }
        MessageId.parse(id);
        AccountId.parse(actor);
        if (!ids.add(id)) return const ChatPinsUnavailable();
      }
      return ChatPinsLoaded(ids);
    } on HostRequestException {
      return const ChatPinsUnavailable();
    } on FormatException {
      return const ChatPinsUnavailable();
    } on IOException {
      return const ChatPinsUnavailable();
    } on TimeoutException {
      return const ChatPinsUnavailable();
    } on StateError {
      return const ChatPinsUnavailable();
    }
  }

  Future<ChatPinWrite> setPinned(
    String conversationId,
    String messageId, {
    required bool pinned,
  }) async {
    try {
      ConversationId.parse(conversationId);
      MessageId.parse(messageId);
    } on FormatException {
      return ChatPinWrite.refused;
    }
    try {
      final receipt = await connection.request(
        pinned ? 'POST' : 'DELETE',
        Routes.messagePin
            .replaceFirst('{conversationId}', conversationId)
            .replaceFirst('{messageId}', messageId),
        retryAuthentication: false,
      );
      final valid =
          receipt['pinned'] == pinned &&
          (pinned
              ? receipt.length == 2 && receipt['duplicate'] is bool
              : receipt.length == 1);
      return valid ? ChatPinWrite.confirmed : ChatPinWrite.unknown;
    } on HostRequestException catch (error) {
      return switch (error.failure.code) {
        FailureCode.invalidArgument ||
        FailureCode.unauthenticated ||
        FailureCode.forbidden ||
        FailureCode.notFound => ChatPinWrite.refused,
        _ => ChatPinWrite.unknown,
      };
    } on FormatException {
      return ChatPinWrite.unknown;
    } on IOException {
      return ChatPinWrite.unknown;
    } on TimeoutException {
      return ChatPinWrite.unknown;
    } on StateError {
      return ChatPinWrite.unknown;
    }
  }
}
