import 'package:material_ui/material_ui.dart';

import '../features/inbox/foreground_message_activity.dart';
import '../net/attachment_api.dart';
import '../net/chat_pins_api.dart';
import '../net/host_connection.dart' show HostReadCancellation;
import '../net/favorites_api.dart' show FavoriteSaveOutcome;
import '../net/message_operations_api.dart'
    show MessageWriteOutcome, MessageWriteCancelled;
import '../net/message_reactions_api.dart';
import '../net/scheduled_messages_scope.dart';

/// UI-only contract. The runtime owns persistence, network and platform access.
abstract class ShellViewModel extends ChangeNotifier {
  bool get ready;
  bool get busy;
  bool get onboarded;

  /// True when an authenticated host session is available.
  bool get authenticated => connectedAccountId != null;

  /// True once the user chose to use chat before optional world setup.
  bool get chatEntered;
  bool get locked;
  bool get online;
  String? get error;

  /// Optional live UI signal, never notification history or an OS capability.
  ForegroundMessageActivity? get foregroundMessageActivity => null;

  // Defaults keep older read-only view-model doubles source-compatible. The
  // runtime overrides all of these.
  List<ShellOwnedAi> get ownAiAccounts => const <ShellOwnedAi>[];
  String? get ownAiNotice => null;
  Object? get ownAiSessionContext => null;
  bool get ownAiLoaded => false;
  Future<void> loadOwnAi() async {}
  Future<void> createOwnAi(String displayName) async {}
  Future<void> removeOwnAi(String accountId) async {}

  /// Opaque runtime-issued session/lock epoch for an explicit confirmation.
  Object? get ownAiDirectContext => null;
  ShellOwnAiDirectState ownAiDirectState(String aiAccountId) =>
      const ShellOwnAiDirectState();
  Future<void> loadOwnAiDirectConsent(String aiAccountId) async {}
  Future<void> setOwnAiDirectConsent(
    String aiAccountId, {
    required String profileId,
    required int expectedRevision,
    required bool enabled,
    required Object interactionContext,
  }) async {}

  /// Conversation id of the user's own AI partner direct chat, or null while
  /// it is unknown. The default takes the first account in [ownAiAccounts]
  /// whose [ownAiDirectState] names a conversation.
  String? get partnerConversationId {
    for (final ai in ownAiAccounts) {
      final id = ownAiDirectState(ai.accountId).conversationId;
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  String? get selectedConversationId;
  List<ShellConversation> get conversations;

  /// False until the first read of the conversation list has finished, even a
  /// failed one, so the UI can tell "loading" apart from "empty".
  bool get conversationsLoaded => true;
  List<ShellMessage> get messages;
  int get queuedCount;
  String get draft;
  bool get aiConsentGranted;
  bool get appLockEnabled;
  bool get hideNotificationBody;
  bool get autoStart;
  ThemeMode get themeMode;
  double get fontScale;

  /// Reduce-motion preference; when true the shell also turns off Material's
  /// own animations.
  bool get reduceMotion => false;
  Future<void> setReduceMotion(bool value) async {}
  String? get roomPreview;
  String? get connectedAccountId => null;
  Future<void> connectHost(
    String address,
    String invite, {
    String displayName = '',
    String password = '',
    String deviceName = '',
    String accountId = '',
  });

  /// Enter the existing chat shell without completing world setup.
  Future<void> enterChat();
  Future<void> chooseCharacter(String characterId);
  Future<void> generateRoom(String preset);
  Future<void> confirmRoom();
  Future<void> selectConversation(String id);
  Future<void> createGroup(String name);
  Future<void> refreshConversations();

  /// Checks current visibility and consent for this shortcut without sending.
  Future<OwnAiChatEntry> checkOwnAiChatEntry(String aiAccountId) async =>
      OwnAiChatEntry.unavailable;
  Future<void> addGroupMember(String groupId, String accountId);
  bool get canAddMembersToSelectedGroup;
  void updateDraft(String value);
  Future<void> sendMessage();
  bool get canMentionAi;
  Future<void> sendMentionedMessage({
    required String conversationId,
    required String expectedDraft,
    required String aiAccountId,
  });
  Future<void> setAiConsent(bool allowed);

  /// Open the picker and stage a selection without uploading it.
  Future<void> attachFile(String kind);

  /// Basename of the attachment staged for the current conversation, if any.
  String? get selectedAttachmentName => null;
  Future<void> sendSelectedAttachment() async {}
  Future<void> discardSelectedAttachment() async {}

  /// The persisted/visible draft for a conversation, without changing selection.
  String draftFor(String conversationId) => '';

  /// Present only for an authenticated, online, unlocked current group chat.
  /// Captured at route open; every read and write rechecks this same scope.
  ScheduledMessagesScope? scheduledMessagesScope(String conversationId) => null;

  /// A transient OS-shared text value; never includes native intent fields.
  ShellIncomingShare? get incomingSharedText => null;
  String? get incomingShareNotice => null;

  /// Changes whenever a pending share or its authenticated target is invalidated.
  Object? get shareInteractionContext => null;

  Future<bool> useSharedTextInDraft(
    String conversationId, {
    required Object interactionContext,
  }) async => false;

  Future<void> discardSharedText() async {}

  /// Explicitly opens the image referenced by a canonical message. Returns
  /// null when the request is stale, refused or unavailable; never throws.
  Future<MessageImage?> openImageAttachment(String messageId) async => null;

  /// A pin for one authenticated, unlocked chat selection. Old controls must
  /// present the context originally rendered, not capture a new one on tap.
  Object? get messageFavoriteContext => null;

  /// An in-memory duplicate guard, not a claim that the host saved the row.
  bool hasSubmittedMessageFavorite(String messageId) => false;

  Future<FavoriteSaveOutcome> saveMessageFavorite({
    required String conversationId,
    required String messageId,
    required Object expectedContext,
    required bool Function() viewIsCurrent,
  }) async => FavoriteSaveOutcome.cancelled;

  bool get supportsVoicePlayback => false;
  ShellVoicePlayback? get voicePlayback => null;

  /// True when host-backed message operations (edit/recall) can be issued for the
  /// current authenticated, unlocked, online chat session.
  bool get messageOperationsAvailable => false;

  /// Opaque session/selection epoch. A control must pass the context it was
  /// rendered with; the runtime refuses a stale confirmation.
  Object? get messageOperationsContext => null;

  bool get supportsChatPins => false;

  /// Host-confirmed pin IDs intersected with this selection's live history.
  Future<ChatPinsRead> readChatPins({
    required String conversationId,
    required Object expectedContext,
    required bool Function() viewIsCurrent,
    HostReadCancellation? cancellation,
  }) async => const ChatPinsUnavailable();

  Future<ChatPinWrite> setMessagePinned({
    required String conversationId,
    required String messageId,
    required bool pinned,
    required Object expectedContext,
    required bool Function() viewIsCurrent,
  }) async => ChatPinWrite.cancelled;

  bool get supportsMessageReactions => false;

  /// Only fixed aggregate counts and the current account's active state cross
  /// into the view. The selection, row and route must all still be current.
  Future<ReactionRead> readMessageReactions({
    required String conversationId,
    required String messageId,
    required Object expectedContext,
    required bool Function() viewIsCurrent,
    HostReadCancellation? cancellation,
  }) async => const ReactionsUnavailable();

  Future<ReactionWrite> toggleMessageReaction({
    required String conversationId,
    required String messageId,
    required ChatReaction choice,
    required Object expectedContext,
    required bool Function() viewIsCurrent,
  }) async => const ReactionCancelled();

  /// Replaces one own message body. The runtime validates the current session,
  /// selection and canonical row again before any request.
  Future<MessageWriteOutcome> editMessage({
    required String conversationId,
    required String messageId,
    required String expectedText,
    required String text,
    required Object expectedContext,
    required bool Function() viewIsCurrent,
  }) async => const MessageWriteCancelled();

  /// Recalls one own message inside the host's 24h window.
  Future<MessageWriteOutcome> recallMessage({
    required String conversationId,
    required String messageId,
    required Object expectedContext,
    required bool Function() viewIsCurrent,
  }) async => const MessageWriteCancelled();

  /// Starts one explicit play for a visible, sent voice message. The pane
  /// supplies its current-route check and, when present, its frame barrier.
  Future<void> playVoiceMessage(
    String messageId, {
    required bool Function() viewIsCurrent,
    Future<void> Function()? waitForView,
  }) async {}

  /// The pane can stop only playback it started, including when it is removed.
  void stopVoicePlayback({bool Function()? viewIsCurrent}) {}

  Future<void> setAppLock(bool enabled, String pin);
  Future<void> unlock(String pin);
  Future<void> setHideNotificationBody(bool value);
  Future<void> setAutoStart(bool value);
  Future<void> setThemeMode(ThemeMode value);
  Future<void> setFontScale(double value);
  void clearError();
}

enum ShellVoicePhase { loading, playing, denied, unavailable }

class ShellVoicePlayback {
  const ShellVoicePlayback(this.messageId, this.phase);

  final String messageId;
  final ShellVoicePhase phase;
}

enum OwnAiChatEntry {
  ready,
  busy,
  unavailable,
  notVisible,
  consentChanged,
  cancelled,
}

enum ShellOwnAiDirectPhase { unknown, loading, ready, uncertain }

/// Missing/uncertain state is not an explicit off grant. UI must check phase
/// and obtain a fresh runtime-issued context before an explicit CAS mutation.
class ShellOwnAiDirectState {
  const ShellOwnAiDirectState({
    this.phase = ShellOwnAiDirectPhase.unknown,
    this.profileId,
    this.revision,
    this.enabled,
    this.conversationId,
    this.notice,
  });
  final ShellOwnAiDirectPhase phase;
  final String? profileId;
  final int? revision;
  final bool? enabled;
  final String? conversationId;
  final String? notice;
}

class ShellIncomingShare {
  const ShellIncomingShare({required this.text});

  final String text;
}

class ShellOwnedAi {
  const ShellOwnedAi({
    required this.accountId,
    required this.displayName,
    required this.disabled,
  });
  final String accountId;
  final String displayName;
  final bool disabled;
}

class ShellConversation {
  const ShellConversation({
    required this.id,
    required this.title,
    this.preview = '',
    this.unread = 0,
    this.kind = 'unknown',
    this.ownerAccountId,
    this.lastActivityAt,
  });
  final String id;
  final String title;
  final String preview;
  final int unread;
  final String kind;
  final String? ownerAccountId;

  /// Latest known activity, for the row's time label; null without data.
  final DateTime? lastActivityAt;
}

class ShellMessage {
  const ShellMessage({
    required this.id,
    required this.text,
    this.outgoing = false,
    this.status = '已发送',
    this.attachmentId,
    this.attachmentName,
    this.imageAttachment = false,
    this.voiceAttachment = false,
    this.favoriteEligible = false,
    this.copyText,
    this.sentAt,
    this.edited = false,
    this.recalled = false,
    this.operationEligible = false,
  });
  final String id;
  final String text;
  final bool outgoing;
  final String status;

  /// Canonical synced message only: outbox/dropped rows never carry a ref.
  final String? attachmentId;
  final String? attachmentName;
  final bool imageAttachment;
  final bool voiceAttachment;

  /// Set only for a canonical synced row without a recall marker.
  final bool favoriteEligible;

  /// Exact text of a live canonical text message; never a display label.
  final String? copyText;
  final DateTime? sentAt;

  /// Locally confirmed edit by this device for a canonical row.
  final bool edited;

  /// Recalled rows render a placeholder only; their body has no plaintext.
  final bool recalled;

  /// Runtime says this canonical row is visible and actionable in the current
  /// session. UI still checks the per-action preconditions.
  final bool operationEligible;

  bool get canEdit => operationEligible && outgoing && canCopy;

  /// Client-side preview of the host's 24h window; the host stays authoritative.
  bool get canRecall =>
      operationEligible &&
      outgoing &&
      !recalled &&
      sentAt != null &&
      DateTime.now().difference(sentAt!) <= const Duration(hours: 24);

  bool get canCopy => !recalled && copyText?.trim().isNotEmpty == true;
}
