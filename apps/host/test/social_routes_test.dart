import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/social/social_routes.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late SqliteDatabase database;
  late ConversationService conversations;
  late Pipeline pipeline;
  var serial = 0;

  Future<HostResponse> request(
    String method, {
    String? account = 'alice',
    String? path,
    Object? body,
    Map<String, String> query = const {},
  }) => pipeline.handle(
    HostRequest(
      method: method,
      path: path ?? Routes.conversations,
      headers: {'test-account': ?account},
      query: query,
      body: body,
    ),
  );

  String memberPath(String id) =>
      Routes.conversationMembers.replaceFirst('{conversationId}', id);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('jingyu-social-routes-');
    database = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [...allMigrations, ...socialMigrations],
    );
    // Fake account capability still queries the same real SQLite transaction.
    await database.execute(
      'CREATE TABLE route_accounts (id TEXT PRIMARY KEY, active INTEGER NOT NULL)',
    );
    for (final id in ['alice', 'bob', 'charlie']) {
      await database.execute('INSERT INTO route_accounts VALUES (?, ?)', [
        id,
        1,
      ]);
    }
    conversations = ConversationService(
      database: database,
      clock: FakeClock(DateTime.utc(2026, 11, 13)),
      newId: () => 'route_group_${++serial}',
      headSeq: (_, _) async => 7,
      accountExists: (tx, id) async => (await tx.query(
        'SELECT id FROM route_accounts WHERE id = ? AND active = ?',
        [id, 1],
      )).isNotEmpty,
    );
    final router = Router();
    mountSocialRoutes(router, conversations);
    pipeline = Pipeline(
      router: router,
      // Transport-only fake: the route must take identity from this principal.
      authenticate: (request) async {
        final account = request.headers['test-account'];
        return account == null
            ? null
            : Principal(accountId: account, deviceId: 'test-device');
      },
    );
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test('all social routes require an authenticated principal', () async {
    for (final call in [
      () => request('GET', account: null),
      () => request('POST', account: null, body: {'name': 'group'}),
      () => request(
        'POST',
        account: null,
        path: memberPath('missing'),
        body: {'accountId': 'bob'},
      ),
    ]) {
      expect((await call()).status, 401);
    }
    expect((await conversations.list('alice')).value, isEmpty);
  });

  test(
    'create uses principal as owner and persists group visibility',
    () async {
      for (final visibility in ['all', 'joined']) {
        final response = await request(
          'POST',
          body: {
            'name': '  Our group  ',
            'kind': 'group',
            'historyVisibility': visibility,
          },
        );
        expect(response.status, 200);
        final group = response.json as Map;
        expect(group['ownerAccountId'], 'alice');
        expect(group['name'], 'Our group');
        expect(group['kind'], 'group');
        expect(group['historyVisibility'], visibility);
        expect(group['createdAt'], '2026-11-13T00:00:00.000Z');
        expect(
          await conversations.canRead('alice', group['id'] as String),
          isTrue,
        );
        expect(
          await conversations.canRead('bob', group['id'] as String),
          isFalse,
        );
      }
    },
  );

  test(
    'minimal group defaults to all history and lists only memberships',
    () async {
      final created = await request('POST', body: {'name': 'Private group'});
      expect(created.status, 200);
      final group = created.json as Map;
      expect(group['historyVisibility'], 'all');
      final own = await request('GET');
      expect(own.status, 200);
      expect((own.json as Map)['conversations'], [group]);
      final outsider = await request(
        'GET',
        account: 'bob',
        query: {'accountId': 'alice', 'ownerAccountId': 'alice'},
      );
      expect(outsider.status, 200);
      expect((outsider.json as Map)['conversations'], isEmpty);
    },
  );

  test(
    'create rejects unknown fields, unsupported DM and invalid types',
    () async {
      final invalid = <Object?>[
        null,
        [],
        'group',
        {},
        {'name': 42},
        {'name': null},
        {'name': ''},
        {'name': '  '},
        {'name': 'x' * 101},
        {'name': 'group', 'historyVisibility': 42},
        {'name': 'group', 'historyVisibility': null},
        {'name': 'group', 'historyVisibility': 'future'},
        {'name': 'group', 'kind': 'dm'},
        {'name': 'group', 'kind': 'unknown'},
        {'name': 'group', 'kind': 42},
        {'name': 'group', 'kind': null},
        {'name': 'group', 'ownerAccountId': 'bob'},
        {'name': 'group', 'actorAccountId': 'bob'},
        {'name': 'group', 'unknown': true},
      ];
      for (final body in invalid) {
        final response = await request('POST', body: body);
        expect(response.status, 400, reason: '$body');
      }
      expect((await conversations.list('alice')).value, isEmpty);
      expect((await conversations.list('bob')).value, isEmpty);
    },
  );

  test(
    'only principal owner can add members and preserve joined boundary',
    () async {
      final created = await request(
        'POST',
        body: {'name': 'Joined group', 'historyVisibility': 'joined'},
      );
      final id = (created.json as Map)['id'] as String;
      final path = memberPath(id);
      expect(
        (await request(
          'POST',
          account: 'bob',
          path: path,
          body: {'accountId': 'charlie'},
        )).status,
        404,
      );
      expect(await conversations.canRead('charlie', id), isFalse);
      expect(
        (await request('POST', path: path, body: {'accountId': 'bob'})).status,
        200,
      );
      expect(await conversations.firstVisibleSeq('bob', id), 8);
      final visible = await request('GET', account: 'bob');
      expect(((visible.json as Map)['conversations'] as List).single['id'], id);
      expect(
        (await request(
          'POST',
          account: 'bob',
          path: path,
          body: {'accountId': 'charlie'},
        )).status,
        404,
      );
      expect(
        (await request('POST', path: path, body: {'accountId': 'bob'})).status,
        200,
      );
      expect(await conversations.firstVisibleSeq('bob', id), 8);
    },
  );

  test(
    'member input cannot spoof actor or owner and invalid types return 400',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: 'alice',
        name: 'group',
      )).value;
      for (final body in <Object?>[
        null,
        [],
        {},
        {'accountId': 42},
        {'accountId': null},
        {'accountId': ''},
        {'accountId': 'bad id'},
        {'accountId': 'charlie', 'actorAccountId': 'alice'},
        {'accountId': 'charlie', 'ownerAccountId': 'alice'},
        {'accountId': 'charlie', 'unknown': true},
      ]) {
        expect(
          (await request(
            'POST',
            account: 'bob',
            path: memberPath(group.id),
            body: body,
          )).status,
          400,
          reason: '$body',
        );
      }
      expect(await conversations.canRead('charlie', group.id), isFalse);
      expect(
        (await request(
          'POST',
          path: memberPath('bad%20id'),
          body: {'accountId': 'bob'},
        )).status,
        400,
      );
    },
  );

  test('unknown groups and absent or disabled accounts return 404', () async {
    final group = (await conversations.createGroup(
      ownerAccountId: 'alice',
      name: 'group',
    )).value;
    expect(
      (await request(
        'POST',
        path: memberPath('missing'),
        body: {'accountId': 'bob'},
      )).status,
      404,
    );
    await database.execute(
      'UPDATE route_accounts SET active = 0 WHERE id = ?',
      ['bob'],
    );
    for (final account in ['missing', 'bob']) {
      expect((await request('GET', account: account)).status, 404);
      expect(
        (await request(
          'POST',
          account: account,
          body: {'name': 'group'},
        )).status,
        404,
      );
      expect(
        (await request(
          'POST',
          path: memberPath(group.id),
          body: {'accountId': account},
        )).status,
        404,
      );
    }
  });
}
