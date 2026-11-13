/// 消息模块：装配 [MessageStore] 并暴露发送与差集路由。
///
/// 框架阶段的权限检查只做"必须登录"。会话成员校验（FR-22）、拉黑（FR-08）
/// 与可见性由 M04-social 补上，接入点见 [MembershipCheck]。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'message_store.dart';

/// 会话成员校验。默认实现放行；社交模块登记真正实现后自动替换。
abstract class MembershipCheck {
  Future<bool> canPost(String accountId, String conversationId);
  Future<bool> canRead(String accountId, String conversationId);
}

class _AllowAll implements MembershipCheck {
  @override
  Future<bool> canPost(String accountId, String conversationId) async => true;
  @override
  Future<bool> canRead(String accountId, String conversationId) async => true;
}

/// 消息模块。
class MessagesModule extends HostModule {
  MessagesModule({MessageStore? store}) : _store = store ?? InMemoryMessageStore();

  final MessageStore _store;
  late HostServices _services;

  @override
  String get name => 'messages';

  @override
  Future<void> configure(HostServices services) async {
    _services = services;
    services.provide<MessageStore>(_store, owner: name);
  }

  MembershipCheck get _members => _services.maybeGet<MembershipCheck>() ?? _AllowAll();

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
      return HostResponse.failure(const Failure(FailureCode.invalidArgument, 'bad id'));
    }
    if (!await _members.canPost(principal.accountId, conversationId)) {
      return HostResponse.failure(const Failure(FailureCode.notFound, 'not visible'));
    }

    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) return HostResponse.failure(body.failure);
    final json = body.value;
    final clientMsgId = json['clientMsgId'];
    final kindRaw = json['kind'];
    final content = json['body'];
    final kind = kindRaw is String ? MessageKind.tryParse(kindRaw) : null;
    if (clientMsgId is! String || kind == null || content is! Map) {
      return HostResponse.failure(const Failure(FailureCode.invalidArgument, 'bad body'));
    }

    final result = await _store.append(
      conversationId: conversationId,
      senderId: principal.accountId,
      clientMsgId: clientMsgId,
      kind: kind,
      body: content.cast<String, Object?>(),
    );
    return HostResponse.fromResult(result, (r) => {
          'duplicate': r.duplicate,
          'message': r.message.toPayload(),
        });
  }

  Future<HostResponse> _sync(HostRequest request) async {
    final principal = request.principal!;
    final conversationId = request.pathParams['conversationId']!;
    if (!await _members.canRead(principal.accountId, conversationId)) {
      return HostResponse.failure(const Failure(FailureCode.notFound, 'not visible'));
    }
    final afterSeq = int.tryParse(request.query['afterSeq'] ?? '0');
    final limit = int.tryParse(request.query['limit'] ?? '200');
    if (afterSeq == null || limit == null) {
      return HostResponse.failure(const Failure(FailureCode.invalidArgument, 'bad query'));
    }
    final page = await _store.since(conversationId: conversationId, afterSeq: afterSeq, limit: limit);
    return HostResponse.fromResult(page, (p) => {
          'messages': [for (final m in p.messages) m.toPayload()],
          'hasMore': p.hasMore,
        });
  }
}
