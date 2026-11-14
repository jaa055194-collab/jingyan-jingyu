/// 消息模块：装配 [MessageStore] 并暴露发送与差集路由。
///
/// Membership is required for sending and reading. A missing policy fails closed.
/// Social services register visibility and optional history boundaries.
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'message_store.dart';

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
  MessagesModule({MessageStore? store})
    : _store = store ?? InMemoryMessageStore();

  final MessageStore _store;
  late HostServices _services;

  @override
  String get name => 'messages';

  @override
  Future<void> configure(HostServices services) async {
    _services = services;
    services.provide<MessageStore>(_store, owner: name);
  }

  MembershipCheck get _members =>
      _services.maybeGet<MembershipCheck>() ?? _DenyAll();

  @override
  void mount(Router router) {
    router.post(Routes.messages, _send);
    router.get(Routes.sync, _sync);
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
