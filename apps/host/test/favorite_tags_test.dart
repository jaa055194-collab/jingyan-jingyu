import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/messages/favorites.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/messages_module.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _ReadMembership implements MembershipCheck {
  @override
  Future<bool> canPost(String accountId, String conversationId) async => true;

  @override
  Future<bool> canRead(String accountId, String conversationId) async => true;
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late FakeClock clock;
  late FavoritesService favorites;
  var counter = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('favorite-tags-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [...allMigrations, ...messagesMigrations],
    );
    cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
    clock = FakeClock(DateTime.utc(2026, 11, 14, 9));
    counter = 0;
    favorites = FavoritesService(
      database: db,
      cipher: cipher,
      clock: clock,
      newId: () => 'fav-${++counter}',
    );
  });

  tearDown(() async {
    cipher.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  test('tags and note are stored, returned, and encrypted at rest', () async {
    final added = await favorites.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      title: '书摘',
      content: '项目代号鲸落',
      tags: ['工作', '重要'],
      note: '私密备注 hello',
    );
    expect(added.isOk, isTrue);
    final id = added.value['id'] as String;

    final listed = await favorites.list(ownerAccountId: 'acctA');
    final item = listed.value.single;
    expect(item['tags'], ['工作', '重要']);
    expect(item['note'], '私密备注 hello');

    final row = (await db.query(
      'SELECT tags, note FROM favorites WHERE id = ?',
      [id],
    )).single;
    expect(row['tags'], isNot(contains('工作')));
    expect(row['note'], isNot(equals('hello')));
    expect((row['tags'] as String).startsWith('v1:'), isTrue);
    expect((row['note'] as String).startsWith('v1:'), isTrue);
  });

  test('search matches tag and note text', () async {
    await favorites.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      content: '正文内容',
      tags: ['旅行'],
      note: '下次去京都',
    );
    expect(
      (await favorites.search(ownerAccountId: 'acctA', query: '旅行')).value,
      hasLength(1),
    );
    expect(
      (await favorites.search(ownerAccountId: 'acctA', query: '京都')).value,
      hasLength(1),
    );
    expect(
      (await favorites.search(ownerAccountId: 'acctA', query: '不存在')).value,
      isEmpty,
    );
  });

  test('invalid tags and note are rejected', () async {
    Future<bool> invalid(Future<Result<Map<String, Object?>>> op) async =>
        (await op).isErr;
    expect(
      await invalid(
        favorites.add(
          ownerAccountId: 'acctA',
          kind: 'text',
          content: 'x',
          tags: List.generate(21, (i) => 't$i'),
        ),
      ),
      isTrue,
    );
    expect(
      await invalid(
        favorites.add(
          ownerAccountId: 'acctA',
          kind: 'text',
          content: 'x',
          tags: ['a'.padRight(51, 'a')],
        ),
      ),
      isTrue,
    );
    expect(
      await invalid(
        favorites.add(
          ownerAccountId: 'acctA',
          kind: 'text',
          content: 'x',
          note: 'n'.padRight(2001, 'n'),
        ),
      ),
      isTrue,
    );
  });

  test('favorites without tags keep null tags/note', () async {
    await favorites.add(ownerAccountId: 'acctA', kind: 'text', content: 'plain');
    final item = (await favorites.list(ownerAccountId: 'acctA')).value.single;
    expect(item['tags'], isNull);
    expect(item['note'], isNull);
  });

  test('GET /favorites?tag= filters by tag (case-insensitive)', () async {
    await favorites.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      content: 'one',
      tags: ['Work'],
    );
    await favorites.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      content: 'two',
      tags: ['life'],
    );
    final services = HostServices()
      ..provide<MembershipCheck>(_ReadMembership(), owner: 'test');
    final module = MessagesModule(
      favorites: favorites,
      clock: clock,
    );
    await module.configure(services);
    final router = Router();
    module.mount(router);
    final pipeline = Pipeline(
      router: router,
      authenticate: (request) async => Principal(
        accountId: request.headers['test-account'] ?? '',
        deviceId: 'd',
      ),
    );
    final response = await pipeline.handle(
      HostRequest(
        method: 'GET',
        path: Routes.favorites,
        query: {'tag': 'work'},
        headers: {'test-account': 'acctA'},
      ),
    );
    expect(response.status, 200);
    final items = ((response.json! as Map)['favorites'] as List)
        .cast<Map<String, Object?>>();
    expect(items, hasLength(1));
    expect(items.single['content'], 'one');
  });

  test('updateMeta replaces tags/note, reindexes, and stays encrypted', () async {
    final added = await favorites.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      content: '正文内容',
      tags: ['old'],
      note: 'n1',
    );
    final id = added.value['id'] as String;
    final updated = await favorites.updateMeta(
      ownerAccountId: 'acctA',
      favoriteId: id,
      tags: ['new', '重要'],
      note: 'n2',
    );
    expect(updated.isOk, isTrue);
    final item = (await favorites.list(ownerAccountId: 'acctA')).value.single;
    expect(item['tags'], ['new', '重要']);
    expect(item['note'], 'n2');
    expect(
      (await favorites.search(ownerAccountId: 'acctA', query: 'old')).value,
      isEmpty,
    );
    expect(
      (await favorites.search(ownerAccountId: 'acctA', query: '重要')).value,
      hasLength(1),
    );
    final row = (await db.query(
      'SELECT tags, note FROM favorites WHERE id = ?',
      [id],
    )).single;
    expect(row['tags'], isNot(contains('重要')));
    expect(row['note'], isNot(equals('n2')));
  });

  test('updateMeta is owner-only and validates input', () async {
    final added = await favorites.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      content: 'x',
    );
    final id = added.value['id'] as String;
    expect(
      (await favorites.updateMeta(
        ownerAccountId: 'acctB',
        favoriteId: id,
        tags: null,
        note: null,
      ))
          .isErr,
      isTrue,
    );
    expect(
      (await favorites.updateMeta(
        ownerAccountId: 'acctA',
        favoriteId: 'missing',
        tags: null,
        note: null,
      ))
          .isErr,
      isTrue,
    );
    expect(
      (await favorites.updateMeta(
        ownerAccountId: 'acctA',
        favoriteId: id,
        tags: List.generate(21, (i) => 't$i'),
        note: null,
      ))
          .isErr,
      isTrue,
    );
  });

  test('PATCH /favorites/{id} updates tags and note', () async {
    final added = await favorites.add(
      ownerAccountId: 'acctA',
      kind: 'text',
      content: 'item',
    );
    final id = added.value['id'] as String;
    final services = HostServices()
      ..provide<MembershipCheck>(_ReadMembership(), owner: 'test');
    final module = MessagesModule(favorites: favorites, clock: clock);
    await module.configure(services);
    final router = Router();
    module.mount(router);
    final pipeline = Pipeline(
      router: router,
      authenticate: (request) async => Principal(
        accountId: request.headers['test-account'] ?? '',
        deviceId: 'd',
      ),
    );
    final response = await pipeline.handle(
      HostRequest(
        method: 'PATCH',
        path: Routes.favorite.replaceFirst('{favoriteId}', id),
        headers: {'test-account': 'acctA'},
        body: {
          'tags': ['x', 'y'],
          'note': 'hello',
        },
      ),
    );
    expect(response.status, 200);
    final item = (await favorites.list(ownerAccountId: 'acctA')).value.single;
    expect(item['tags'], ['x', 'y']);
    expect(item['note'], 'hello');
  });
}
