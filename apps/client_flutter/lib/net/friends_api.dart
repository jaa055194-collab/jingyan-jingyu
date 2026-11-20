library;

import 'dart:async';
import 'dart:io';

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

/// One read-only contact row from `GET /friends`. It carries no consent
/// capability; the host remains the friendship authority.
class FriendContact {
  const FriendContact({
    required this.accountId,
    required this.displayName,
    required this.state,
  });

  final String accountId;
  final String displayName;
  final FriendState state;

  factory FriendContact.fromJson(Object? value) {
    if (value is! Map) throw const FormatException();
    const fields = {'accountId', 'displayName', 'state'};
    final accountId = value['accountId'];
    final displayName = value['displayName'];
    final rawState = value['state'];
    if (value.length != fields.length ||
        value.keys.any((key) => !fields.contains(key)) ||
        accountId is! String ||
        displayName is! String ||
        displayName.trim().isEmpty ||
        displayName.length > 100 ||
        rawState is! String) {
      throw const FormatException();
    }
    AccountId.parse(accountId);
    final state = FriendState.tryParse(rawState);
    // A friend list only contains existing relationships; `none` is not a row.
    if (state == null || state == FriendState.none) {
      throw const FormatException();
    }
    return FriendContact(
      accountId: accountId,
      displayName: displayName,
      state: state,
    );
  }
}

/// Typed access to the host friendship state routes.
///
/// Exposes the list and single-state reads plus explicit request, accept and
/// deny writes. Block/unblock remain outside this adapter. Reads retain the
/// [HostConnection] renewal behavior; invite writes never replay after a 401.
class FriendsApi {
  FriendsApi(this.connection);

  final HostConnection connection;

  /// Read the caller's contacts. Strict DTO: exactly three fields, valid account
  /// id, non-empty display name and a known non-`none` relationship state.
  Future<List<FriendContact>> list() async {
    try {
      final rows = await connection.requestList('GET', Routes.friends);
      return List<FriendContact>.unmodifiable(rows.map(FriendContact.fromJson));
    } on FormatException {
      throw const FormatException('好友列表响应无效');
    } on SocketException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on HttpException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on TimeoutException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    }
  }

  /// Submit an outgoing request; an acknowledgement is not recipient consent.
  Future<void> requestFriend(String accountId) =>
      _writeFriend(Routes.friendRequest, accountId, requireEmpty: true);

  /// Explicitly accept a pending incoming friend request without auto-replay.
  Future<void> acceptFriend(String accountId) =>
      _writeFriend(Routes.friendAccept, accountId);

  /// Explicitly deny a pending incoming friend request.
  Future<void> denyFriend(String accountId) =>
      _writeFriend(Routes.friendDeny, accountId);

  Future<void> _writeFriend(
    String route,
    String accountId, {
    bool requireEmpty = false,
  }) async {
    final AccountId id;
    try {
      id = AccountId.parse(accountId);
    } on FormatException {
      throw const FormatException('账号标识非法');
    }
    try {
      final response = await connection.request(
        'POST',
        route.replaceFirst('{accountId}', Uri.encodeComponent(id.value)),
        retryAuthentication: false,
        allowEmptySuccess: true,
      );
      if (requireEmpty && response.isNotEmpty) throw const FormatException();
    } on FormatException {
      throw const FormatException('好友操作响应无效');
    } on SocketException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on HttpException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on TimeoutException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    }
  }

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
