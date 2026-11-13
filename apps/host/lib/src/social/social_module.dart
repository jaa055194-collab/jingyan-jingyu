import 'package:jingyu_host_kit/jingyu_host_kit.dart';

import '../messages/messages_module.dart';
import 'conversation_service.dart';
import 'social_routes.dart';

/// The host owns authenticated routes and migration assembly. Registration uses
/// the messages permission abstractions, without coupling social to accounts.
class SocialModule extends HostModule {
  SocialModule({required this.conversations});
  final ConversationService conversations;

  @override
  String get name => 'social';
  @override
  List<String> get dependsOn => const ['storage', 'messages'];

  @override
  Future<void> configure(HostServices services) async {
    services.provide<MembershipCheck>(conversations, owner: name);
    services.provide<HistoryMembershipCheck>(conversations, owner: name);
    services.provide<ConversationService>(conversations, owner: name);
  }

  @override
  void mount(Router router) => mountSocialRoutes(router, conversations);
}
