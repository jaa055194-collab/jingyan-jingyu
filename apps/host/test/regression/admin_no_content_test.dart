/// AC-01 管理端无正文回归。
///
/// 用管理员 token 调每一个 `Access.admin` 只读路由，断言响应里搜不到已知正文、
/// 收藏内容、附件抽取正文与明文 key。唯一允许的例外是 02-decisions.md A-8 的
/// 旧版正文路由（`GET .../messages/{id}/edits` 只返回编辑前旧正文）。
///
/// 本测试是“可运行子集”：记忆正文未装配域以 skip 如实标注未覆盖。
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';

import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

import 'hardening_support.dart';

const String currentBody = '{{SECRET_k7l8m9n0}}';
const String oldBody = '{{SECRET_a8oldbody77}}';
const String favContent = '{{SECRET_q1w2e3r4}}';
const String attachText = '{{SECRET_t5y6u7i8}}';
const String providerKey = '{{SECRET_o9p0a1s2}}';

const List<String> nonExceptionSecrets = <String>[
  currentBody,
  oldBody,
  favContent,
  attachText,
  providerKey,
];

void main() {
  group('AC-01 管理端不返回他人正文 / 记忆正文 / 明文 key', () {
    late Harness harness;
    late TestUser admin;
    late TestUser bob;
    late String bobConversation;
    late String bobMessage;

    setUpAll(() async {
      harness = await Harness.boot();
      admin = await harness.seedAccount(
        displayName: 'Root',
        id: 'acct-admin',
        token: syntheticToken('z'),
        isAdmin: true,
      );
      bob = await harness.seedAccount(
        displayName: 'Bobby',
        id: 'acct-bob',
        token: syntheticToken('b'),
      );
      bobConversation = await createGroup(harness, bob.token, 'Bob group');
      bobMessage = await sendText(
        harness,
        bob.token,
        bobConversation,
        oldBody,
        'bob-admin-msg-1',
      );
      await editMessage(
        harness,
        bob.token,
        bobConversation,
        bobMessage,
        currentBody,
      );
      await addTextFavorite(harness, bob.token, 'fav-title', favContent);
      await uploadTextAttachment(
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

    Map<String, String> params() => <String, String>{
      'conversationId': bobConversation,
      'messageId': bobMessage,
      'attachmentId': 'probe',
      'accountId': bob.id,
    };

    test('每个管理端只读路由都不含正文 / 收藏 / 附件正文 / 明文 key（A-8 旧正文除外）', () async {
      final adminGets = describeRoutes(
        harness.host,
      ).where((route) => route.method == 'GET' && route.access == 'admin').toList();
      expect(adminGets, isNotEmpty);
      for (final route in adminGets) {
        final res = await harness.handle(
          'GET',
          fillPath(route.pattern, params()),
          token: admin.token,
        );
        expect(res.status, 200, reason: '${route.method} ${route.pattern}');
        final body = jsonEncode(res.json);
        final isEditHistory = route.pattern == Routes.messageEdits;
        for (final secret in nonExceptionSecrets) {
          if (isEditHistory && secret == oldBody) continue; // A-8 明确例外
          expect(
            body,
            isNot(contains(secret)),
            reason: '${route.method} ${route.pattern} 泄露了秘密内容',
          );
        }
      }
    });

    test('A-8 例外：管理端旧版正文路由返回编辑前正文（且仅此一类）', () async {
      final res = await harness.handle(
        'GET',
        fillPath(Routes.messageEdits, {
          'conversationId': bobConversation,
          'messageId': bobMessage,
        }),
        token: admin.token,
      );
      expect(res.status, 200);
      expect(jsonEncode(res.json), contains(oldBody));
      expect(jsonEncode(res.json), isNot(contains(currentBody)));
    });

    test('管理员账号列表只返回元数据，不含 B 的正文', () async {
      final res = await harness.handle(
        'GET',
        Routes.adminAccounts,
        token: admin.token,
      );
      expect(res.status, 200);
      expect(jsonEncode(res.json), isNot(contains(currentBody)));
    });

    test('管理端审计流不把正文写进 meta', () async {
      final res = await harness.handle(
        'GET',
        Routes.adminAudit,
        token: admin.token,
      );
      expect(res.status, 200);
      final body = jsonEncode(res.json);
      for (final secret in nonExceptionSecrets) {
        expect(body, isNot(contains(secret)));
      }
    });

    test(
      '未覆盖：记忆正文管理端隔离（memories 未装配）',
      () {},
      skip: '默认宿主未装配 memories 模块/管理端路由；AC-01“管理端不得返回记忆正文”'
          '在本基线无法验证，如实标未覆盖。',
    );
  });
}
