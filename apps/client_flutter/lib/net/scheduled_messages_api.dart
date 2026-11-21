import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

enum ScheduleStatus { pending, delivered, cancelled, expired }

enum ScheduleProblem { refused, unavailable, unknown }

sealed class ScheduleResult {
  const ScheduleResult();
}

final class ScheduleCreated extends ScheduleResult {
  const ScheduleCreated(this.item);
  final ScheduledMessage item;
}

final class ScheduleLoaded extends ScheduleResult {
  const ScheduleLoaded(this.items, {required this.hasMore});
  final List<ScheduledMessage> items;
  final bool hasMore;
}

final class ScheduleCancelled extends ScheduleResult {
  const ScheduleCancelled();
}

final class ScheduleFailure extends ScheduleResult {
  const ScheduleFailure(this.problem);
  final ScheduleProblem problem;

  @override
  bool operator ==(Object other) =>
      other is ScheduleFailure && other.problem == problem;
  @override
  int get hashCode => problem.hashCode;
}

final class ScheduledMessage {
  const ScheduledMessage({
    required this.id,
    required this.conversationId,
    required this.at,
    required this.status,
  });
  final String id;
  final String conversationId;
  final DateTime at;
  final ScheduleStatus status;

  static ScheduledMessage? tryParse(Object? value, String conversationId) {
    if (value is! Map ||
        value.length != 4 ||
        !{
          'id',
          'conversationId',
          'deliverAt',
          'status',
        }.every(value.containsKey)) {
      return null;
    }
    final id = value['id'];
    final group = value['conversationId'];
    final rawAt = value['deliverAt'];
    final rawStatus = value['status'];
    if (id is! String ||
        group is! String ||
        group != conversationId ||
        rawAt is! String ||
        rawStatus is! String) {
      return null;
    }
    try {
      validateId(id, kind: 'scheduledMessage');
      validateId(group, kind: 'conversation');
    } on FormatException {
      return null;
    }
    final at = DateTime.tryParse(rawAt);
    final status = switch (rawStatus) {
      'pending' => ScheduleStatus.pending,
      'delivered' => ScheduleStatus.delivered,
      'cancelled' => ScheduleStatus.cancelled,
      'expired' => ScheduleStatus.expired,
      _ => null,
    };
    if (at == null ||
        !at.isUtc ||
        at.toIso8601String() != rawAt ||
        status == null) {
      return null;
    }
    return ScheduledMessage(
      id: id,
      conversationId: group,
      at: at,
      status: status,
    );
  }
}

/// The existing host contract. All reads are sender-and-conversation-scoped;
/// no body or another account's metadata crosses this adapter.
class ScheduledMessagesApi {
  const ScheduledMessagesApi(this.connection);
  final HostConnection connection;

  static const maxResponseBytes = 64 * 1024;
  static const maxTextBytes = 64 * 1024;

  String _collection(String conversationId) {
    validateId(conversationId, kind: 'conversation');
    return Routes.scheduledMessages.replaceFirst(
      '{conversationId}',
      Uri.encodeComponent(conversationId),
    );
  }

  String _item(String conversationId, String scheduledId) {
    validateId(scheduledId, kind: 'scheduledMessage');
    return Routes.scheduledMessage
        .replaceFirst('{conversationId}', Uri.encodeComponent(conversationId))
        .replaceFirst('{scheduledId}', Uri.encodeComponent(scheduledId));
  }

  Future<ScheduleResult> create(
    String conversationId, {
    required String text,
    required DateTime at,
  }) async {
    final body = {'text': text};
    if (text.trim().isEmpty ||
        body.length != 1 ||
        utf8.encode(jsonEncode(body)).length > maxTextBytes ||
        !at.isUtc ||
        !at.isAfter(DateTime.now().toUtc())) {
      return const ScheduleFailure(ScheduleProblem.refused);
    }
    final String path;
    try {
      path = _collection(conversationId);
    } on FormatException {
      return const ScheduleFailure(ScheduleProblem.refused);
    }
    try {
      final payload = await connection.requestBoundedObject(
        'POST',
        path,
        body: {'kind': 'text', 'body': body, 'deliverAt': at.toIso8601String()},
        maxResponseBytes: maxResponseBytes,
        expectedStatus: 200,
      );
      final item = ScheduledMessage.tryParse(payload, conversationId);
      if (item == null ||
          item.status != ScheduleStatus.pending ||
          item.at != at ||
          payload.length != 4) {
        return const ScheduleFailure(ScheduleProblem.unknown);
      }
      return ScheduleCreated(item);
    } on HostRequestException catch (error) {
      return ScheduleFailure(_problem(error, writing: true));
    } on FormatException {
      return const ScheduleFailure(ScheduleProblem.unknown);
    } on IOException {
      return const ScheduleFailure(ScheduleProblem.unknown);
    } on TimeoutException {
      return const ScheduleFailure(ScheduleProblem.unknown);
    } on StateError {
      return const ScheduleFailure(ScheduleProblem.unknown);
    }
  }

  Future<ScheduleResult> read(String conversationId, {String? knownId}) async {
    final String path;
    final Map<String, String>? query;
    try {
      path = _collection(conversationId);
      query = knownId == null
          ? null
          : {'scheduledId': validateId(knownId, kind: 'scheduledMessage')};
    } on FormatException {
      return const ScheduleFailure(ScheduleProblem.refused);
    }
    try {
      final payload = await connection.requestBoundedObject(
        'GET',
        path,
        query: query,
        maxResponseBytes: maxResponseBytes,
        expectedStatus: 200,
      );
      if (payload.length != 2 ||
          payload['scheduledMessages'] is! List ||
          payload['hasMore'] is! bool ||
          (payload['hasMore'] as bool && knownId != null)) {
        return const ScheduleFailure(ScheduleProblem.unavailable);
      }
      final raw = payload['scheduledMessages'] as List;
      final limit = knownId == null ? 50 : 1;
      if (raw.length > limit || (knownId != null && raw.isEmpty)) {
        return const ScheduleFailure(ScheduleProblem.unavailable);
      }
      final items = <ScheduledMessage>[];
      final ids = <String>{};
      for (final entry in raw) {
        final item = ScheduledMessage.tryParse(entry, conversationId);
        if (item == null ||
            !ids.add(item.id) ||
            (knownId != null && item.id != knownId)) {
          return const ScheduleFailure(ScheduleProblem.unavailable);
        }
        items.add(item);
      }
      return ScheduleLoaded(
        List.unmodifiable(items),
        hasMore: payload['hasMore'] as bool,
      );
    } on HostRequestException catch (error) {
      return ScheduleFailure(_problem(error, writing: false));
    } on FormatException {
      return const ScheduleFailure(ScheduleProblem.unavailable);
    } on IOException {
      return const ScheduleFailure(ScheduleProblem.unavailable);
    } on TimeoutException {
      return const ScheduleFailure(ScheduleProblem.unavailable);
    } on StateError {
      return const ScheduleFailure(ScheduleProblem.unavailable);
    } catch (_) {
      return const ScheduleFailure(ScheduleProblem.unavailable);
    }
  }

  Future<ScheduleResult> cancel(
    String conversationId, {
    required ScheduledMessage item,
  }) async {
    if (item.conversationId != conversationId ||
        item.status != ScheduleStatus.pending) {
      return const ScheduleFailure(ScheduleProblem.refused);
    }
    final String path;
    try {
      path = _item(conversationId, item.id);
    } on FormatException {
      return const ScheduleFailure(ScheduleProblem.refused);
    }
    try {
      final payload = await connection.requestBoundedObject(
        'DELETE',
        path,
        maxResponseBytes: maxResponseBytes,
        expectedStatus: 200,
      );
      return payload.length == 1 && payload['cancelled'] == true
          ? const ScheduleCancelled()
          : const ScheduleFailure(ScheduleProblem.unknown);
    } on HostRequestException catch (error) {
      return ScheduleFailure(_problem(error, writing: true));
    } on FormatException {
      return const ScheduleFailure(ScheduleProblem.unknown);
    } on IOException {
      return const ScheduleFailure(ScheduleProblem.unknown);
    } on TimeoutException {
      return const ScheduleFailure(ScheduleProblem.unknown);
    } on StateError {
      return const ScheduleFailure(ScheduleProblem.unknown);
    }
  }

  static ScheduleProblem _problem(
    HostRequestException error, {
    required bool writing,
  }) => switch (error.failure.code) {
    FailureCode.invalidArgument ||
    FailureCode.unauthenticated ||
    FailureCode.forbidden ||
    FailureCode.notFound => ScheduleProblem.refused,
    _ => writing ? ScheduleProblem.unknown : ScheduleProblem.unavailable,
  };
}
