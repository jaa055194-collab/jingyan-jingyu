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
  static const String adminUsage = '$prefix/admin/usage';

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

  /// Current human's explicit ownerTextOnly consent (GET/POST/DELETE), no dispatch.
  static const String ownerAiDirectConsent =
      '$prefix/ai-profiles/{aiId}/direct-conversation';

  /// Current human's owner-scoped contacts list (friends/pending/blocked).
  /// Read-only; never accepts an owner or actor from the request.
  static const String friends = '$prefix/friends';
  static const String friendState = '$prefix/friends/{accountId}';
  static const String friendRequest = '$prefix/friends/{accountId}/requests';
  static const String friendAccept = '$prefix/friends/{accountId}/accept';
  static const String friendDeny = '$prefix/friends/{accountId}/deny';
  static const String friendBlock = '$prefix/friends/{accountId}/block';

  /// Group owner adds an existing account after approving membership.
  static const String conversationMembers =
      '$prefix/conversations/{conversationId}/members';
  static const String groupName = '$prefix/conversations/{conversationId}/name';
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

  /// Original human owner's reply-attempt metadata for an exact source message.
  static const String ownerAiReplyStatus =
      '$prefix/conversations/{conversationId}/messages/{messageId}/owner-reply';

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

  /// Saved provider model catalog discovery; normal body limits, no chat.
  static const String modelProviderModels =
      '$prefix/model-providers/{providerId}/models';
  static const String aiProfileRegister = '$prefix/ai-profiles/register';
  static const String aiProfile = '$prefix/ai-profiles/{aiId}';
  static const String aiBindings = '$prefix/ai-profiles/{aiId}/bindings';
  static const String aiBinding =
      '$prefix/ai-profiles/{aiId}/bindings/{capability}';
  static const String aiBudget = '$prefix/ai-profiles/{aiId}/budget';
  static const String aiUsage = '$prefix/ai-profiles/{aiId}/usage';
  static const String aiUsageTrend = '$prefix/ai-profiles/{aiId}/usage/trend';

  /// Current operator's explicit L0-L4 configuration, not reply authorization.
  static const String aiSocialLevel = '$prefix/ai-profiles/{aiId}/social-level';

  /// Explicit owner persona initialization and CAS-based configuration.
  static const String aiPersona = '$prefix/ai-profiles/{aiId}/persona';
  static const String aiPersonaInitialize =
      '$prefix/ai-profiles/{aiId}/persona/initialize';
  static const String aiPersonaLock = '$prefix/ai-profiles/{aiId}/persona/lock';

  /// Current operator's bounded change history and full-snapshot restoration.
  static const String aiPersonaHistory =
      '$prefix/ai-profiles/{aiId}/persona/history';
  static const String aiPersonaRevert =
      '$prefix/ai-profiles/{aiId}/persona/revert';

  /// WebSocket 长连接（通知与实时事件）。
  static const String stream = '$prefix/stream';

  // ---- M08 voice：音色档案、短期试听票据与 1v1 通话 ----

  /// 某 AI 的音色档案（GET 读取）。
  static const String aiVoiceProfile =
      '$prefix/ai-profiles/{aiId}/voice-profile';

  /// 某 AI 的短期试听/合成会话票据（POST 签发，5 分钟有效）。
  static const String aiVoiceTicket = '$prefix/ai-profiles/{aiId}/voice-ticket';

  /// 创建 1v1 通话（POST）。
  static const String voiceCalls = '$prefix/voice/calls';

  /// 单通通话的状态（GET）。
  static const String voiceCall = '$prefix/voice/calls/{callId}';

  /// 应答通话（POST）。
  static const String voiceCallAnswer = '$prefix/voice/calls/{callId}/answer';

  /// 结束通话（POST）。
  static const String voiceCallEnd = '$prefix/voice/calls/{callId}/end';

  /// 打断当前发言（POST）：取消 LLM、清 TTS 队列、停播并标记截断。
  static const String voiceCallInterrupt =
      '$prefix/voice/calls/{callId}/interrupt';

  // ===== M10 world：街区/房间/形象（仅追加） =====

  /// 房间布局：GET 读取 / PUT 保存（带 expectedVersion 的 CAS）。
  static const String worldSpaceLayout =
      '$prefix/world/spaces/{spaceId}/layout';

  /// 某空间当前 presence 位置快照（2–5Hz 下发由客户端轮询/推送）。
  static const String worldSpacePresence =
      '$prefix/world/spaces/{spaceId}/presence';

  /// 发起拜访（visitorId 取自认证主体；body 含 hostOwnerId/location/邀请 token）。
  static const String worldVisits = '$prefix/world/visits';

  /// 结束拜访。
  static const String worldVisitEnd = '$prefix/world/visits/{visitId}/end';

  /// 寻路超时/卡住回自家。
  static const String worldVisitTimeout =
      '$prefix/world/visits/{visitId}/timeout';

  /// 主人给访客发室内邀请，返回一次性 token。
  static const String worldSpaceInvitations =
      '$prefix/world/spaces/{spaceId}/invitations';

  /// 形象：GET 列表 / POST 登记。
  static const String worldAvatars = '$prefix/world/avatars';

  /// 启用（切换）某形象。
  static const String worldAvatarEnable =
      '$prefix/world/avatars/{avatarId}/enable';

  /// 当前启用形象的 model_id + profile_rev 广播。
  static const String worldAvatarActive = '$prefix/world/avatars/active';

  // ---------------------------------------------------------------------------
  // M12 lifecycle（本切片追加；只新增常量，不改既有路径）
  // ---------------------------------------------------------------------------

  /// 当前账号的配额用量与磁盘状态。
  static const String lifecycleQuota = '$prefix/lifecycle/quota';

  /// 上传预检：配额/磁盘评估并占用一个并发上传名额（返回 permitId）。
  static const String lifecycleUploadPreview =
      '$prefix/lifecycle/uploads/preview';

  /// 上传记用量：释放预检占用的名额并累加已用字节。
  static const String lifecycleUploadCommit =
      '$prefix/lifecycle/uploads/commit';

  /// 导出当前账号数据（JSON 导出内容；文件流接口受限时的替代）。
  static const String lifecycleExport = '$prefix/lifecycle/export';

  /// 导入到当前账号（仅人格 / 人格 + 聊天记录）。
  static const String lifecycleImport = '$prefix/lifecycle/import';

  /// 离开前对象清点（当前账号）。
  static const String lifecycleDepartureSurvey =
      '$prefix/lifecycle/departure/survey';

  /// 离开并生成删除回执（当前账号）。
  static const String lifecycleDepartureReceipt = '$prefix/lifecycle/departure';

  /// 清理策略只读预览（当前账号；将提醒/将过期对象计数，不执行删除）。
  static const String lifecycleCleanupPreview =
      '$prefix/lifecycle/cleanup/preview';

  /// Owner-only consent for report scopes and radio generation.
  static const String creativeOwnerConsent =
      '$prefix/creative/authorizations/{aiId}';

  /// CR-03 关系周报/年报（本人只读，按 owner 过滤）。
  static const String creativeReports = '$prefix/creative/reports';
  static const String creativeReport =
      '$prefix/creative/reports/{aiId}/{kind}/{periodKey}';

  /// CR-07 深夜电台（本人只读，按 owner 过滤）。
  static const String creativeRadio = '$prefix/creative/radio';
  static const String creativeRadioEpisode =
      '$prefix/creative/radio/{aiId}/{dateKey}';
}
