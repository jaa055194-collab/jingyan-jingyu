/// FR-37 真实 VisitAccessPolicy（只读 social 关系表）契约测试。
///
/// 覆盖好友、拉黑（含 AI→operator 继承）、账号可用性，以及明确缺口
/// （在线 presence / AI 接待开关未持久化）。
library;

import 'dart:io';

import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/social/friendship_migrations.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host/src/world/database_visit_access_policy.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late SqliteDatabase database;
  late DatabaseVisitAccessPolicy policy;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('world-policy-');
    database = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        friendshipMigration,
      ],
    );
    policy = DatabaseVisitAccessPolicy(database: database);
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<void> addHuman(String id, {int disabled = 0}) => database.execute(
    "INSERT INTO account VALUES (?,?,'human',0,?,'h',0,0)",
    [id, id, disabled],
  );

  Future<void> addAi(String id, String operator) async {
    await database.execute(
      "INSERT INTO account VALUES (?,?,'ai',0,0,NULL,0,0)",
      [id, id],
    );
    await database.execute('INSERT INTO ai_operator VALUES (?,?)', [
      id,
      operator,
    ]);
  }

  Future<void> befriend(String a, String b) async {
    final pair = a.compareTo(b) < 0 ? [a, b] : [b, a];
    await database.execute('INSERT INTO friendships VALUES (?,?,0)', pair);
  }

  Future<void> block(String blocker, String target) => database.execute(
    'INSERT INTO account_blocks VALUES (?,?,0)',
    [blocker, target],
  );

  test('好友关系来自 friendships 表', () async {
    await addHuman('a');
    await addHuman('b');
    expect(await policy.areFriends('a', 'b'), isFalse);
    await befriend('a', 'b');
    expect(await policy.areFriends('a', 'b'), isTrue);
    expect(await policy.areFriends('b', 'a'), isTrue);
  });

  test('拉黑：isBlocked 双向可见，且好友关系失效', () async {
    await addHuman('a');
    await addHuman('b');
    await befriend('a', 'b');
    await block('b', 'a');
    expect(await policy.isBlocked('a', 'b'), isTrue);
    expect(await policy.isBlocked('b', 'a'), isTrue);
    expect(await policy.areFriends('a', 'b'), isFalse);
  });

  test('AI 继承 operator 的拉黑关系（C-5）', () async {
    await addHuman('human_a');
    await addHuman('human_b');
    await addAi('ai_a', 'human_a');
    await block('human_b', 'human_a');
    expect(await policy.isBlocked('ai_a', 'human_b'), isTrue);
  });

  test('账号可用性：禁用账号不算好友 / 不算主人在场', () async {
    await addHuman('a');
    await addHuman('b', disabled: 1);
    await befriend('a', 'b');
    expect(await policy.areFriends('a', 'b'), isFalse);
    expect(await policy.isHostPresent('b'), isFalse);
    expect(await policy.isHostPresent('a'), isTrue);
  });

  test('缺口：aiReceivesWhileAbsent 默认 true（未见持久化开关）', () async {
    await addHuman('a');
    expect(await policy.aiReceivesWhileAbsent('a'), isTrue);
  });
}
