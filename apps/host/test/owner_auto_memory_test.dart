import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/ai/memory/memory_migrations.dart';
import 'package:jingyu_host/src/ai/memory/memory_store.dart';
import 'package:jingyu_host/src/ai/memory/owner_auto_memory.dart';
import 'package:jingyu_host/src/ai/memory/owner_auto_memory_migration.dart';
import 'package:jingyu_host/src/ai/memory/owner_auto_memory_module.dart';
import 'package:jingyu_host/src/ai/memory/owner_memory_authorization.dart';
import 'package:jingyu_host/src/brain/owner_ai_direct_incoming.dart';
import 'package:jingyu_host/src/brain/owner_ai_direct_source_migration.dart';
import 'package:jingyu_host/src/messages/message_store.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/models/binding_migrations.dart';
import 'package:jingyu_host/src/models/models_migrations.dart';
import 'package:jingyu_host/src/social/friendship_migrations.dart';
import 'package:jingyu_host/src/social/owner_ai_direct_consent.dart';
import 'package:jingyu_host/src/social/owner_ai_direct_migration.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

const _owner = 'auto-owner';
const _other = 'auto-other';
const _ai = 'auto-ai';
const _profile = 'auto-profile';

const _migrations = [
  ...allMigrations,
  ...accountsMigrations,
  ...messagesMigrations,
  ownerAiDirectSourceMigration,
  ...socialMigrations,
  friendshipMigration,
  privateConversationMigration,
  ownerAiDirectMigration,
  ...modelsMigrations,
  aiIdentityMigration,
  bindingMigration,
  ...memoryMigrations,
  ownerAutoMemoryMigration,
];

void main() {
  late _Fixture f;
  setUp(() async => f = await _Fixture.create());
  tearDown(() async {
    await f.close();
    await f.directory.delete(recursive: true);
  });

  test('default is off with no rows and anon/non-owner are refused', () async {
    expect(await f.readSettings(), {
      'revision': 0,
      'enabled': false,
      'target': null,
    });
    expect(await f.db.query('SELECT * FROM owner_auto_memory_settings'), isEmpty);
    expect(await f.db.query('SELECT * FROM encrypted_memory'), isEmpty);

    await f.consent();
    await f.bind();
    final offered = await f.readSettings();
    expect(offered['revision'], 0);
    expect(offered['enabled'], false);
    expect(offered['target'], isNotNull);

    final anon = await f.autoMemory.readSettings(
      owner: _owner,
      device: '$_owner-device',
      bearer: '',
      ai: AiId.parse(_profile),
    );
    expect(anon.failureOrNull?.code, FailureCode.unauthenticated);
    final other = await f.autoMemory.readSettings(
      owner: _other,
      device: '$_other-device',
      bearer: f.tokens[_other]!,
      ai: AiId.parse(_profile),
    );
    expect(other.failureOrNull?.code, FailureCode.notFound);
  });

  test('settings are strict and CAS-bound', () async {
    await f.consent();
    await f.bind();
    final settings = await f.readSettings();
    final target = settings['target']! as Map;
    final token = target['token']! as String;

    final cas = await f.autoMemory.setEnabled(
      owner: _owner,
      device: '$_owner-device',
      bearer: f.tokens[_owner]!,
      ai: AiId.parse(_profile),
      expectedRevision: 5,
      enabled: true,
      expectedTargetToken: token,
    );
    expect(cas.failureOrNull?.code, FailureCode.conflict);

    for (final bad in [
      (enabled: false, token: 'x'),
      (enabled: true, token: 'wrong-token'),
      (enabled: true, token: null),
    ]) {
      final result = await f.autoMemory.setEnabled(
        owner: _owner,
        device: '$_owner-device',
        bearer: f.tokens[_owner]!,
        ai: AiId.parse(_profile),
        expectedRevision: 0,
        enabled: bad.enabled,
        expectedTargetToken: bad.token,
      );
      expect(result.failureOrNull?.code, FailureCode.invalidArgument);
    }

    final enabled = await f.enable();
    expect(enabled['revision'], 1);
    expect(enabled['enabled'], true);
    expect(
      (await f.db.query('SELECT * FROM owner_auto_memory_settings')).single,
      containsPair('enabled', 1),
    );
  });

  test('capture is encrypted at rest and audit never contains body', () async {
    await f.consent();
    await f.bind();
    await f.enable();
    final message = await f.accept('c1', '记住我喜欢桂花');
    await f.capture(message);
    final rows = await f.db.query('SELECT * FROM encrypted_memory');
    expect(rows, hasLength(1));
    expect(rows.single['encrypted_body']! as String, startsWith('v1:'));
    expect(rows.single['tier'], 't0');
    expect(rows.single['status'], 'active');
    expect(rows.single['scope_key'], 'private:$_profile:$_owner');
    final memoryDump = jsonEncode(rows);
    expect(memoryDump, isNot(contains('喜欢桂花')));
    final audit = jsonEncode(await f.db.query('SELECT * FROM audit_log'));
    expect(audit, isNot(contains('喜欢桂花')));
    expect(audit, contains('owner_auto_memory.settings'));
  });

  test('never captures group or third-party content', () async {
    await f.consent();
    await f.bind();
    await f.enable();
    final store = MemoryStore(
      database: f.db,
      cipher: f.cipher,
      clock: f.clock,
      authorizer: const OwnerPrivateMemoryAuthorization(),
    );
    MemoryCandidate candidate({
      required String scopeKey,
      required String sourceAccountId,
      required MemoryTier tier,
    }) => MemoryCandidate(
      owningOperatorId: _owner,
      aiProfileId: _profile,
      sourceAccountId: sourceAccountId,
      aboutAccountId: _owner,
      scopeKey: scopeKey,
      sourceMessageIds: const ['m1'],
      body: '记住群里的内容',
      overlappingTiers: [tier],
      evidence: EvidenceLevel.userStated,
      userOptedOut: false,
    );

    final group = await store.capture(
      candidate(
        scopeKey: 'group:$_profile:room',
        sourceAccountId: _owner,
        tier: MemoryTier.t0,
      ),
    );
    expect(group.failureOrNull?.code, FailureCode.forbidden);
    final thirdParty = await store.capture(
      candidate(
        scopeKey: 'private:$_profile:$_owner',
        sourceAccountId: _other,
        tier: MemoryTier.t1,
      ),
    );
    expect(thirdParty.failureOrNull?.code, FailureCode.forbidden);
    expect(await f.db.query('SELECT * FROM encrypted_memory'), isEmpty);
  });

  test('T0 is active, T1 is pending, and only active injects', () async {
    await f.consent();
    await f.bind();
    await f.enable();
    final t0 = await f.accept('c-t0', '记住我喜欢桂花');
    await f.capture(t0);
    final t1 = await f.accept('c-t1', '我最近睡得很晚');
    await f.capture(t1);

    final list = await f.list();
    final entries = (list['entries']! as List).cast<Map<String, Object?>>();
    expect(entries, hasLength(2));
    final byText = {for (final e in entries) e['text']: e};
    expect(byText['记住我喜欢桂花']!['tier'], 't0');
    expect(byText['记住我喜欢桂花']!['status'], 'active');
    expect(byText['我最近睡得很晚']!['tier'], 't1');
    expect(byText['我最近睡得很晚']!['status'], 'pending');

    final use = await f.db.transaction((tx) async {
      final grant = await OwnerAiDirectConsent.resolveInTx(
        tx,
        ownerAccountId: _owner,
        conversationId: f.conversationId!,
      );
      return f.autoMemory.forSourceInTx(tx, grant!, t0.messageId);
    });
    expect(use, isNotNull);
    expect(use!.entries, ['记住我喜欢桂花']);
  });

  test('injection is bounded to five active entries', () async {
    await f.consent();
    await f.bind();
    await f.enable();
    String? lastId;
    for (var i = 1; i <= 6; i++) {
      f.clock.advance(const Duration(seconds: 1));
      final message = await f.accept('c$i', '记住事项$i');
      await f.capture(message);
      lastId = message.messageId;
    }
    expect(((await f.list())['entries']! as List), hasLength(6));
    final use = await f.db.transaction((tx) async {
      final grant = await OwnerAiDirectConsent.resolveInTx(
        tx,
        ownerAccountId: _owner,
        conversationId: f.conversationId!,
      );
      return f.autoMemory.forSourceInTx(tx, grant!, lastId!);
    });
    expect(use!.entries, hasLength(5));
    expect(use.entries.first, '记住事项6');
  });

  test('capture is capped at 50 active+pending per AI', () async {
    await f.consent();
    await f.bind();
    await f.enable();
    for (var i = 1; i <= 50; i++) {
      f.clock.advance(const Duration(seconds: 1));
      final message = await f.accept('c$i', '记住事项$i');
      await f.capture(message);
    }
    expect(((await f.list())['entries']! as List), hasLength(50));
    f.clock.advance(const Duration(seconds: 1));
    final overflow = await f.accept('c51', '记住溢出事项');
    await f.capture(overflow);
    expect(((await f.list())['entries']! as List), hasLength(50));
    expect(
      jsonEncode(await f.db.query('SELECT * FROM encrypted_memory')),
      isNot(contains('溢出事项')),
    );
  });

  test('old accepted message cannot obtain memory enabled later', () async {
    await f.consent();
    await f.bind();
    final old = await f.accept('old', '记住我很早就说过这句');
    await f.enable();
    await f.capture(old);
    expect(await f.db.query('SELECT * FROM encrypted_memory'), isEmpty);
    expect(await f.db.query('SELECT * FROM owner_auto_memory_sources'), isEmpty);
  });

  test('delete single and clear remove entries and bump revision', () async {
    await f.consent();
    await f.bind();
    await f.enable();
    final active = await f.accept('a1', '记住我喜欢桂花');
    await f.capture(active);
    final pending = await f.accept('p1', '我最近睡得晚');
    await f.capture(pending);
    final list = await f.list();
    expect(list['revision'], 1);
    final entries = (list['entries']! as List).cast<Map<String, Object?>>();
    expect(entries, hasLength(2));

    final pendingEntry = entries.firstWhere(
      (e) => e['status'] == 'pending',
    );
    final afterDelete = await f.delete(
      pendingEntry['id']! as String,
      list['revision']! as int,
    );
    expect(afterDelete['revision'], 2);
    expect(afterDelete['entries']! as List, hasLength(1));
    expect(
      jsonEncode(afterDelete['entries']),
      isNot(contains('我最近睡得晚')),
    );

    final afterClear = await f.clear(afterDelete['revision']! as int);
    expect(afterClear['revision'], 3);
    expect(afterClear['entries']! as List, isEmpty);
    expect(
      await f.db.query(
        "SELECT * FROM encrypted_memory WHERE status IN ('active','pending')",
      ),
      isEmpty,
    );
    final audit = jsonEncode(await f.db.query('SELECT * FROM audit_log'));
    expect(audit, contains('owner_auto_memory.delete'));
    expect(audit, contains('owner_auto_memory.clear'));
    for (final sentinel in ['喜欢桂花', '我最近睡得晚']) {
      expect(audit, isNot(contains(sentinel)));
    }
  });

  test('module maps anonymous, non-owner, strict and conflict statuses', () async {
    await f.consent();
    await f.bind();
    final router = Router();
    OwnerAutoMemoryModule(f.autoMemory, f.auth).mount(router);
    final pipeline = Pipeline(router: router, authenticate: f.auth);
    Future<HostResponse> call(
      String method,
      String path, {
      Object? body,
      String? actor = _owner,
    }) => pipeline.handle(
      HostRequest(
        method: method,
        path: path,
        body: body,
        headers: {
          if (actor != null) 'authorization': 'Bearer ${f.tokens[actor]}',
        },
      ),
    );

    final settingsPath = Routes.aiOwnerAutoMemorySettings.replaceFirst(
      '{aiId}',
      _profile,
    );
    final listPath = Routes.aiOwnerAutoMemory.replaceFirst('{aiId}', _profile);

    expect((await call('GET', settingsPath, actor: null)).status, 401);
    expect((await call('GET', settingsPath, actor: _other)).status, 404);

    final target = (await f.readSettings())['target']! as Map;
    expect(
      (await call(
        'PUT',
        settingsPath,
        body: {
          'expectedRevision': 0,
          'enabled': true,
          'expectedTargetToken': target['token'],
          'extra': true,
        },
      )).status,
      400,
    );
    expect(
      (await call(
        'PUT',
        settingsPath,
        body: {
          'expectedRevision': 9,
          'enabled': true,
          'expectedTargetToken': target['token'],
        },
      )).status,
      409,
    );
    expect((await call('GET', listPath)).status, 200);
  });

  test('module rejects bad revision, token shape, body and path params', () async {
    await f.consent();
    await f.bind();
    final router = Router();
    OwnerAutoMemoryModule(f.autoMemory, f.auth).mount(router);
    final pipeline = Pipeline(router: router, authenticate: f.auth);
    Future<HostResponse> call(
      String method,
      String path, {
      Object? body,
      String? actor = _owner,
    }) => pipeline.handle(
      HostRequest(
        method: method,
        path: path,
        body: body,
        headers: {
          if (actor != null) 'authorization': 'Bearer ${f.tokens[actor]}',
        },
      ),
    );
    final settingsPath = Routes.aiOwnerAutoMemorySettings.replaceFirst(
      '{aiId}',
      _profile,
    );
    final listPath = Routes.aiOwnerAutoMemory.replaceFirst('{aiId}', _profile);
    final entryPath = Routes.aiOwnerAutoMemoryEntry
        .replaceFirst('{aiId}', _profile)
        .replaceFirst('{memoryId}', 'mem-a');

    for (final body in [
      {'expectedRevision': -1, 'enabled': false, 'expectedTargetToken': null},
      {'expectedRevision': 0, 'enabled': 'yes', 'expectedTargetToken': null},
      {'expectedRevision': 0, 'enabled': false},
      {'expectedRevision': 0, 'enabled': false, 'expectedTargetToken': 'a' * 129},
      {'expectedRevision': 0, 'enabled': false, 'expectedTargetToken': 'bad token'},
    ]) {
      expect((await call('PUT', settingsPath, body: body)).status, 400);
    }
    for (final body in [
      {'expectedRevision': -1},
      {'expectedRevision': 0, 'extra': true},
      <String, Object?>{},
    ]) {
      expect((await call('DELETE', listPath, body: body)).status, 400);
      expect((await call('DELETE', entryPath, body: body)).status, 400);
    }
    // A GET with a body, a query string, or a non-canonical AI id is refused.
    expect((await call('GET', listPath, body: {'a': 1})).status, 400);
    expect(
      (await pipeline.handle(
        HostRequest(
          method: 'GET',
          path: listPath,
          query: const {'debug': '1'},
          headers: {'authorization': 'Bearer ${f.tokens[_owner]}'},
        ),
      )).status,
      400,
    );
    expect(
      (await call(
        'GET',
        Routes.aiOwnerAutoMemory.replaceFirst('{aiId}', 'bad id'),
      )).status,
      400,
    );
    // Unknown entry id is a 404, never a silent success.
    expect(
      (await call('DELETE', entryPath, body: {'expectedRevision': 0})).status,
      404,
    );
    expect(await f.db.query('SELECT * FROM owner_auto_memory_settings'), isEmpty);
  });

  test('clear with no entries still bumps revision and audits', () async {
    await f.consent();
    await f.bind();
    await f.enable();
    final cleared = await f.clear(1);
    expect(cleared['revision'], 2);
    expect(cleared['entries'], isEmpty);
    expect(
      jsonEncode(await f.db.query('SELECT * FROM audit_log')),
      contains('owner_auto_memory.clear'),
    );
  });

  test('capture rejects recalled, edited and non-private sources', () async {
    await f.consent();
    await f.bind();
    await f.enable();
    final edited = await f.accept('c-edit', '记住会被编辑');
    await f.db.execute(
      '''INSERT INTO message_edits(edit_id,message_id,conversation_id,editor_id,body,edited_at)
VALUES('e1',?,?,?,?,?)''',
      [edited.messageId, edited.conversationId, _owner, 'sealed', 'now'],
    );
    await f.capture(edited);

    final recalled = await f.accept('c-recall', '记住会被撤回');
    await f.db.execute(
      'UPDATE messages SET recalled_at=? WHERE message_id=?',
      ['now', recalled.messageId],
    );
    await f.capture(recalled);

    expect(await f.db.query('SELECT * FROM encrypted_memory'), isEmpty);
  });

  test('long or multi-line owner text is never captured', () async {
    await f.consent();
    await f.bind();
    await f.enable();
    // 512 UTF-8 bytes is the per-entry bound: "记住" is 6 bytes, so 169 CJK
    // chars (507 bytes) is 513 bytes and must be refused.
    final tooLong = await f.accept('c-long', '记住${'花' * 169}');
    await f.capture(tooLong);
    expect(await f.db.query('SELECT * FROM encrypted_memory'), isEmpty);

    f.clock.advance(const Duration(seconds: 1));
    // Control characters (including a newline) are refused outright.
    final multiLine = await f.accept('c-multi', '记住第一行\n第二行');
    await f.capture(multiLine);
    expect(await f.db.query('SELECT * FROM encrypted_memory'), isEmpty);

    f.clock.advance(const Duration(seconds: 1));
    // 168 CJK chars (504 bytes) plus the 6-byte prefix is exactly 510 bytes.
    final bounded = await f.accept('c-bound', '记住${'花' * 168}');
    await f.capture(bounded);
    expect(await f.db.query('SELECT * FROM encrypted_memory'), hasLength(1));
  });

  test('disable stops capture and stale sources never inject', () async {
    await f.consent();
    await f.bind();
    await f.enable();
    final before = await f.accept('c1', '记住关闭前');
    await f.capture(before);
    final disabled = await f.disable();
    expect(disabled['enabled'], false);
    // Existing entries stay visible after revoking the grant.
    expect(((await f.list())['entries']! as List), hasLength(1));

    f.clock.advance(const Duration(seconds: 1));
    final after = await f.accept('c2', '记住关闭后');
    await f.capture(after);
    expect(((await f.list())['entries']! as List), hasLength(1));

    final use = await f.db.transaction((tx) async {
      final grant = await OwnerAiDirectConsent.resolveInTx(
        tx,
        ownerAccountId: _owner,
        conversationId: f.conversationId!,
      );
      return f.autoMemory.forSourceInTx(tx, grant!, before.messageId);
    });
    expect(use, isNull);
  });

  test('injection is also bounded by 1024 total bytes', () async {
    await f.consent();
    await f.bind();
    await f.enable();
    String? last;
    // Each entry is ~340 bytes, so only three fit inside 1024 bytes.
    for (var i = 1; i <= 4; i++) {
      f.clock.advance(const Duration(seconds: 1));
      final message = await f.accept('c$i', '记住${'花' * 110}$i');
      await f.capture(message);
      last = message.messageId;
    }
    final use = await f.db.transaction((tx) async {
      final grant = await OwnerAiDirectConsent.resolveInTx(
        tx,
        ownerAccountId: _owner,
        conversationId: f.conversationId!,
      );
      return f.autoMemory.forSourceInTx(tx, grant!, last!);
    });
    expect(use, isNotNull);
    expect(use!.entries, hasLength(3));
    final total = use.entries.fold<int>(
      0,
      (sum, text) => sum + utf8.encode(text).length,
    );
    expect(total, lessThanOrEqualTo(1024));
    expect(OwnerAutoMemoryUse.kind, 'untrusted_owner_memory');
    expect(use.toJson(), {
      'kind': 'untrusted_owner_memory',
      'entries': use.entries,
    });
  });

  test('pending entries never inject even when newer than active ones', () async {
    await f.consent();
    await f.bind();
    await f.enable();
    final active = await f.accept('a1', '记住我喜欢桂花');
    await f.capture(active);
    f.clock.advance(const Duration(seconds: 1));
    final pending = await f.accept('p1', '我最近睡得很晚');
    await f.capture(pending);
    final use = await f.db.transaction((tx) async {
      final grant = await OwnerAiDirectConsent.resolveInTx(
        tx,
        ownerAccountId: _owner,
        conversationId: f.conversationId!,
      );
      return f.autoMemory.forSourceInTx(tx, grant!, pending.messageId);
    });
    expect(use!.entries, ['记住我喜欢桂花']);
  });

  test('a settings change makes the earlier accepted source stale', () async {
    await f.consent();
    await f.bind();
    await f.enable();
    final message = await f.accept('c1', '记住我喜欢桂花');
    await f.capture(message);
    final use = await f.db.transaction((tx) async {
      final grant = await OwnerAiDirectConsent.resolveInTx(
        tx,
        ownerAccountId: _owner,
        conversationId: f.conversationId!,
      );
      return f.autoMemory.forSourceInTx(tx, grant!, message.messageId);
    });
    expect(use, isNotNull);
    // Disabling and re-enabling must not revive the old source stamp.
    await f.disable();
    await f.enable();
    final stale = await f.db.transaction((tx) async {
      final grant = await OwnerAiDirectConsent.resolveInTx(
        tx,
        ownerAccountId: _owner,
        conversationId: f.conversationId!,
      );
      return f.autoMemory.forSourceInTx(tx, grant!, message.messageId);
    });
    expect(stale, isNull);
  });

  test('capture is a no-op for an unknown or non-owner message', () async {
    await f.consent();
    await f.bind();
    await f.enable();
    final message = await f.accept('c1', '记住我喜欢桂花');
    // An unstamped message id and a mismatched sender both capture nothing.
    await f.autoMemory.captureAccepted(
      StoredMessage(
        conversationId: message.conversationId,
        seq: message.seq,
        messageId: 'not-stamped',
        senderId: _owner,
        clientMsgId: 'x',
        kind: MessageKind.text,
        body: const {'text': '记住伪造'},
        sentAt: message.sentAt,
      ),
    );
    expect(await f.db.query('SELECT * FROM encrypted_memory'), isEmpty);
    // The observer interface delegates to the same bounded capture path.
    await f.autoMemory.onAccepted(message);
    expect(await f.db.query('SELECT * FROM encrypted_memory'), hasLength(1));
  });
}

final class _Fixture {
  _Fixture(this.directory, this.clock);
  final Directory directory;
  final FakeClock clock;
  final tokens = <String, String>{};
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late OwnerAutoMemory autoMemory;
  late OwnerAiDirectIncoming incoming;
  String? conversationId;

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'owner-auto-memory-',
    );
    final clock = FakeClock(DateTime.utc(2026, 1, 1, 9));
    final f = _Fixture(directory, clock);
    f.db = await SqliteDatabase.open(
      '${directory.path}/memory.sqlite',
      migrations: _migrations,
    );
    f.cipher = AesGcmColumnCipher(List.filled(32, 7));
    f.autoMemory = OwnerAutoMemory(
      database: f.db,
      cipher: f.cipher,
      clock: clock,
    );
    f.incoming = OwnerAiDirectIncoming(
      database: f.db,
      messages: SqliteMessageStore(
        database: f.db,
        cipher: f.cipher,
        clock: clock,
      ),
    );

    for (final human in [_owner, _other]) {
      await f.db.execute(
        "INSERT INTO account VALUES(?,?,'human',?,0,'test-only',0,0)",
        [human, human, human == _other ? 1 : 0],
      );
    }
    await f.db.execute("INSERT INTO account VALUES(?,?,'ai',0,0,NULL,0,0)", [
      _ai,
      'Fixture',
    ]);
    await f.db.execute('INSERT INTO ai_operator VALUES(?,?)', [_ai, _owner]);
    await f.db.execute('INSERT INTO ai_profile VALUES(?,?)', [_profile, _ai]);

    final random = Random.secure();
    String hash(String raw) => sha256.convert(utf8.encode(raw)).toString();
    for (final actor in [_owner, _other]) {
      final token = base64UrlEncode(
        List.generate(16, (_) => random.nextInt(256)),
      ).replaceAll('=', '');
      f.tokens[actor] = token;
      final now = clock.now();
      final expires = now.add(const Duration(days: 30)).millisecondsSinceEpoch;
      await f.db.execute('INSERT INTO device VALUES(?,?,?,?,?,?)', [
        '$actor-device',
        actor,
        'Test device',
        hash(token),
        expires,
        now.millisecondsSinceEpoch,
      ]);
      await f.db.execute('INSERT INTO refresh_token VALUES(?,?,?)', [
        '$actor-device',
        hash('refresh-$token'),
        expires,
      ]);
    }
    return f;
  }

  Future<Principal?> auth(HostRequest request) async {
    final header = request.headers['authorization'];
    if (header == null || !header.startsWith('Bearer ')) return null;
    final bearer = header.substring(7).trim();
    for (final entry in tokens.entries) {
      if (entry.value == bearer) {
        return Principal(accountId: entry.key, deviceId: '${entry.key}-device');
      }
    }
    return null;
  }

  Future<void> consent() async {
    final result = await OwnerAiDirectConsent(
      database: db,
      clock: clock,
    ).open(ownerId: _owner, aiProfileId: _profile, expectedRevision: 0);
    expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
    conversationId = result.value['conversationId']! as String;
  }

  Future<void> bind() async {
    await db.execute(
      '''
INSERT INTO providers(owner_id,id,name,base_url,encrypted_key,key_mask,enabled,capabilities)
VALUES(?,?,?,?,?,?,?,?)''',
      [
        _owner,
        'provider-a',
        'Synthetic',
        'https://192.0.2.1/v1',
        'encrypted-key',
        'mask',
        1,
        '["chat"]',
      ],
    );
    await db.execute(
      '''
INSERT INTO model_bindings(owner_id,ai_profile_id,capability,provider_id,model)
VALUES(?,?,?,?,?)''',
      [_owner, _profile, 'chat', 'provider-a', 'fixture-model'],
    );
  }

  Future<Map<String, Object?>> readSettings() async {
    final result = await autoMemory.readSettings(
      owner: _owner,
      device: '$_owner-device',
      bearer: tokens[_owner]!,
      ai: AiId.parse(_profile),
    );
    expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
    return result.value;
  }

  Future<Map<String, Object?>> enable() async {
    final settings = await readSettings();
    final target = settings['target']! as Map;
    final result = await autoMemory.setEnabled(
      owner: _owner,
      device: '$_owner-device',
      bearer: tokens[_owner]!,
      ai: AiId.parse(_profile),
      expectedRevision: settings['revision']! as int,
      enabled: true,
      expectedTargetToken: target['token']! as String,
    );
    expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
    return result.value;
  }

  Future<Map<String, Object?>> disable() async {
    final settings = await readSettings();
    final result = await autoMemory.setEnabled(
      owner: _owner,
      device: '$_owner-device',
      bearer: tokens[_owner]!,
      ai: AiId.parse(_profile),
      expectedRevision: settings['revision']! as int,
      enabled: false,
      expectedTargetToken: null,
    );
    expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
    return result.value;
  }

  Future<Map<String, Object?>> list() async {
    final result = await autoMemory.listEntries(
      owner: _owner,
      device: '$_owner-device',
      bearer: tokens[_owner]!,
      ai: AiId.parse(_profile),
    );
    expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
    return result.value;
  }

  Future<Map<String, Object?>> delete(String id, int revision) async {
    final result = await autoMemory.deleteEntry(
      owner: _owner,
      device: '$_owner-device',
      bearer: tokens[_owner]!,
      ai: AiId.parse(_profile),
      memoryId: id,
      expectedRevision: revision,
    );
    expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
    return result.value;
  }

  Future<Map<String, Object?>> clear(int revision) async {
    final result = await autoMemory.clearEntries(
      owner: _owner,
      device: '$_owner-device',
      bearer: tokens[_owner]!,
      ai: AiId.parse(_profile),
      expectedRevision: revision,
    );
    expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
    return result.value;
  }

  Future<StoredMessage> accept(String clientId, String text) async {
    final result = await incoming.append(
      conversationId: conversationId!,
      senderId: _owner,
      clientMsgId: clientId,
      kind: MessageKind.text,
      body: {'text': text},
    );
    expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
    return result.value.message;
  }

  Future<void> capture(StoredMessage message) =>
      autoMemory.captureAccepted(message);

  Future<void> close() async {
    await db.close();
    cipher.dispose();
  }
}
