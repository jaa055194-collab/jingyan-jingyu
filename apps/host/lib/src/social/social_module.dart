import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_core/jingyu_core.dart';
import '../accounts/db_authenticator.dart';
import '../audit/audit_log.dart';
import '../storage/database.dart';
import 'friendship_routes.dart';
import 'private_conversations.dart';
import 'combined_membership.dart';
import 'private_routes.dart';

import '../messages/messages_module.dart';
import 'conversation_service.dart';
import 'social_routes.dart';

/// The host owns authenticated routes and migration assembly. Registration uses
/// the messages permission abstractions, without coupling social to accounts.
class SocialModule extends HostModule {
  SocialModule({
    required this.conversations,
    this.database,
    this.clock,
    this.direct,
  });
  final ConversationService conversations;
  final PrivateConversations? direct;
  final Database? database;
  final Clock? clock;
  AccountsDomain? _accounts;
  AuditLog? _audit;

  @override
  String get name => 'social';
  @override
  List<String> get dependsOn => [
    'storage',
    'messages',
    if (database != null && clock != null) 'accounts',
  ];

  @override
  Future<void> configure(HostServices services) async {
    final private = direct;
    final db = database;
    final HistoryMembershipCheck membership = private != null && db != null
        ? CombinedMembership(db: db, group: conversations, direct: private)
        : conversations;
    services.provide<MembershipCheck>(membership, owner: name);
    services.provide<HistoryMembershipCheck>(membership, owner: name);
    if (private != null) {
      services.provide<PrivateConversations>(private, owner: name);
    }
    services.provide<ConversationService>(conversations, owner: name);
    _accounts = services.maybeGet<AccountsDomain>();
    _audit = services.maybeGet<AuditLog>();
  }

  @override
  void mount(Router router) {
    mountSocialRoutes(router, conversations);
    final db = database;
    final hostClock = clock;
    final accounts = _accounts;
    final audit = _audit;
    if (db != null && hostClock != null && accounts != null && audit != null) {
      final private = direct;
      if (private != null) {
        mountPrivateRoutes(
          router,
          db: db,
          clock: hostClock,
          accounts: accounts,
          audit: audit,
          direct: private,
        );
      }
      mountFriendshipRoutes(
        router,
        db: db,
        clock: hostClock,
        accounts: accounts,
        audit: audit,
      );
    }
  }
}
