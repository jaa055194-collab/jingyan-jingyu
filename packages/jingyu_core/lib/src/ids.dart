/// 全系统标识类型。
///
/// 设计约束（不要改成 `String` 别名或 `int` 主键）：
/// * 客户端与服务端共用同一套解析规则，任何一侧都不能把非法串塞进系统；
/// * 类型不同就不能互相传递，避免"把消息 id 当会话 id"这类串数据缺陷（FR-67）；
/// * 序列化形式就是普通字符串，协议层不需要额外映射。
library;

/// 标识串的合法字符与长度。
///
/// 只用 URL 安全字符，因此可以直接出现在路由路径与查询参数里。
final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// 所有标识的公共父类型。
///
/// 子类都是 `const` 构造，且不暴露未校验的构造入口：唯一的创建路径是
/// [EntityId.parse]（子类各自提供 `parse`）或 [EntityId.newId]。
abstract class EntityId implements Comparable<EntityId> {
  /// 校验并保存标识串。子类请通过 `parse` 使用，不要直接对外暴露。
  const EntityId(this.value);

  /// 未做校验的原始字符串形式。仅在已经通过 `parse` 校验后可信。
  final String value;

  /// 该标识所属实体类型的稳定名字，用于日志、审计与错误信息。
  String get kind;

  @override
  int compareTo(EntityId other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is EntityId &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => value;

  /// 与 [EntityId.parse] 相同，供泛型场景使用。
  static T checked<T extends EntityId>(T Function(String value) parse, String raw) =>
      parse(raw);
}

/// 校验标识串并抛出 [FormatException]。
///
/// 服务端遇到非法标识时统一转成 `400 invalid_argument`，
/// 绝不做"清洗后继续用"的容错。
String validateId(String raw, {String kind = 'id'}) {
  if (!_idPattern.hasMatch(raw)) {
    throw FormatException(
      '$kind 标识非法：只允许 1–64 位字母、数字、下划线与连字符',
      raw,
    );
  }
  return raw;
}

/// 账号标识。人类与 AI 共用同一标识空间（FR-04：AI 是独立 principal）。
class AccountId extends EntityId {
  const AccountId._(super.value);

  /// 校验并构造。
  factory AccountId.parse(String raw) =>
      AccountId._(validateId(raw, kind: 'account'));

  @override
  String get kind => 'account';
}

/// AI 档案标识。与 [AccountId] 不是同一个概念：一个 AI 账号对应一份 AI 档案。
class AiId extends EntityId {
  const AiId._(super.value);

  factory AiId.parse(String raw) => AiId._(validateId(raw, kind: 'ai'));

  @override
  String get kind => 'ai';
}

/// 会话标识。私聊、群聊、话题各有独立会话记录。
class ConversationId extends EntityId {
  const ConversationId._(super.value);

  factory ConversationId.parse(String raw) =>
      ConversationId._(validateId(raw, kind: 'conversation'));

  @override
  String get kind => 'conversation';
}

/// 消息标识。
class MessageId extends EntityId {
  const MessageId._(super.value);

  factory MessageId.parse(String raw) =>
      MessageId._(validateId(raw, kind: 'message'));

  @override
  String get kind => 'message';
}

/// 设备标识。已读位点与 refresh token 都按设备维度记录（FR-06、FR-14）。
class DeviceId extends EntityId {
  const DeviceId._(super.value);

  factory DeviceId.parse(String raw) =>
      DeviceId._(validateId(raw, kind: 'device'));

  @override
  String get kind => 'device';
}

/// 附件标识。媒体本体在宿主硬盘，库里只存索引（FR-62）。
class AttachmentId extends EntityId {
  const AttachmentId._(super.value);

  factory AttachmentId.parse(String raw) =>
      AttachmentId._(validateId(raw, kind: 'attachment'));

  @override
  String get kind => 'attachment';
}
