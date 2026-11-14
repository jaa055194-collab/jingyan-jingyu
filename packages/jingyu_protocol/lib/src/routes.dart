/// 路由常量。
///
/// 所有 HTTP 路径集中在此处，客户端与服务端都从这里取，禁止各写字符串字面量。
/// 版本前缀 `/api/v1`：破坏性变更必须抬版本，不允许原地改语义。
library;

/// HTTP/WS 路由表。
abstract final class Routes {
  /// 版本前缀。
  static const String prefix = '/api/v1';

  /// 存活探测（不需要认证）。
  static const String health = '$prefix/health';

  /// 宿主能力与版本。
  static const String hostInfo = '$prefix/host';

  /// 登录（换取设备 token）。
  static const String authLogin = '$prefix/auth/login';

  /// 刷新设备 token。
  static const String authRefresh = '$prefix/auth/refresh';

  /// 当前账号的设备列表。
  static const String authDevices = '$prefix/auth/devices';

  /// 远程下线某设备：`/auth/devices/{deviceId}/revoke`。
  static const String authDeviceRevoke =
      '$prefix/auth/devices/{deviceId}/revoke';

  /// 兑换邀请码创建账号。
  static const String authInviteRedeem = '$prefix/auth/invites/redeem';

  /// Current human operator's AI accounts; no implicit friendship or profile.
  static const String ownAiAccounts = '$prefix/accounts/me/ai';

  /// 管理员账号元数据与账号创建。
  static const String adminAccounts = '$prefix/admin/accounts';

  /// Administrator resets a human account's password; existing sessions are revoked.
  static const String adminAccountPasswordReset =
      '$prefix/admin/accounts/{accountId}/reset-password';

  /// Administrator disables an account; the sole administrator is protected.
  static const String adminAccountDisable =
      '$prefix/admin/accounts/{accountId}/disable';
  /// Bounded administrator audit envelopes; no entry metadata or bodies.
  static const String adminAudit = '$prefix/admin/audit';

  /// 管理员邀请码管理。
  static const String adminInvites = '$prefix/admin/invites';

  /// Revoke an existing invitation by its metadata ID, never its secret code.
  static const String adminInviteRevoke =
      '$prefix/admin/invites/{inviteId}/revoke';

  /// 会话列表。
  static const String conversations = '$prefix/conversations';
  static const String conversationPreferences =
      '$prefix/conversations/{conversationId}/preferences';
  static const String directConversations = '$prefix/direct-conversations';
  static const String friendState = '$prefix/friends/{accountId}';
  static const String friendRequest = '$prefix/friends/{accountId}/requests';
  static const String friendAccept = '$prefix/friends/{accountId}/accept';
  static const String friendDeny = '$prefix/friends/{accountId}/deny';
  static const String friendBlock = '$prefix/friends/{accountId}/block';

  /// Group owner adds an existing account after approving membership.
  static const String conversationMembers =
      '$prefix/conversations/{conversationId}/members';
  static const String groupOwner =
      '$prefix/conversations/{conversationId}/owner';
  static const String groupLeave =
      '$prefix/conversations/{conversationId}/leave';
  static const String groupMember =
      '$prefix/conversations/{conversationId}/members/{accountId}';
  static const String groupAnnouncement =
      '$prefix/conversations/{conversationId}/announcement';
  static const String groupAiWithdraw =
      '$prefix/conversations/{conversationId}/ai/{accountId}/withdraw';
  static const String groupAiSettings =
      '$prefix/conversations/{conversationId}/ai-settings';
  static const String groupAiInterval =
      '$prefix/conversations/{conversationId}/ai/{accountId}/interval';
  static const String groupAiMute =
      '$prefix/conversations/{conversationId}/ai/{accountId}/mute';

  /// Topic metadata references existing group messages; these are not send routes.
  static const String groupTopics =
      '$prefix/conversations/{conversationId}/topics';
  static const String topic = '$prefix/topics/{topicId}';
  static const String topicReferences = '$prefix/topics/{topicId}/references';

  /// 全局消息搜索（服务端按可见性过滤）。
  static const String search = '$prefix/search';

  /// 收藏夹（本人私有）。
  static const String favorites = '$prefix/favorites';
  static const String favorite = '$prefix/favorites/{favoriteId}';

  /// 会话内消息：`/conversations/{conversationId}/messages`。
  static const String messages =
      '$prefix/conversations/{conversationId}/messages';

  /// Per-device message acknowledgement for one conversation.
  static const String messageAck = '$prefix/conversations/{conversationId}/ack';

  /// Emoji reactions on one message (POST toggles, GET lists).
  static const String messageReactions =
      '$prefix/conversations/{conversationId}/messages/{messageId}/reactions';

  /// Pinned messages in one conversation (POST/DELETE one message, GET list).
  static const String messagePin =
      '$prefix/conversations/{conversationId}/messages/{messageId}/pin';
  static const String conversationPins =
      '$prefix/conversations/{conversationId}/pins';

  /// Scheduled messages for one conversation (schedule/cancel are explicit routes).
  static const String scheduledMessages =
      '$prefix/conversations/{conversationId}/scheduled-messages';
  static const String scheduledMessage =
      '$prefix/conversations/{conversationId}/scheduled-messages/{scheduledId}';

  /// Edit one of the caller's own messages; keeps encrypted prior versions.
  static const String messageEdit =
      '$prefix/conversations/{conversationId}/messages/{messageId}/edit';

  /// Admin-only read of encrypted prior versions.
  static const String messageEdits =
      '$prefix/conversations/{conversationId}/messages/{messageId}/edits';

  /// Recall one of the caller's own recent messages.
  static const String messageRecall =
      '$prefix/conversations/{conversationId}/messages/{messageId}/recall';

  /// 单会话差集同步：`/conversations/{conversationId}/sync`。
  static const String sync = '$prefix/conversations/{conversationId}/sync';

  /// 附件上传。
  static const String attachments = '$prefix/attachments';

  /// 分片上传：初始化一次上传会话。
  static const String attachmentUploads = '$prefix/attachments/uploads';

  /// 上传一个分片；[index] 从 0 起按序递增，支持断点续传。
  static const String attachmentUploadChunk =
      '$prefix/attachments/uploads/{uploadId}/chunks/{index}';

  /// 完成上传：校验大小与 sha256，落库并抽取正文。
  static const String attachmentUploadComplete =
      '$prefix/attachments/uploads/{uploadId}/complete';

  /// 单个附件元数据（含可选解密正文）。
  static const String attachment = '$prefix/attachments/{attachmentId}';

  /// 记忆管理。
  static const String memories = '$prefix/memories';

  /// 模型接入配置。
  static const String modelProviders = '$prefix/model-providers';
  static const String modelProvider = '$prefix/model-providers/{providerId}';
  static const String aiProfileRegister = '$prefix/ai-profiles/register';
  static const String aiProfile = '$prefix/ai-profiles/{aiId}';
  static const String aiBindings = '$prefix/ai-profiles/{aiId}/bindings';
  static const String aiBinding =
      '$prefix/ai-profiles/{aiId}/bindings/{capability}';
  static const String aiBudget = '$prefix/ai-profiles/{aiId}/budget';
  static const String aiUsage = '$prefix/ai-profiles/{aiId}/usage';
  static const String aiUsageTrend = '$prefix/ai-profiles/{aiId}/usage/trend';

  /// Explicit owner persona initialization and CAS-based configuration.
  static const String aiPersona = '$prefix/ai-profiles/{aiId}/persona';
  static const String aiPersonaInitialize =
      '$prefix/ai-profiles/{aiId}/persona/initialize';
  static const String aiPersonaLock = '$prefix/ai-profiles/{aiId}/persona/lock';

  /// WebSocket 长连接（通知与实时事件）。
  static const String stream = '$prefix/stream';
}
