import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/brain/owner_ai_reply_status_module.dart';
import 'package:jingyu_host/src/brain/owner_reply_attempts.dart';
import 'package:jingyu_host/src/brain/owner_reply_attempts_migration.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/social/owner_ai_direct_consent.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

import 'owner_ai_direct_consent_test.dart' show consentMigrations;

class _FastHasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String value) async => 'test:$value';
  @override
  Future<bool> verifyAsync(String value, String encoded) async =>
      encoded == 'test:$value';
}

class _ObservedDatabase implements Database {
  _ObservedDatabase(this.inner);
  final Database inner;
  final queries = <String>[];
  bool failReads = false;
  Future<void> Function()? beforeTransaction;
  @override
  Future<T> transaction<T>(Future<T> Function(Tx) body) async {
    await beforeTransaction?.call();
    return inner.transaction((tx) => body(_ObservedTx(this, tx)));
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) => throw StateError('status must only use supplied Tx');
  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) =>
      throw StateError('status must not write');
  @override
  Future<int> schemaVersion() => inner.schemaVersion();
  @override
  Future<String> integrityCheck() => inner.integrityCheck();
}

class _ObservedTx implements Tx {
  _ObservedTx(this.db, this.tx);
  final _ObservedDatabase db;
  final Tx tx;
  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) {
    db.queries.add(sql);
    if (db.failReads) throw StateError('PRIVATE_BODY_OR_KEY_SENTINEL');
    if (RegExp(
      r'\bbody\b|\bprovider\b|\bapi_key\b',
      caseSensitive: false,
    ).hasMatch(sql)) {
      throw StateError('unexpected content read');
    }
    return tx.query(sql, args);
  }

  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) =>
      throw StateError('status must not write in Tx');
}

void main() {
  late Directory dir;
  late SqliteDatabase db;
  late _ObservedDatabase observed;
  late AccountsDomain accounts;
  late OwnerAiReplyStatusModule module;
  late OwnerAiDirectConsent consent;
  late Pipeline pipeline;
  late Router router;
  late AccountId owner, other, ai;
  late String token, otherToken, conversation;
  late Principal principal;
  final clock = FakeClock(DateTime.utc(2026, 11, 17));
  const ledger = OwnerReplyAttempts();
  const profile = 'historical-profile';
  const source = 'source-message';
  const secret = 'status-test-password';

  String path({String? conv, String message = source}) => Routes
      .ownerAiReplyStatus
      .replaceFirst('{conversationId}', conv ?? conversation)
      .replaceFirst('{messageId}', message);
  Future<HostResponse> get({
    String? bearer,
    Pipeline? through,
    String? route,
    Object? body,
    Map<String, String> query = const {},
    Map<String, String> headers = const {},
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: 'GET',
      path: route ?? path(),
      headers: {'authorization': 'Bearer ${bearer ?? token}', ...headers},
      body: body,
      query: query,
    ),
  );
  Future<void> claim() => db.transaction((tx) async {
    expect(
      await ledger.claimInTx(
        tx,
        claim: OwnerReplyAttemptClaim(
          sourceMessageId: source,
          aiProfileId: profile,
          ownerAccountId: owner.value,
          aiAccountId: ai.value,
          conversationId: conversation,
          grantRevision: 1,
          requestId: 'request-1',
        ),
      ),
      isTrue,
    );
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('owner-reply-status-');
    db = await SqliteDatabase.open(
      '${dir.path}/host.sqlite',
      migrations: [
        ...consentMigrations,
        ...messagesMigrations,
        ownerReplyAttemptsMigration,
      ],
    );
    observed = _ObservedDatabase(db);
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    owner = (await accounts.bootstrapAdmin(
      displayName: 'owner',
      password: secret,
    )).value;
    final login = (await accounts.login(
      owner,
      secret,
      deviceName: 'owner-device',
    )).value;
    token = login.accessToken;
    principal = (await accounts.authenticate(token))!;
    final session = (await accounts.scope(token)).value;
    other = (await session.accounts.createHuman(
      displayName: 'other',
      password: secret,
    )).value;
    otherToken = (await accounts.login(
      other,
      secret,
      deviceName: 'other-device',
    )).value.accessToken;
    ai = (await session.accounts.createAi(
      operator: owner,
      displayName: 'AI',
    )).value;
    await db.execute('INSERT INTO ai_profile(id,account_id) VALUES(?,?)', [
      profile,
      ai.value,
    ]);
    consent = OwnerAiDirectConsent(database: db, clock: clock);
    conversation =
        (await consent.open(
              ownerId: owner.value,
              aiProfileId: profile,
              expectedRevision: 0,
            )).value['conversationId']
            as String;
    await db.execute(
      '''INSERT INTO messages(message_id,conversation_id,seq,sender_id,
client_msg_id,kind,body,sent_at) VALUES(?,?,1,?,'source-client','text',?,?)''',
      [
        source,
        conversation,
        owner.value,
        'PRIVATE_BODY_OR_KEY_SENTINEL',
        clock.now().toIso8601String(),
      ],
    );
    module = OwnerAiReplyStatusModule(database: observed);
    await module.configure(
      HostServices()..provide<AccountsDomain>(accounts, owner: 'accounts'),
    );
    router = Router();
    module.mount(router);
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(accounts).call,
    );
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test(
    'eligible exact source without attempt returns notAttempted and performs only metadata reads',
    () async {
      final before = await db.query('SELECT * FROM owner_ai_direct_grants');
      final result = await get();
      expect(result.status, 200);
      expect(result.json, {'status': 'notAttempted'});
      expect(await db.query('SELECT * FROM owner_reply_attempts'), isEmpty);
      expect(await db.query('SELECT * FROM owner_ai_direct_grants'), before);
      expect(observed.queries, isNotEmpty);
      expect(module.name, 'owner_ai_reply_status');
      expect(module.dependsOn, ['storage', 'accounts', 'social']);
    },
  );

  for (final status in OwnerReplyAttemptStatus.values) {
    test('returns exact safe ${status.name} projection', () async {
      await claim();
      if (status != OwnerReplyAttemptStatus.pending) {
        await db.transaction(
          (tx) => ledger.finishInTx(
            tx,
            ownerAccountId: owner.value,
            sourceMessageId: source,
            aiProfileId: profile,
            requestId: 'request-1',
            status: status,
            replyId: status == OwnerReplyAttemptStatus.completed
                ? 'reply-message'
                : null,
            failureCode: status == OwnerReplyAttemptStatus.failed
                ? FailureCode.modelUnavailable
                : null,
          ),
        );
      }
      final result = await get();
      expect(result.status, 200);
      expect(result.json, {
        'status': status.name,
        'sourceMessageId': source,
        if (status == OwnerReplyAttemptStatus.completed)
          'replyMessageId': 'reply-message',
        if (status == OwnerReplyAttemptStatus.failed)
          'failureCode': 'model_unavailable',
      });
      expect(
        jsonEncode(result.json),
        isNot(contains('PRIVATE_BODY_OR_KEY_SENTINEL')),
      );
    });
  }

  test(
    'revoke and transfer retain original owner metadata but deny new owner and AI',
    () async {
      await claim();
      await consent.revoke(
        ownerId: owner.value,
        aiProfileId: profile,
        expectedRevision: 1,
      );
      await db.execute('UPDATE ai_operator SET operator_id=? WHERE ai_id=?', [
        other.value,
        ai.value,
      ]);
      expect((await get()).status, 200);
      expect((await get(bearer: otherToken)).status, 404);
      // AI credential deliberately seeded: test handler policy even with valid auth.
      final aiDevice = 'ai-device';
      await accounts.store.transaction((state) {
        state.devices[aiDevice] = {
          ...state.devices[principal.deviceId]!,
          'id': aiDevice,
          'account': ai.value,
        };
        state.devices.remove(principal.deviceId);
        return null;
      });
      expect((await get()).status, 404);
    },
  );

  test(
    'profile deletion or remap does not remove original owner history',
    () async {
      await claim();
      await db.execute('DELETE FROM ai_profile WHERE id=?', [profile]);
      expect((await get()).status, 200);
      await db.execute('INSERT INTO ai_profile(id,account_id) VALUES(?,?)', [
        profile,
        other.value,
      ]);
      expect((await get()).status, 200);
    },
  );

  test('edited and recalled source retains metadata history', () async {
    await claim();
    await db.execute(
      'UPDATE messages SET body=?,recalled_at=? WHERE message_id=?',
      ['unreadable-content', clock.now().toIso8601String(), source],
    );
    expect((await get()).status, 200);
  });

  test(
    'unknown/foreign source, wrong conversation, untagged direct, group return 404',
    () async {
      expect((await get(route: path(message: 'unknown'))).status, 404);
      expect((await get(bearer: otherToken)).status, 404);
      expect((await get(route: path(conv: 'wrong-conversation'))).status, 404);
      await db.execute('UPDATE messages SET sender_id=? WHERE message_id=?', [
        ai.value,
        source,
      ]);
      expect((await get()).status, 404);
      await db.execute('UPDATE messages SET sender_id=? WHERE message_id=?', [
        owner.value,
        source,
      ]);
      await db.execute(
        '''INSERT INTO social_conversations
(id,owner_account_id,name,history_visibility,created_at) VALUES(?,?,?,'all',0)''',
        [conversation, owner.value, 'group/direct collision'],
      );
      expect((await get()).status, 404);
      await db.execute('DELETE FROM social_conversations WHERE id=?', [
        conversation,
      ]);
      await db.execute('DELETE FROM owner_ai_direct_grants');
      expect((await get()).status, 404);
      await db.execute('DELETE FROM direct_conversations');
      expect((await get()).status, 404);
    },
  );

  test('non-text source and noncanonical tagged pair return 404', () async {
    await db.execute("UPDATE messages SET kind='image' WHERE message_id=?", [
      source,
    ]);
    expect((await get()).status, 404);
    await db.execute("UPDATE messages SET kind='text' WHERE message_id=?", [
      source,
    ]);
    final wrongPair = [owner.value, other.value]..sort();
    await db.execute(
      'UPDATE direct_conversations SET account_low=?,account_high=? WHERE id=?',
      [...wrongPair, conversation],
    );
    expect((await get()).status, 404);
  });

  test('ledger identity mismatch does not leak status', () async {
    await claim();
    for (final field in ['conversation_id', 'ai_account_id']) {
      final original = field == 'conversation_id' ? conversation : ai.value;
      await db.execute('UPDATE owner_reply_attempts SET $field=?', [
        'wrong-id',
      ]);
      expect((await get()).status, 404);
      await db.execute('UPDATE owner_reply_attempts SET $field=?', [original]);
    }
  });

  test(
    'stale, mismatched account/device, expired and revoked credentials return 401',
    () async {
      final cached = Pipeline(
        router: router,
        authenticate: (_) async => principal,
      );
      expect((await get(bearer: otherToken, through: cached)).status, 401);
      final another = (await accounts.login(
        owner,
        secret,
        deviceName: 'second-device',
      )).value;
      expect(
        (await get(bearer: another.accessToken, through: cached)).status,
        401,
      );
      await db.execute('UPDATE device SET access_expires=0 WHERE id=?', [
        principal.deviceId,
      ]);
      expect((await get(through: cached)).status, 401);
      await db.execute('DELETE FROM refresh_token WHERE device_id=?', [
        principal.deviceId,
      ]);
      expect((await get(through: cached)).status, 401);
    },
  );

  test(
    'credential revoked between authentication and data Tx returns 401',
    () async {
      observed.beforeTransaction = () async {
        observed.beforeTransaction = null;
        await db.execute('DELETE FROM refresh_token WHERE device_id=?', [
          principal.deviceId,
        ]);
      };
      expect((await get()).status, 401);
    },
  );

  test(
    'rejects query, body, framed null and invalid IDs without returning content',
    () async {
      for (final result in [
        await get(body: {}),
        await get(query: {'owner': owner.value}),
        await get(headers: {'content-length': '4'}),
        await get(headers: {'transfer-encoding': 'chunked'}),
        await get(route: path(message: 'invalid%2Fid')),
      ]) {
        expect(result.status, 400);
        expect(result.json, {'error': 'invalid_argument'});
      }
    },
  );

  test(
    'storage/corrupt enum errors become safe500, no internal text',
    () async {
      observed.failReads = true;
      final failed = await get();
      expect(failed.status, 500);
      expect(failed.json, {'error': 'internal'});
      observed.failReads = false;
      await claim();
      await db.execute('PRAGMA ignore_check_constraints=ON');
      await db.execute(
        "UPDATE owner_reply_attempts SET status='PRIVATE_BODY_OR_KEY_SENTINEL'",
      );
      expect((await get()).json, {'error': 'internal'});
    },
  );
}
