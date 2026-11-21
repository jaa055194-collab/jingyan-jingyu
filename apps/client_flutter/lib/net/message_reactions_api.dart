import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// The client only offers and displays these exact spellings. The server still
/// accepts its existing legacy strings; the client does not normalize them.
enum ChatReaction {
  thumbsUp('👍', '点赞'),
  heart('❤️', '喜欢'),
  laugh('😂', '大笑'),
  surprise('😮', '惊讶'),
  sad('😢', '难过'),
  celebrate('🙌', '庆祝');

  const ChatReaction(this.emoji, this.label);

  final String emoji;
  final String label;
}

typedef ReactionCount = ({int count, bool mine});

sealed class ReactionRead {
  const ReactionRead();
}

final class ReactionsLoaded extends ReactionRead {
  ReactionsLoaded(Map<ChatReaction, ReactionCount> counts)
    : counts = Map.unmodifiable(counts);

  final Map<ChatReaction, ReactionCount> counts;

  ReactionCount forChoice(ChatReaction choice) =>
      counts[choice] ?? (count: 0, mine: false);
}

/// Distinct from a successfully read list whose visible counts are empty.
final class ReactionsUnavailable extends ReactionRead {
  const ReactionsUnavailable();
}

sealed class ReactionWrite {
  const ReactionWrite();
}

final class ReactionToggled extends ReactionWrite {
  const ReactionToggled(this.active);

  final bool active;
}

final class ReactionRefused extends ReactionWrite {
  const ReactionRefused();
}

/// The host may already have toggled; repeating POST could undo it.
final class ReactionUnknown extends ReactionWrite {
  const ReactionUnknown();
}

/// A retired selection or another in-flight operation must not show success.
final class ReactionCancelled extends ReactionWrite {
  const ReactionCancelled();
}

class MessageReactionsApi {
  const MessageReactionsApi(this.connection);

  final HostConnection connection;
  static const _maxBytes = 128 * 1024;
  static const _maxRows = 4096;
  static final _choices = {
    for (final choice in ChatReaction.values) choice.emoji: choice,
  };

  String _path(String conversationId, String messageId) => Routes
      .messageReactions
      .replaceFirst(
        '{conversationId}',
        ConversationId.parse(conversationId).value,
      )
      .replaceFirst('{messageId}', MessageId.parse(messageId).value);

  Future<ReactionRead> read(
    String conversationId,
    String messageId, {
    required String ownAccountId,
    HostReadCancellation? cancellation,
  }) async {
    try {
      AccountId.parse(ownAccountId);
      final body = await connection.getBoundedJson(
        _path(conversationId, messageId),
        maxResponseBytes: _maxBytes,
        cancellation: cancellation,
      );
      final rows = body['reactions'];
      if (body.length != 1 || rows is! List || rows.length > _maxRows) {
        return const ReactionsUnavailable();
      }
      final seen = <(String, String)>{};
      final counts = <ChatReaction, ReactionCount>{};
      for (final row in rows) {
        if (row is! Map<String, Object?> || row.length != 2) {
          return const ReactionsUnavailable();
        }
        final account = row['accountId'];
        final emoji = row['emoji'];
        if (account is! String ||
            emoji is! String ||
            emoji.isEmpty ||
            emoji.length > 32) {
          return const ReactionsUnavailable();
        }
        AccountId.parse(account);
        if (!seen.add((account, emoji))) return const ReactionsUnavailable();
        final choice = _choices[emoji];
        if (choice == null) continue;
        final prior = counts[choice];
        counts[choice] = (
          count: (prior?.count ?? 0) + 1,
          mine: prior?.mine == true || account == ownAccountId,
        );
      }
      return ReactionsLoaded(counts);
    } on HostRequestException {
      return const ReactionsUnavailable();
    } on FormatException {
      return const ReactionsUnavailable();
    } on IOException {
      return const ReactionsUnavailable();
    } on TimeoutException {
      return const ReactionsUnavailable();
    } on StateError {
      return const ReactionsUnavailable();
    }
  }

  Future<ReactionWrite> toggle(
    String conversationId,
    String messageId,
    ChatReaction choice,
  ) async {
    final String path;
    try {
      path = _path(conversationId, messageId);
    } on FormatException {
      return const ReactionRefused();
    }
    try {
      final data = await connection.request(
        'POST',
        path,
        body: {'emoji': choice.emoji},
        retryAuthentication: false,
      );
      final active = data['active'];
      return data.length == 2 && data['emoji'] == choice.emoji && active is bool
          ? ReactionToggled(active)
          : const ReactionUnknown();
    } on HostRequestException catch (error) {
      return switch (error.failure.code) {
        FailureCode.invalidArgument ||
        FailureCode.unauthenticated ||
        FailureCode.forbidden ||
        FailureCode.notFound => const ReactionRefused(),
        _ => const ReactionUnknown(),
      };
    } on FormatException {
      return const ReactionUnknown();
    } on IOException {
      return const ReactionUnknown();
    } on TimeoutException {
      return const ReactionUnknown();
    } on StateError {
      return const ReactionUnknown();
    }
  }
}
