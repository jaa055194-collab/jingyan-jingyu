import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

sealed class MessageWriteOutcome {
  const MessageWriteOutcome();
}

/// The initiating view is no longer current. Its result must not be shown in
/// another view. A request already sent may still have committed.
final class MessageWriteCancelled extends MessageWriteOutcome {
  const MessageWriteCancelled();
}

final class MessageWriteRejected extends MessageWriteOutcome {
  const MessageWriteRejected();
}

/// The host may have applied the change. Never replay the request automatically.
final class MessageWriteUnknown extends MessageWriteOutcome {
  const MessageWriteUnknown();
}

final class MessageWriteAccepted extends MessageWriteOutcome {
  const MessageWriteAccepted();
}

final class EditAccepted extends MessageWriteOutcome {
  const EditAccepted(this.body);

  final Map<String, Object?> body;
}

/// One-shot writes on the existing host routes, without authentication replay.
class MessageOperationsApi {
  const MessageOperationsApi(this.connection);

  final HostConnection connection;
  static const maxEditTextLength = 4000;

  Future<MessageWriteOutcome> editMessage({
    required MessageEventFrame source,
    required String text,
  }) async {
    final oldText = source.body['text'];
    if (source.seq < 1 ||
        source.kind != MessageKind.text ||
        source.body['recalled'] == true ||
        oldText is! String ||
        text == oldText ||
        text.trim().isEmpty ||
        text.length > maxEditTextLength) {
      return const MessageWriteRejected();
    }
    final body = {...source.body, 'text': text};
    final identity = source.payload()..remove('body');
    return _post(
      Routes.messageEdit,
      conversationId: source.conversationId,
      messageId: source.messageId,
      body: {'body': body},
      parse: (receipt) {
        final stored = receipt['body'];
        if (receipt.length != identity.length + 1 ||
            receipt['seq'] is! int ||
            !identity.entries.every(
              (entry) => receipt[entry.key] == entry.value,
            ) ||
            stored is! Map<String, Object?> ||
            !_sameJson(stored, body)) {
          return const MessageWriteUnknown();
        }
        // Match the exact same row and full JSON body, not only the text.
        return EditAccepted(Map.unmodifiable(stored));
      },
    );
  }

  Future<MessageWriteOutcome> recallMessage({
    required String conversationId,
    required String messageId,
  }) => _post(
    Routes.messageRecall,
    conversationId: conversationId,
    messageId: messageId,
    parse: (receipt) => receipt.length == 1 && receipt['recalled'] == true
        ? const MessageWriteAccepted()
        : const MessageWriteUnknown(),
  );

  Future<MessageWriteOutcome> _post(
    String route, {
    required String conversationId,
    required String messageId,
    Map<String, Object?>? body,
    required MessageWriteOutcome Function(Map<String, Object?>) parse,
  }) async {
    try {
      ConversationId.parse(conversationId);
      MessageId.parse(messageId);
      if (body != null) jsonEncode(body);
    } on FormatException {
      return const MessageWriteRejected();
    } on JsonUnsupportedObjectError {
      return const MessageWriteRejected();
    }
    try {
      final receipt = await connection.request(
        'POST',
        route
            .replaceAll('{conversationId}', Uri.encodeComponent(conversationId))
            .replaceAll('{messageId}', Uri.encodeComponent(messageId)),
        body: body,
        retryAuthentication: false,
      );
      return parse(receipt);
    } on HostRequestException catch (error) {
      return switch (error.failure.code) {
        FailureCode.invalidArgument ||
        FailureCode.unauthenticated ||
        FailureCode.forbidden ||
        FailureCode.notFound => const MessageWriteRejected(),
        _ => const MessageWriteUnknown(),
      };
    } on FormatException {
      return const MessageWriteUnknown();
    } on IOException {
      return const MessageWriteUnknown();
    } on TimeoutException {
      return const MessageWriteUnknown();
    } on StateError {
      return const MessageWriteUnknown();
    }
  }

  static bool _sameJson(Object? left, Object? right) {
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.entries.every(
            (entry) =>
                right.containsKey(entry.key) &&
                _sameJson(entry.value, right[entry.key]),
          );
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var i = 0; i < left.length; i++) {
        if (!_sameJson(left[i], right[i])) return false;
      }
      return true;
    }
    return left.runtimeType == right.runtimeType && left == right;
  }
}
