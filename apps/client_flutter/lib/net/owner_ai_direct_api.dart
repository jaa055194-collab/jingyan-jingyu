import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// Canonical profile identity resolved from an explicitly selected AI account.
/// Registration does not enable direct conversation consent or model dispatch.
class OwnedAiProfileIdentity {
  const OwnedAiProfileIdentity._({
    required this.profileId,
    required this.accountId,
    required this.ownerAccountId,
  });

  final String profileId;
  final String accountId;
  final String ownerAccountId;

  factory OwnedAiProfileIdentity.fromJson(
    Map<String, Object?> json, {
    required String expectedAccountId,
    required String expectedOwnerAccountId,
  }) {
    try {
      final profile = json['profileId'];
      final account = json['accountId'];
      final owner = json['ownerAccountId'];
      if (json.length != 3 ||
          json.keys.any(
            (key) => !const {
              'profileId',
              'accountId',
              'ownerAccountId',
            }.contains(key),
          ) ||
          profile is! String ||
          account is! String ||
          owner is! String ||
          account != expectedAccountId ||
          owner != expectedOwnerAccountId) {
        throw const FormatException();
      }
      AiId.parse(profile);
      AccountId.parse(account);
      AccountId.parse(owner);
      return OwnedAiProfileIdentity._(
        profileId: profile,
        accountId: account,
        ownerAccountId: owner,
      );
    } on FormatException {
      throw const FormatException('AI档案身份响应无效');
    }
  }
}

/// Immutable consent metadata, not permission to send or invoke a model.
/// AI profile and AI account identifiers remain separate even if equal in value.
class OwnerAiDirectConsentState {
  const OwnerAiDirectConsentState._({
    required this.aiProfileId,
    required this.aiAccountId,
    required this.conversationId,
    required this.enabled,
    required this.revision,
  });

  final String aiProfileId;
  final String aiAccountId;
  final String? conversationId;
  final bool enabled;
  final int revision;
  String get scope => 'ownerTextOnly';

  factory OwnerAiDirectConsentState.fromJson(
    Map<String, Object?> json, {
    required String expectedAiProfileId,
  }) {
    try {
      const fields = {
        'scope',
        'aiProfileId',
        'aiAccountId',
        'conversationId',
        'enabled',
        'revision',
      };
      final profile = json['aiProfileId'];
      final account = json['aiAccountId'];
      final conversation = json['conversationId'];
      final enabled = json['enabled'];
      final revision = json['revision'];
      if (json.length != fields.length ||
          json.keys.any((key) => !fields.contains(key)) ||
          json['scope'] != 'ownerTextOnly' ||
          profile is! String ||
          profile != expectedAiProfileId ||
          account is! String ||
          (conversation != null && conversation is! String) ||
          enabled is! bool ||
          revision is! int ||
          revision < 0) {
        throw const FormatException();
      }
      AiId.parse(profile);
      AccountId.parse(account);
      if (conversation != null) ConversationId.parse(conversation as String);
      // Never-opened consent is the sole null-conversation state. Disabled
      // historical conversations with nonzero revisions remain valid metadata.
      if ((conversation == null && (enabled || revision != 0)) ||
          (conversation != null && revision == 0)) {
        throw const FormatException();
      }
      return OwnerAiDirectConsentState._(
        aiProfileId: profile,
        aiAccountId: account,
        conversationId: conversation as String?,
        enabled: enabled,
        revision: revision,
      );
    } on FormatException {
      // Core ID and JSON parser errors can contain their supplied source.
      throw const FormatException('AI私聊授权响应无效');
    }
  }
}

/// Explicit online GET/open/revoke operations for the existing host contract.
///
/// No UI, queue, polling, local grant or model dispatch is performed. Existing
/// HostConnection authentication renewal is bounded to one 401 replay. No
/// automatic replay is added for conflict, 503, transport or malformed success:
/// an uncertain mutation may already have committed; callers must not silently
/// repeat it or infer that failed parsing means consent remained unchanged.
class OwnerAiDirectApi {
  OwnerAiDirectApi(this.connection);
  final HostConnection connection;

  /// Explicitly register or resolve the profile for a selected owned AI account.
  /// The host operation is idempotent, but no transport/503/parse retry is added.
  Future<OwnedAiProfileIdentity> registerOrResolve(
    String aiAccountId, {
    required String expectedOwnerAccountId,
    bool retryAuthentication = true,
  }) async {
    try {
      AccountId.parse(aiAccountId);
      AccountId.parse(expectedOwnerAccountId);
    } on FormatException {
      throw const FormatException('AI档案身份参数无效');
    }
    try {
      final response = await connection.request(
        'POST',
        Routes.aiProfileRegister,
        body: {'accountId': aiAccountId},
        retryAuthentication: retryAuthentication,
      );
      return OwnedAiProfileIdentity.fromJson(
        response,
        expectedAccountId: aiAccountId,
        expectedOwnerAccountId: expectedOwnerAccountId,
      );
    } on FormatException {
      throw const FormatException('AI档案身份响应无效');
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

  Future<OwnerAiDirectConsentState> read(
    String aiProfileId, {
    bool retryAuthentication = true,
  }) => _request('GET', aiProfileId, retryAuthentication: retryAuthentication);

  Future<OwnerAiDirectConsentState> open(
    String aiProfileId, {
    required int expectedRevision,
    bool retryAuthentication = true,
  }) => _request(
    'POST',
    aiProfileId,
    expectedRevision: expectedRevision,
    retryAuthentication: retryAuthentication,
  );

  Future<OwnerAiDirectConsentState> revoke(
    String aiProfileId, {
    required int expectedRevision,
    bool retryAuthentication = true,
  }) => _request(
    'DELETE',
    aiProfileId,
    expectedRevision: expectedRevision,
    retryAuthentication: retryAuthentication,
  );

  Future<OwnerAiDirectConsentState> _request(
    String method,
    String profile, {
    int? expectedRevision,
    bool retryAuthentication = true,
  }) async {
    try {
      AiId.parse(profile);
      if (expectedRevision != null && expectedRevision < 0) {
        throw const FormatException();
      }
    } on FormatException {
      throw const FormatException('AI私聊授权参数无效');
    }
    try {
      final response = await connection.request(
        method,
        Routes.ownerAiDirectConsent.replaceFirst(
          '{aiId}',
          Uri.encodeComponent(profile),
        ),
        body: expectedRevision == null
            ? null
            : {'expectedRevision': expectedRevision},
        retryAuthentication: retryAuthentication,
      );
      final state = OwnerAiDirectConsentState.fromJson(
        response,
        expectedAiProfileId: profile,
      );
      if (expectedRevision != null) {
        final neverOpenedNoOp =
            method == 'DELETE' &&
            expectedRevision == 0 &&
            state.revision == 0 &&
            state.conversationId == null &&
            !state.enabled;
        if ((!neverOpenedNoOp && state.revision != expectedRevision + 1) ||
            (method == 'POST' && !state.enabled) ||
            (method == 'DELETE' && state.enabled)) {
          throw const FormatException();
        }
      }
      return state;
    } on FormatException {
      throw const FormatException('AI私聊授权响应无效');
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
}
