import 'package:flutter/foundation.dart';

typedef PrivateAiExchange = ({String user, String assistant, int? seq});

/// Android private-chat UI port. In particular, no credential is readable from
/// the view model. Lifecycle and storage are owned by its route.
abstract class AndroidPrivateAiChatPort extends ChangeNotifier {
  String get aiName;
  bool get isCurrent;
  bool get busy;
  bool get online;
  bool get initialized;
  String? get model;
  String? get endpoint;
  String? get personaName;
  String? get personaText;
  int? get personaVersion;
  String? get behaviorSnapshot => null;
  String? get notice;
  bool get keyConfigured;
  bool get syncEnabled;
  List<PrivateAiExchange> get exchanges;

  Future<bool> loadHostProfile();
  Future<bool> configure({
    required String endpoint,
    required String model,
    String? apiKey,
  });
  Future<bool> send(String text);
  Future<void> setSyncEnabled(bool enabled);
  Future<void> sync();
}
