/// 消息模块：装配 [MessageStore] 并暴露发送与差集路由。
///
/// Membership is required for sending and reading. A missing policy fails closed.
/// Social services register visibility and optional history boundaries.
library;

import 'dart:async';
import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../audit/audit_log.dart';
import 'attachments.dart';
import 'accepted_message_observer.dart';
import 'blind_index.dart';
import 'favorites.dart';
import 'message_store.dart';
import 'pins.dart';
import 'reactions.dart';
import 'scheduled.dart';
import 'search.dart';

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

/// Trusted composition hook for HTTP sends, called after existing prechecks.
///
/// A successful result must represent an already committed append before it is
/// returned: indexing and accepted-message observers run afterwards. A failure
/// is returned without falling back to the default store. Authorization and
/// transaction ownership remain the caller's responsibility.
typedef IncomingMessageAppend =
    Future<Result<AppendResult>> Function({
      required String conversationId,
      required String senderId,
      required String clientMsgId,
      required MessageKind kind,
      required Map<String, Object?> body,
    });

/// 消息模块。
class MessagesModule extends HostModule {
  MessagesModule({
    MessageStore? store,
    IncomingMessageAppend? appendIncoming,
    Authenticator? authenticate,
    ScheduledMessageService? scheduled,
    ReactionsService? reactions,
    MessageSearchService? search,
    PinsService? pins,
    BlindIndexService? blind,
    FavoritesService? favorites,
    AttachmentService? attachments,
    this.clock = const SystemClock(),
  }) : _store = store ?? InMemoryMessageStore(),
       _appendIncoming = appendIncoming,
       _authenticate = authenticate,
       _scheduled = scheduled,
       _reactions = reactions,
       _searchService = search,
       _pins = pins,
       _blind = blind,
       _favorites = favorites,
       _attachments = attachments;

  final MessageStore _store;
  final IncomingMessageAppend? _appendIncoming;
  final Authenticator? _authenticate;
  final ScheduledMessageService? _scheduled;
  final ReactionsService? _reactions;
  final MessageSearchService? _searchService;
  final PinsService? _pins;
  final BlindIndexService? _blind;
  final FavoritesService? _favorites;
  final AttachmentService? _attachments;
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
    router.get(Routes.search, _search);
    router.post(Routes.favorites, _addFavorite);
    router.get(Routes.favorites, _listFavorites);
    router.delete(Routes.favorite, _removeFavorite);
    router.add('PATCH', Routes.favorite, _updateFavorite);
    router.post(Routes.messagePin, _pin);
    router.delete(Routes.messagePin, _unpin);
    router.get(Routes.conversationPins, _pinsList);
    router.post(Routes.messageAck, _ack);
    router.get(Routes.sync, _sync);
    router.get(
      Routes.messageAttachment,
      (request) => _messageAttachment(request, MessageKind.image),
    );
    router.get(
      Routes.messageVoiceAttachment,
      (request) => _messageAttachment(request, MessageKind.audio),
    );
  }

  /// Message-scoped bounded attachment bytes. Authorization precedes any read:
  /// membership, history floor, then the message, then the attachment. Every
  /// authorization/missing/invalid-content failure is a uniform 404.
  Future<HostResponse> _messageAttachment(
    HostRequest request,
    MessageKind kind,
  ) async {
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
    final notFound = HostResponse.failure(
      const Failure(FailureCode.notFound, 'not visible'),
    );
    if (!await _members.canRead(principal.accountId, conversationId)) {
      return notFound;
    }
    final history = _services.maybeGet<HistoryMembershipCheck>();
    // Byte-serving must fail closed: without the history boundary we cannot
    // prove the message is inside the viewer's visible range.
    if (history == null) return notFound;
    final first = await history.firstVisibleSeq(
      principal.accountId,
      conversationId,
    );
    if (first == null) return notFound;
    final message = await _store.read(
      conversationId: conversationId,
      messageId: messageId,
    );
    if (message.isErr || message.value.seq < first) return notFound;
    final attachments = _attachments;
    if (attachments == null) {
      return HostResponse.failure(
        const Failure(FailureCode.internal, 'attachments unavailable'),
      );
    }
    final stored = message.value;
    final body = stored.body;
    if (body['recalled'] == true || stored.kind != kind) {
      return notFound;
    }
    final attachmentId = body['attachmentId'];
    if (attachmentId is! String) return notFound;
    final readContent = kind == MessageKind.audio
        ? attachments.readVoiceContent
        : attachments.readImageContent;
    final content = await readContent(
      attachmentId: attachmentId,
      conversationId: stored.conversationId,
      senderId: stored.senderId,
    );
    if (content.isErr) return notFound;
    final media = content.value;
    return HostResponse(
      200,
      json: {
        'mime': media.mime,
        'size': media.size,
        'sha256': media.sha256,
        'dataBase64': base64Encode(media.bytes),
      },
      headers: const {
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
      },
    );
  }

  Future<int?> _favoriteVisibility(String owner, String conversationId) async {
    if (!await _members.canRead(owner, conversationId)) return null;
    return _services.maybeGet<HistoryMembershipCheck>()?.firstVisibleSeq(
      owner,
      conversationId,
    );
  }

  Future<HostResponse> _addFavorite(HostRequest request) async {
    final favorites = _favorites;
    final principal = request.principal!;
    if (favorites == null) {
      return HostResponse.failure(
        const Failure(FailureCode.internal, 'favorites unavailable'),
      );
    }
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) {
      return HostResponse.failure(body.failure);
    }
    final json = body.value;
    final kind = json['kind'];
    final tagsRaw = json['tags'];
    const fields = {
      'kind',
      'messageId',
      'conversationId',
      'title',
      'content',
      'tags',
      'note',
    };
    if (kind is! String ||
        json.keys.any((key) => !fields.contains(key)) ||
        json.entries.any(
          (entry) =>
              entry.key != 'tags' &&
              entry.value != null &&
              entry.value is! String,
        ) ||
        (tagsRaw != null &&
            (tagsRaw is! List || tagsRaw.any((tag) => tag is! String)))) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad kind'),
      );
    }
    final List<String>? tags = tagsRaw == null
        ? null
        : (tagsRaw as List).cast<String>();
    final result = await favorites.add(
      ownerAccountId: principal.accountId,
      kind: kind,
      messageId: json['messageId'] is String
          ? json['messageId'] as String
          : null,
      conversationId: json['conversationId'] is String
          ? json['conversationId'] as String
          : null,
      title: json['title'] is String ? json['title'] as String : null,
      content: json['content'] is String ? json['content'] as String : null,
      tags: tags,
      note: json['note'] is String ? json['note'] as String : null,
      firstVisibleSeq: _favoriteVisibility,
    );
    return HostResponse.fromResult(result);
  }

  Future<HostResponse> _listFavorites(HostRequest request) async {
    final favorites = _favorites;
    final principal = request.principal!;
    if (favorites == null) {
      return HostResponse.failure(
        const Failure(FailureCode.internal, 'favorites unavailable'),
      );
    }
    final result = await favorites.list(
      ownerAccountId: principal.accountId,
      firstVisibleSeq: _favoriteVisibility,
    );
    final tag = request.query['tag'];
    if (tag == null) {
      return HostResponse.fromResult(result, (items) => {'favorites': items});
    }
    if (result.isErr) return HostResponse.fromResult(result);
    final needle = tag.toLowerCase();
    final filtered = <Map<String, Object?>>[
      for (final item in result.value)
        if (_favoriteHasTag(item, needle)) item,
    ];
    return HostResponse.ok({'favorites': filtered});
  }

  bool _favoriteHasTag(Map<String, Object?> item, String tag) {
    final tags = item['tags'];
    if (tags is! List) return false;
    return tags.any((value) => value is String && value.toLowerCase() == tag);
  }

  Future<HostResponse> _removeFavorite(HostRequest request) async {
    final favorites = _favorites;
    final principal = request.principal!;
    final favoriteId = request.pathParams['favoriteId']!;
    try {
      validateId(favoriteId, kind: 'favorite');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad id'),
      );
    }
    if (favorites == null) {
      return HostResponse.failure(
        const Failure(FailureCode.internal, 'favorites unavailable'),
      );
    }
    final result = await favorites.remove(
      ownerAccountId: principal.accountId,
      favoriteId: favoriteId,
    );
    return HostResponse.fromResult(result, (_) => {'removed': true});
  }

  Future<HostResponse> _updateFavorite(HostRequest request) async {
    final favorites = _favorites;
    final principal = request.principal!;
    final favoriteId = request.pathParams['favoriteId']!;
    try {
      validateId(favoriteId, kind: 'favorite');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad id'),
      );
    }
    if (favorites == null) {
      return HostResponse.failure(
        const Failure(FailureCode.internal, 'favorites unavailable'),
      );
    }
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) {
      return HostResponse.failure(body.failure);
    }
    final json = body.value;
    final tagsRaw = json['tags'];
    const fields = {'tags', 'note'};
    if (json.keys.any((key) => !fields.contains(key)) ||
        (tagsRaw != null &&
            (tagsRaw is! List || tagsRaw.any((tag) => tag is! String))) ||
        (json['note'] != null && json['note'] is! String)) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad body'),
      );
    }
    final List<String>? tags = tagsRaw == null
        ? null
        : (tagsRaw as List).cast<String>();
    final result = await favorites.updateMeta(
      ownerAccountId: principal.accountId,
      favoriteId: favoriteId,
      tags: tags,
      note: json['note'] is String ? json['note'] as String : null,
    );
    return HostResponse.fromResult(result);
  }

  Future<HostResponse> _pin(HostRequest request) async {
    final pins = _pins;
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
    if (pins == null) {
      return HostResponse.failure(
        const Failure(FailureCode.internal, 'pins unavailable'),
      );
    }
    final result = await pins.pin(
      conversationId: conversationId,
      messageId: messageId,
      accountId: principal.accountId,
    );
    return HostResponse.fromResult(result);
  }

  Future<HostResponse> _unpin(HostRequest request) async {
    final pins = _pins;
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
    if (pins == null) {
      return HostResponse.failure(
        const Failure(FailureCode.internal, 'pins unavailable'),
      );
    }
    final result = await pins.unpin(
      conversationId: conversationId,
      messageId: messageId,
      accountId: principal.accountId,
    );
    return HostResponse.fromResult(result, (_) => {'pinned': false});
  }

  Future<HostResponse> _pinsList(HostRequest request) async {
    final pins = _pins;
    final principal = request.principal!;
    final conversationId = request.pathParams['conversationId']!;
    try {
      validateId(conversationId, kind: 'conversation');
    } on FormatException {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad id'),
      );
    }
    if (pins == null) {
      return HostResponse.failure(
        const Failure(FailureCode.internal, 'pins unavailable'),
      );
    }
    final result = await pins.list(
      conversationId: conversationId,
      accountId: principal.accountId,
    );
    return HostResponse.fromResult(result, (items) => {'pins': items});
  }

  Future<HostResponse> _search(HostRequest request) async {
    final principal = request.principal!;
    final query = request.query['q'];
    if (query == null || query.trim().isEmpty || query.length > 200) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad query'),
      );
    }
    final limit = int.tryParse(request.query['limit'] ?? '50');
    if (limit == null || limit < 1 || limit > 100) {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad limit'),
      );
    }
    final type = request.query['type'] ?? 'message';
    if (type != 'message' && type != 'favorite' && type != 'file') {
      return HostResponse.failure(
        const Failure(FailureCode.invalidArgument, 'bad type'),
      );
    }
    if (type == 'file') {
      final attachments = _attachments;
      if (attachments == null) {
        return HostResponse.failure(
          const Failure(FailureCode.internal, 'attachments unavailable'),
        );
      }
      final result = await attachments.searchOwn(
        ownerAccountId: principal.accountId,
        query: query,
        limit: limit,
      );
      return HostResponse.fromResult(
        result,
        (items) => {'type': 'file', 'hits': items},
      );
    }
    if (type == 'favorite') {
      final favorites = _favorites;
      if (favorites == null) {
        return HostResponse.failure(
          const Failure(FailureCode.internal, 'favorites unavailable'),
        );
      }
      final result = await favorites.search(
        ownerAccountId: principal.accountId,
        query: query,
        limit: limit,
        firstVisibleSeq: _favoriteVisibility,
      );
      return HostResponse.fromResult(
        result,
        (items) => {'type': 'favorite', 'hits': items},
      );
    }
    final search = _searchService;
    if (search == null) {
      return HostResponse.failure(
        const Failure(FailureCode.internal, 'search unavailable'),
      );
    }
    MessageKind? kind;
    final kindRaw = request.query['kind'];
    if (kindRaw != null) {
      kind = MessageKind.tryParse(kindRaw);
      if (kind == null) {
        return HostResponse.failure(
          const Failure(FailureCode.invalidArgument, 'bad kind'),
        );
      }
    }
    DateTime? from;
    DateTime? to;
    final fromRaw = request.query['from'];
    final toRaw = request.query['to'];
    if (fromRaw != null) {
      from = DateTime.tryParse(fromRaw);
      if (from == null) {
        return HostResponse.failure(
          const Failure(FailureCode.invalidArgument, 'bad from'),
        );
      }
    }
    if (toRaw != null) {
      to = DateTime.tryParse(toRaw);
      if (to == null) {
        return HostResponse.failure(
          const Failure(FailureCode.invalidArgument, 'bad to'),
        );
      }
    }
    final members = _members;
    final history = _services.maybeGet<HistoryMembershipCheck>();
    final result = await search.search(
      accountId: principal.accountId,
      query: query,
      canRead: members.canRead,
      firstVisibleSeq: (accountId, conversationId) async {
        if (history != null) {
          return history.firstVisibleSeq(accountId, conversationId);
        }
        return await members.canRead(accountId, conversationId) ? 1 : null;
      },
      senderId: request.query['senderId'],
      kind: kind,
      from: from,
      to: to,
      limit: limit,
    );
    return HostResponse.fromResult(result, (hits) => {'hits': hits});
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

    if (content.containsKey('mentionAccountIds')) {
      final mentions = content['mentionAccountIds'];
      var valid =
          kind == MessageKind.text && mentions is List && mentions.length <= 1;
      if (valid) {
        for (final mention in mentions) {
          try {
            if (mention is! String) {
              valid = false;
              break;
            }
            AccountId.parse(mention);
          } on FormatException {
            valid = false;
            break;
          }
        }
      }
      if (!valid) {
        return HostResponse.failure(
          const Failure(
            FailureCode.invalidArgument,
            'Invalid mention metadata',
          ),
        );
      }
    }

    // A message may reference an attachment (image/file/audio/…). The reference
    // is accepted only for the sender's own attachment uploaded to this same
    // conversation; membership for posting was already checked above.
    final attachmentRef = content['attachmentId'];
    if (attachmentRef != null) {
      if (attachmentRef is! String) {
        return HostResponse.failure(
          const Failure(FailureCode.invalidArgument, 'bad attachmentId'),
        );
      }
      final attachments = _attachments;
      if (attachments == null) {
        return HostResponse.failure(
          const Failure(FailureCode.internal, 'attachments unavailable'),
        );
      }
      final check = await attachments.assertSendable(
        ownerAccountId: principal.accountId,
        attachmentId: attachmentRef,
        conversationId: conversationId,
      );
      if (check.isErr) {
        return HostResponse.failure(check.failureOrNull!);
      }
    }

    final result = await (_appendIncoming ?? _store.append)(
      conversationId: conversationId,
      senderId: principal.accountId,
      clientMsgId: clientMsgId,
      kind: kind,
      body: content.cast<String, Object?>(),
    );
    final blind = _blind;
    if (blind != null && result.isOk) {
      try {
        await blind.indexMessage(
          messageId: result.value.message.messageId,
          conversationId: conversationId,
          body: result.value.message.body,
        );
      } catch (_) {
        // Search indexing must not fail an accepted send; a rebuild can repair it.
      }
    }
    if (result.isOk && !result.value.duplicate) {
      try {
        await _services.maybeGet<AcceptedMessageObserver>()?.onAccepted(
          result.value.message,
        );
      } catch (_) {
        // Input is already committed. Optional local observers cannot undo it.
      }
    }
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
    final newBody = (body.value['body']! as Map).cast<String, Object?>();
    // An edit must not introduce a reference to an attachment the editor could
    // not have sent. Reuse the same send-time check as _send; a body without an
    // attachmentId (including one that removes a reference) keeps old behavior.
    final attachmentRef = newBody['attachmentId'];
    if (attachmentRef != null) {
      if (attachmentRef is! String) {
        return HostResponse.failure(
          const Failure(FailureCode.invalidArgument, 'bad attachmentId'),
        );
      }
      final attachments = _attachments;
      if (attachments == null) {
        return HostResponse.failure(
          const Failure(FailureCode.internal, 'attachments unavailable'),
        );
      }
      final check = await attachments.assertSendable(
        ownerAccountId: principal.accountId,
        attachmentId: attachmentRef,
        conversationId: conversationId,
      );
      if (check.isErr) {
        return HostResponse.failure(
          const Failure(FailureCode.notFound, 'not visible'),
        );
      }
    }
    final result = await _store.edit(
      conversationId: conversationId,
      messageId: messageId,
      senderId: principal.accountId,
      body: newBody,
    );
    if (result.isErr) return HostResponse.failure(result.failureOrNull!);
    final edited = result.value;
    final blind = _blind;
    if (blind != null) {
      try {
        await blind.indexMessage(
          messageId: edited.message.messageId,
          conversationId: conversationId,
          body: edited.message.body,
        );
      } catch (_) {}
    }
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
    final blind = _blind;
    if (blind != null) {
      try {
        await blind.removeMessage(messageId);
      } catch (_) {}
    }
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
    int? firstVisibleSeq;
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
      if (first > 1) firstVisibleSeq = first;
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
        'firstVisibleSeq': ?firstVisibleSeq,
      },
    );
  }
}
