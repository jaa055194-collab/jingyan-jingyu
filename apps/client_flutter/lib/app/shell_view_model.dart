import 'package:material_ui/material_ui.dart';

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
  // Defaults keep older read-only view-model doubles source-compatible. The
  // runtime overrides all of these.
  List<ShellOwnedAi> get ownAiAccounts => const <ShellOwnedAi>[];
  String? get ownAiNotice => null;
  Object? get ownAiSessionContext => null;
  bool get ownAiLoaded => false;
  Future<void> loadOwnAi() async {}
  Future<void> createOwnAi(String displayName) async {}
  String? get selectedConversationId;
  List<ShellConversation> get conversations;
  List<ShellMessage> get messages;
  int get queuedCount;
  String get draft;
  bool get aiConsentGranted;
  bool get appLockEnabled;
  bool get hideNotificationBody;
  bool get autoStart;
  ThemeMode get themeMode;
  double get fontScale;
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
  Future<void> attachFile(String kind);
  Future<void> setAppLock(bool enabled, String pin);
  Future<void> unlock(String pin);
  Future<void> setHideNotificationBody(bool value);
  Future<void> setAutoStart(bool value);
  Future<void> setThemeMode(ThemeMode value);
  Future<void> setFontScale(double value);
  void clearError();
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
  });
  final String id;
  final String title;
  final String preview;
  final int unread;
  final String kind;
  final String? ownerAccountId;
}

class ShellMessage {
  const ShellMessage({
    required this.id,
    required this.text,
    this.outgoing = false,
    this.status = '已发送',
  });
  final String id;
  final String text;
  final bool outgoing;
  final String status;
}
