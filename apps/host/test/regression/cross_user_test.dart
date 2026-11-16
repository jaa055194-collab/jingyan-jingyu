/// AC-01 / FR-67 / NFR-09 跨用户串数据回归（发布硬门槛）。
///
/// 建两个用户 A、B，B 写入消息（含编辑前旧正文）、收藏、附件、provider 密钥；
/// 用 A 的 token 调每一个读接口，断言响应里找不到 B 的任何内容。
/// 路由清单从 `Router.describe()` 取得，新增读路由会自动进入扫描。
///
/// 本测试是“可运行子集”：仅覆盖默认宿主当前已装配的域。记忆/动态/日记等
/// 未装配域在文件末尾以 skip 如实标记为未覆盖，绝不伪造通过。
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';

import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

import 'hardening_support.dart';

// 测试专用合成秘密串（非真实数据）。
const String msgBody = 'CROSSUSER-MSG-SECRET-7f3a';
const String msgOldBody = '{{SECRET_k1m2n3o4}}';
const String favTitle = 'CROSSUSER-FAV-TITLE-91b2';
const String favContent = '{{SECRET_p5q6r7s8}}';
const String attachText = 'CROSSUSER-ATTACH-TEXT-6c7d';
const String providerKey = '{{SECRET_w9x8y7z6}}';

const List<String> bSecrets = <String>[
  msgBody,
  msgOldBody,
  favTitle,
  favContent,
  attachText,
  providerKey,
];

void main() {
  group('AC-01 / FR-67 跨用户串数据回归', () {
    late Harness harness;
    late TestUser alice;
    late TestUser bob;
    late String bobConversation;
    late String bobMessage;
    late String bobAttachment;

    setUpAll(() async {
      harness = await Harness.boot();
      alice = await harness.seedAccount(
        displayName: 'Alice',
        id: 'acct-alice',
        token: syntheticToken('a'),
      );
      bob = await harness.seedAccount(
        displayName: 'Bobby',
        id: 'acct-bob',
        token: syntheticToken('b'),
      );
      bobConversation = await createGroup(harness, bob.token, 'Bob private group');
      bobMessage = await sendText(
        harness,
        bob.token,
        bobConversation,
        msgOldBody,
        'bob-msg-1',
      );
      await editMessage(harness, bob.token, bobConversation, bobMessage, msgBody);
      await addTextFavorite(harness, bob.token, favTitle, favContent);
      bobAttachment = await uploadTextAttachment(
        harness,
        bob.token,
        attachText,
        conversationId: bobConversation,
      );
      await createProvider(
        harness,
        bob.token,
        name: 'Bob provider',
        apiKey: providerKey,
      );
    });

    tearDownAll(() async {
      await harness.dispose();
    });

    Map<String, String> sweepParams() => <String, String>{
      'conversationId': bobConversation,
      'messageId': bobMessage,
      'attachmentId': bobAttachment,
      'accountId': bob.id,
      'favoriteId': 'probe',
    };

    test('正向对照：A 能搜到自己写的内容（证明隔离断言不是恒真）', () async {
      final ownConversation = await createGroup(
        harness,
        alice.token,
        'Alice group',
      );
      const ownText = '{{SECRET_own_alice_9f3c}}';
      await sendText(harness, alice.token, ownConversation, ownText, 'a-own-1');
      final res = await harness.handle(
        'GET',
        Routes.search,
        token: alice.token,
        query: <String, String>{'q': ownText},
      );
      expect(res.status, 200);
      final hits = asMap(res)['hits'] as List<dynamic>;
      expect(hits, isNotEmpty);
      expect(jsonEncode(hits), contains(ownText));
    });

    test('A 的会话列表看不到 B 的群', () async {
      final res = await harness.handle(
        'GET',
        Routes.conversations,
        token: alice.token,
      );
      expect(res.status, 200);
      expect(jsonEncode(res.json), isNot(contains(bobConversation)));
    });

    test('A 同步 B 的会话返回 404 且无正文', () async {
      final res = await harness.handle(
        'GET',
        fillPath(Routes.sync, {'conversationId': bobConversation}),
        token: alice.token,
      );
      expect(res.status, 404);
      expect(jsonEncode(res.json), isNot(contains(msgBody)));
    });

    test('A 消息搜索找不到 B 的正文', () async {
      final res = await harness.handle(
        'GET',
        Routes.search,
        token: alice.token,
        query: <String, String>{'q': msgBody},
      );
      expect(res.status, 200);
      expect((asMap(res)['hits'] as List<dynamic>), isEmpty);
    });

    test('A 收藏列表与文件搜索看不到 B 的内容', () async {
      final favorites = await harness.handle(
        'GET',
        Routes.favorites,
        token: alice.token,
      );
      expect(favorites.status, 200);
      expect((asMap(favorites)['favorites'] as List<dynamic>), isEmpty);

      final fileSearch = await harness.handle(
        'GET',
        Routes.search,
        token: alice.token,
        query: <String, String>{'q': attachText, 'type': 'file'},
      );
      expect(fileSearch.status, 200);
      expect((asMap(fileSearch)['hits'] as List<dynamic>), isEmpty);
    });

    test('A 读取 B 的附件返回 404 且不含抽取正文', () async {
      final res = await harness.handle(
        'GET',
        fillPath(Routes.attachment, {'attachmentId': bobAttachment}),
        token: alice.token,
      );
      expect(res.status, 404);
      expect(jsonEncode(res.json), isNot(contains(attachText)));
    });

    test('非管理员 A 访问每个管理端只读路由均为 403', () async {
      final adminGets = describeRoutes(
        harness.host,
      ).where((route) => route.method == 'GET' && route.access == 'admin');
      expect(adminGets, isNotEmpty);
      for (final route in adminGets) {
        final res = await harness.handle(
          'GET',
          fillPath(route.pattern, sweepParams()),
          token: alice.token,
        );
        expect(res.status, 403, reason: route.pattern);
      }
    });

    test('Router.describe() 每个 GET 读接口对 A 都不泄露 B 的正文/收藏/附件/密钥', () async {
      final reads = describeRoutes(
        harness.host,
      ).where((route) => route.method == 'GET').toList();
      expect(reads, isNotEmpty);
      final params = sweepParams();
      for (final route in reads) {
        final res = await harness.handle(
          'GET',
          fillPath(route.pattern, params),
          token: alice.token,
        );
        final body = res.json == null ? '' : jsonEncode(res.json);
        for (final secret in bSecrets) {
          expect(
            body,
            isNot(contains(secret)),
            reason: '${route.method} ${route.pattern} 泄露了 B 的秘密内容',
          );
        }
      }
    });

    test(
      '未覆盖：记忆域（memories）未装配，跨用户记忆串读未验证',
      () {},
      skip: '默认宿主未装配 memories 模块/路由；FR-67 记忆正文跨用户隔离在本基线未覆盖，'
          '不得以本文件其它断言推断为通过。',
    );

    test(
      '未覆盖：动态/日记/朋友圈域未装配',
      () {},
      skip: '默认宿主未装配 moments/diary 模块与路由；对应 AC-01 跨域串数据未覆盖。',
    );

    test(
      '未覆盖：客户端展示层账号隔离（M11）',
      () {},
      skip: 'M11 客户端外壳不在本票范围；客户端账号切换/展示隔离未验证。',
    );
  });
}
