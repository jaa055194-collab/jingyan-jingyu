library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// The canonical relationship state between the signed-in account and a target.
///
/// This is a read-only projection of the host friendship authority. It carries
/// no consent capability and performs no mutation.
enum FriendState {
  none('none'),
  outgoingPending('outgoingPending'),
  incomingPending('incomingPending'),
  friends('friends'),
  blocked('blocked');

  const FriendState(this.wire);
  final String wire;

  static FriendState? tryParse(String raw) {
    for (final state in values) {
      if (state.wire == raw) return state;
    }
    return null;
  }
}

/// Typed, read-only access to the host friendship state route.
///
/// Only `GET /friends/{accountId}` is exposed. Request/accept/deny/block writes
/// are intentionally not implemented here. Authentication renewal (bounded
/// one-shot 401 replay) is inherited from [HostConnection].
class FriendsApi {
  FriendsApi(this.connection);

  final HostConnection connection;

  /// Read the canonical relationship state between the caller and [accountId].
  Future<FriendState> state(String accountId) async {
    final AccountId id;
    try {
      id = AccountId.parse(accountId);
    } on FormatException {
      throw const FormatException('账号标识非法');
    }
    try {
      final json = await connection.request(
        'GET',
        Routes.friendState.replaceFirst(
          '{accountId}',
          Uri.encodeComponent(id.value),
        ),
      );
      final raw = json['state'];
      if (raw is! String) throw const FormatException('Invalid state');
      final state = FriendState.tryParse(raw);
      if (state == null) throw const FormatException('Unknown state');
      return state;
    } on FormatException {
      throw const FormatException('好友关系响应无效');
    }
  }
}
