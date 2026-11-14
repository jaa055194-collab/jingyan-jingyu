/// 消息模块：装配 [MessageStore] 并暴露发送与差集路由。
///
/// Membership is required for sending and reading. A missing policy fails closed.
/// Social services register visibility and optional history boundaries.
library;

import 'dart:async';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../audit/audit_log.dart';
import 'message_store.dart';
import 'reactions.dart';
import 'scheduled.dart';

/// 会话成员校验。未登记真实策略时拒绝读取和发送。
abstract class MembershipCheck {
  Future<bool> canPost(String accountId, String conversationId);
  Future<bool> canRead(String accountId, String conversationId);
}

/// Optional server-side lower bound for visible message history.
abstract class HistoryMembershipCheck implements MembershipCheck {
  /// Null means the conversation is not visible; otherwise the first visible seq.
  Future<int?> firstVisibleSeq(String accountId, String conversationId);
}

class _DenyAll implements MembershipCheck {
  @override
  Future<bool> canPost(String accountId, String conversationId) async => false;
  @override
  Future<bool> canRead(String accountId, String conversationId) async => false;
}

/// 消息模块。
class MessagesModule extends HostModule {
  MessagesModule({
    MessageStore? store,
    Authenticator? authenticate,
    ScheduledMessageService? scheduled,
    ReactionsService? reactions,
    this.clock = const SystemClock(),
  }) : _store = store ?? InMemoryMessageStore(),
       _authenticate = authenticate,
       _scheduled = scheduled,
       _reactions = reactions;

  final MessageStore _store;
  final Authenticator? _authenticate;
  final ScheduledMessageService? _scheduled;
  final ReactionsService? _reactions;
  final Clock clock;
  late HostServices _services;
  Timer? _deliveryTimer;

  @override
  String get name => 'messages';

  @override
  Future<void> configure(HostServices services) async {
    _services = services;
    services.provide<MessageStore>(_store, owner: name);
  }

  @override
  Future<void> start() async {
    final scheduled = _scheduled;
    if (scheduled == null) return;
    _deliveryTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      try {
        await scheduled.deliverDue();
      } catch (_) {
        // Delivery failures are retried on the next tick.
      }
    });
  }

  @override
  Future<void> stop() async {
    _deliveryTimer?.cancel();
    _deliveryTimer = null;
  }

  MembershipCheck get _members =>
      _services.maybeGet<MembershipCheck>() ?? _DenyAll();

  @override
  void mount(Router router) {
    router.post(Routes.messages, _send);
    router.post(Routes.messageRecall, _recall);
    router.post(Routes.messageEdit, _edit);
    router.get(Routes.messageEdits, _editHistory, access: Access.admin);
    router.post(Routes.scheduledMessages, _schedule);
    router.delete(Routes.scheduledMessage, _cancelScheduled);
    router.post(Routes.messageReactions, _react);
    router.get(Routes.messageReactions, _reactionsList);
    router.post(Routes.messageAck, _ack);
    router.get(Routes.sync, _sync);
  }

  Future<HostResponse> _react(HostRequest request) async {
    final reactions = _reactions;
    final principal = request.principal!;
    final conversationId = request.pathParams['conversationId']!;
    final messageId = request.pathParams['messageId']!;
    try {
      validateId(conversationId, kind: 'conversation');
      validateId(messageId, kind: 'message');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad id'),
      );
    }
    if (reactions == null) {
      return HostResponse.failure(
        const Failure(FailureCode.internal, 'reactions unavailable'),
      );
    }
    if (!await _members.canPost(principal.accountId, conversationId)) {
      return HostResponse.failure(
        const Failure(FailureCode.notFound, 'not visible'),
      );
    }
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>> || body.value['emoji'] is! String) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad body'),
      );
    }
    final result = await reactions.toggle(
      conversationId: conversationId,
      messageId: messageId,
      accountId: principal.accountId,
      emoji: body.value['emoji']! as String,
    );
    return HostResponse.fromResult(result);
  }

  Future<HostResponse> _reactionsList(HostRequest request) async {
    final reactions = _reactions;
    final principal = request.principal!;
    final conversationId = request.pathParams['conversationId']!;
    final messageId = request.pathParams['messageId']!;
    try {
      validateId(conversationId, kind: 'conversation');
      validateId(messageId, kind: 'message');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad id'),
      );
    }
    if (reactions == null) {
      return HostResponse.failure(
        const Failure(FailureCode.internal, 'reactions unavailable'),
      );
    }
    if (!await _members.canRead(principal.accountId, conversationId)) {
      return HostResponse.failure(
        const Failure(FailureCode.notFound, 'not visible'),
      );
    }
    final result = await reactions.list(
      conversationId: conversationId,
      messageId: messageId,
    );
    return HostResponse.fromResult(
      result,
      (items) => {
        'reactions': [
          for (final item in items)
            {'accountId': item['accountId'], 'emoji': item['emoji']},
        ],
      },
    );
  }

  Future<HostResponse> _schedule(HostRequest request) async {
    final scheduled = _scheduled;
    final principal = request.principal!;
    final conversationId = request.pathParams['conversationId']!;
    try {
      validateId(conversationId, kind: 'conversation');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad id'),
      );
    }
    if (scheduled == null) {
      return HostResponse.failure(
        const Failure(FailureCode.internal, 'scheduled messages unavailable'),
      );
    }
    if (!await _members.canPost(principal.accountId, conversationId)) {
      return HostResponse.failure(
        const Failure(FailureCode.notFound, 'not visible'),
      );
    }
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) {
      return HostResponse.failure(body.failure);
    }
    final json = body.value;
    final kind = json['kind'] is String
        ? MessageKind.tryParse(json['kind']! as String)
        : null;
    final content = json['body'];
    final deliverAt = json['deliverAt'] is String
        ? DateTime.tryParse(json['deliverAt']! as String)
        : null;
    if (kind == null || content is! Map || deliverAt == null) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad body'),
      );
    }
    final result = await scheduled.schedule(
      conversationId: conversationId,
      senderId: principal.accountId,
      kind: kind,
      body: content.cast<String, Object?>(),
      deliverAt: deliverAt,
    );
    return HostResponse.fromResult(result);
  }

  Future<HostResponse> _cancelScheduled(HostRequest request) async {
    final scheduled = _scheduled;
    final principal = request.principal!;
    final conversationId = request.pathParams['conversationId']!;
    final scheduledId = request.pathParams['scheduledId']!;
    try {
      validateId(conversationId, kind: 'conversation');
      validateId(scheduledId, kind: 'scheduledMessage');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad id'),
      );
    }
    if (scheduled == null) {
      return HostResponse.failure(
        const Failure(FailureCode.internal, 'scheduled messages unavailable'),
      );
    }
    final result = await scheduled.cancel(
      conversationId: conversationId,
      scheduledId: scheduledId,
      senderId: principal.accountId,
    );
    return HostResponse.fromResult(result, (_) => {'cancelled': true});
  }

  Future<HostResponse> _send(HostRequest request) async {
    final principal = request.principal!;
    final conversationId = request.pathParams['conversationId']!;
    try {
      validateId(conversationId, kind: 'conversation');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad id'),
      );
    }
    if (!await _members.canPost(principal.accountId, conversationId)) {
      return HostResponse.failure(
        const Failure(FailureCode.notFound, 'not visible'),
      );
    }

    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) {
      return HostResponse.failure(body.failure);
    }
    final json = body.value;
    final clientMsgId = json['clientMsgId'];
    final kindRaw = json['kind'];
    final content = json['body'];
    final kind = kindRaw is String ? MessageKind.tryParse(kindRaw) : null;
    if (clientMsgId is! String || kind == null || content is! Map) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad body'),
      );
    }

    final result = await _store.append(
      conversationId: conversationId,
      senderId: principal.accountId,
      clientMsgId: clientMsgId,
      kind: kind,
      body: content.cast<String, Object?>(),
    );
    return HostResponse.fromResult(
      result,
      (r) => {'duplicate': r.duplicate, 'message': r.message.toPayload()},
    );
  }

  Future<HostResponse> _edit(HostRequest request) async {
    final principal = request.principal!;
    final conversationId = request.pathParams['conversationId']!;
    final messageId = request.pathParams['messageId']!;
    try {
      validateId(conversationId, kind: 'conversation');
      validateId(messageId, kind: 'message');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad id'),
      );
    }
    if (!await _members.canPost(principal.accountId, conversationId)) {
      return HostResponse.failure(
        const Failure(FailureCode.notFound, 'not visible'),
      );
    }
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>> ||
        body.value.length != 1 ||
        body.value['body'] is! Map) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad body'),
      );
    }
    final result = await _store.edit(
      conversationId: conversationId,
      messageId: messageId,
      senderId: principal.accountId,
      body: (body.value['body']! as Map).cast<String, Object?>(),
    );
    if (result.isErr) return HostResponse.failure(result.failureOrNull!);
    final edited = result.value;
    final audit = _services.maybeGet<AuditLog>();
    if (audit != null) {
      try {
        await audit.record(
          AuditEntry(
            at: clock.now(),
            actorId: principal.accountId,
            action: 'message.edit',
            targetKind: 'message',
            targetId: messageId,
            meta: {'editId': edited.editId},
          ),
        );
      } catch (_) {}
    }
    return HostResponse.ok(edited.message.toPayload());
  }

  Future<HostResponse> _editHistory(HostRequest request) async {
    final conversationId = request.pathParams['conversationId']!;
    final messageId = request.pathParams['messageId']!;
    try {
      validateId(conversationId, kind: 'conversation');
      validateId(messageId, kind: 'message');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad id'),
      );
    }
    final result = await _store.editHistory(
      conversationId: conversationId,
      messageId: messageId,
    );
    return HostResponse.fromResult(
      result,
      (versions) => {
        'edits': [
          for (final v in versions)
            {
              'editId': v.editId,
              'editorId': v.editorId,
              'body': v.body,
              'editedAt': v.editedAt.toIso8601String(),
            },
        ],
      },
    );
  }

  Future<HostResponse> _recall(HostRequest request) async {
    final principal = request.principal!;
    final conversationId = request.pathParams['conversationId']!;
    final messageId = request.pathParams['messageId']!;
    try {
      validateId(conversationId, kind: 'conversation');
      validateId(messageId, kind: 'message');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad id'),
      );
    }
    if (!await _members.canPost(principal.accountId, conversationId)) {
      return HostResponse.failure(
        const Failure(FailureCode.notFound, 'not visible'),
      );
    }
    final result = await _store.recall(
      conversationId: conversationId,
      messageId: messageId,
      senderId: principal.accountId,
    );
    if (result.isErr) return HostResponse.failure(result.failureOrNull!);
    final audit = _services.maybeGet<AuditLog>();
    if (audit != null) {
      // The tombstone commit already happened inside the store transaction.
      // Audit is a separate insert sharing the same database; if it fails the
      // recall stays applied, so treat audit failure as non-fatal rather than
      // returning 500 for a mutation that already took effect.
      try {
        await audit.record(
          AuditEntry(
            at: clock.now(),
            actorId: principal.accountId,
            action: 'message.recall',
            targetKind: 'message',
            targetId: messageId,
            meta: {'conversationId': conversationId},
          ),
        );
      } catch (_) {}
    }
    return HostResponse.ok({'recalled': true});
  }

  Future<HostResponse> _ack(HostRequest request) async {
    final authenticate = _authenticate;
    final principal = request.principal;
    if (authenticate == null || principal == null) {
      return HostResponse.failure(
        const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
      );
    }
    final current = await authenticate(request);
    if (current == null ||
        current.accountId != principal.accountId ||
        current.deviceId != principal.deviceId) {
      return HostResponse.failure(
        const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
      );
    }
    final conversationId = request.pathParams['conversationId']!;
    try {
      validateId(conversationId, kind: 'conversation');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad conversation id'),
      );
    }
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>> ||
        body.value.length != 1 ||
        body.value['seq'] is! int ||
        (body.value['seq'] as int) < 0) {
      return HostResponse.failure(
        const Failure(
          FailureCode.invalidArgument,
          'seq must be a nonnegative integer',
        ),
      );
    }
    final history = _services.maybeGet<HistoryMembershipCheck>();
    if (history == null ||
        await history.firstVisibleSeq(current.accountId, conversationId) ==
            null) {
      return HostResponse.failure(
        const Failure(FailureCode.notFound, 'not visible'),
      );
    }
    final seq = await _store.ack(
      conversationId: conversationId,
      deviceId: current.deviceId,
      seq: body.value['seq'] as int,
    );
    return HostResponse.ok({'acknowledgedSeq': seq});
  }

  Future<HostResponse> _sync(HostRequest request) async {
    final principal = request.principal!;
    final conversationId = request.pathParams['conversationId']!;
    if (!await _members.canRead(principal.accountId, conversationId)) {
      return HostResponse.failure(
        const Failure(FailureCode.notFound, 'not visible'),
      );
    }
    final afterSeq = int.tryParse(request.query['afterSeq'] ?? '0');
    final limit = int.tryParse(request.query['limit'] ?? '200');
    if (afterSeq == null || limit == null) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad query'),
      );
    }
    if (afterSeq < 0 || limit <= 0 || limit > 1000) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad query'),
      );
    }
    var visibleAfter = afterSeq;
    final history = _services.maybeGet<HistoryMembershipCheck>();
    if (history != null) {
      final first = await history.firstVisibleSeq(
        principal.accountId,
        conversationId,
      );
      if (first == null) {
        return HostResponse.failure(
          const Failure(FailureCode.notFound, 'not visible'),
        );
      }
      if (first - 1 > visibleAfter) visibleAfter = first - 1;
    }
    final page = await _store.since(
      conversationId: conversationId,
      afterSeq: visibleAfter,
      limit: limit,
    );
    return HostResponse.fromResult(
      page,
      (p) => {
        'messages': [for (final m in p.messages) m.toPayload()],
        'hasMore': p.hasMore,
      },
    );
  }
}
