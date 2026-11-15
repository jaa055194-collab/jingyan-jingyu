import 'package:material_ui/material_ui.dart';

/// UI-only contract. The runtime owns persistence, network and platform access.
abstract class ShellViewModel extends ChangeNotifier {
  bool get ready;
  bool get busy;
  bool get onboarded;
  bool get locked;
  bool get online;
  String? get error;
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
  Future<void> chooseCharacter(String characterId);
  Future<void> generateRoom(String preset);
  Future<void> confirmRoom();
  Future<void> selectConversation(String id);
  void updateDraft(String value);
  Future<void> sendMessage();
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

class ShellConversation {
  const ShellConversation({
    required this.id,
    required this.title,
    this.preview = '',
    this.unread = 0,
  });
  final String id;
  final String title;
  final String preview;
  final int unread;
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
