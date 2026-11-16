import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../accounts/db_authenticator.dart';
import '../social/owner_ai_direct_consent.dart';
import '../storage/database.dart';
import 'owner_reply_attempts.dart';

/// Original human's metadata history, not model-dispatch permission.
///
/// A durable consent tag supplies historical profile/account identity even after
/// revoke, transfer, profile deletion or remap. No source body, prompt or provider
/// credential is selected. `notAttempted` means only no matching ledger row; it
/// does not assert observer eligibility or promise a generated reply.
class OwnerAiReplyStatusModule extends HostModule {
  OwnerAiReplyStatusModule({required this.database});
  final Database database;
  late AccountsDomain _accounts;
  static const _ledger = OwnerReplyAttempts();

  @override
  String get name => 'owner_ai_reply_status';
  @override
  List<String> get dependsOn => const ['storage', 'accounts', 'social'];
  @override
  Future<void> configure(HostServices services) async {
    _accounts = services.get<AccountsDomain>();
  }

  @override
  void mount(Router router) {
    router.get(Routes.ownerAiReplyStatus, _get);
  }

  HostResponse _failure(FailureCode code) =>
      HostResponse.failure(Failure(code, 'Reply status unavailable'));

  Future<HostResponse> _get(HostRequest request) async {
    try {
      final header = request.headers['authorization'] ?? '';
      final bearer = header.startsWith('Bearer ')
          ? header.substring(7).trim()
          : '';
      final scope = await _accounts.scope(bearer);
      final current = scope.isOk ? await _accounts.authenticate(bearer) : null;
      if (current == null ||
          current.accountId != request.principal?.accountId ||
          current.deviceId != request.principal?.deviceId) {
        return _failure(FailureCode.unauthenticated);
      }
      final length = request.headers['content-length'];
      if (request.query.isNotEmpty ||
          request.body != null ||
          (length != null && int.tryParse(length) != 0) ||
          request.headers.containsKey('transfer-encoding')) {
        return _failure(FailureCode.invalidArgument);
      }
      final conversation = request.pathParams['conversationId'] ?? '';
      final source = request.pathParams['messageId'] ?? '';
      try {
        validateId(conversation, kind: 'conversation');
        validateId(source, kind: 'source message');
      } on FormatException {
        return _failure(FailureCode.invalidArgument);
      }
      final digest = sha256.convert(utf8.encode(bearer)).toString();
      return await database.transaction((tx) async {
        // Same-Tx live credential recheck closes auth-to-read revocation gap.
        // Match AccountsDomain semantics: refresh row required, not its expiry.
        final credential = await tx.query(
          '''
SELECT a.kind FROM device d JOIN account a ON a.id=d.account_id
JOIN refresh_token r ON r.device_id=d.id
WHERE d.access_hash=? AND d.id=? AND d.account_id=?
AND d.access_expires>? AND a.disabled=0
''',
          [
            digest,
            current.deviceId,
            current.accountId,
            _accounts.clock.now().toUtc().millisecondsSinceEpoch,
          ],
        );
        if (credential.length != 1) {
          return _failure(FailureCode.unauthenticated);
        }
        if (credential.single['kind'] != 'human') {
          return _failure(FailureCode.notFound);
        }

        final sources = await tx.query(
          '''
SELECT message_id,conversation_id,sender_id,kind FROM messages
WHERE message_id=? AND conversation_id=? AND sender_id=? AND kind='text'
''',
          [source, conversation, current.accountId],
        );
        if (sources.length != 1) return _failure(FailureCode.notFound);
        // Reject ambiguous group/direct IDs; this route is tagged direct only.
        if ((await tx.query('SELECT 1 FROM social_conversations WHERE id=?', [
          conversation,
        ])).isNotEmpty) {
          return _failure(FailureCode.notFound);
        }
        final tag = await OwnerAiDirectConsent.tagInTx(tx, conversation);
        if (tag == null ||
            tag['owner_account_id'] != current.accountId ||
            !await OwnerAiDirectConsent.taggedReadInTx(
              tx,
              tag,
              current.accountId,
            )) {
          return _failure(FailureCode.notFound);
        }
        final profile = tag['ai_profile_id'] as String;
        final aiAccount = tag['ai_account_id'] as String;
        validateId(profile, kind: 'historical AI profile');
        validateId(aiAccount, kind: 'historical AI account');
        final attempt = await _ledger.getForOwnerInTx(
          tx,
          ownerAccountId: current.accountId,
          sourceMessageId: source,
          aiProfileId: profile,
        );
        if (attempt == null) return HostResponse.ok({'status': 'notAttempted'});
        if (attempt.claim.conversationId != conversation ||
            attempt.claim.aiAccountId != aiAccount ||
            attempt.claim.aiProfileId != profile) {
          return _failure(FailureCode.notFound);
        }
        return HostResponse.ok({
          'status': attempt.status.name,
          'sourceMessageId': source,
          if (attempt.replyId != null) 'replyMessageId': attempt.replyId,
          if (attempt.failureCode != null)
            'failureCode': ErrorCode.fromFailure(attempt.failureCode!).wire,
        });
      });
    } catch (_) {
      // No raw exceptions, corrupt enum values, provider prose or body in output.
      return _failure(FailureCode.internal);
    }
  }
}
