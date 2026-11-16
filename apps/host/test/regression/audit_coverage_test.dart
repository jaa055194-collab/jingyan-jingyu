/// 审计全覆盖回归（骨架 + 可运行子集）。
///
/// 目标：规定动作都要写审计。本文件对默认宿主当前已实现、且能在无外部依赖的
/// 条件下稳定触发的动作，逐一触发并通过 `audit_log` 表断言对应审计条目存在
/// （action + targetKind + targetId 精确匹配）。
///
/// 其余规定动作（需 AI 档案/好友图/多成员/真实模型的）在此环境不可稳定触发，
/// 在文件末尾以 skip 如实列出“未覆盖”，不伪造通过。
@Timeout(Duration(minutes: 10))
library;

import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

import 'hardening_support.dart';

Future<bool> hasAudit(
  Harness harness,
  String action,
  String targetKind,
  String targetId,
) async {
  final rows = await harness.auditRows();
  return rows.any(
    (row) =>
        row['action'] == action &&
        row['target_kind'] == targetKind &&
        row['target_id'] == targetId,
  );
}

void main() {
  group('规定动作写入审计', () {
    late Harness harness;
    late TestUser owner;

    setUpAll(() async {
      harness = await Harness.boot();
      owner = await harness.seedAccount(
        displayName: 'Owner',
        id: 'acct-owner',
        token: syntheticToken('o'),
      );
    });

    tearDownAll(() async {
      await harness.dispose();
    });

    test('message.edit 写审计（不含正文）', () async {
      final conversation = await createGroup(harness, owner.token, 'edit group');
      final messageId = await sendText(
        harness,
        owner.token,
        conversation,
        'before edit',
        'audit-edit-1',
      );
      await editMessage(
        harness,
        owner.token,
        conversation,
        messageId,
        'after edit',
      );
      expect(
        await hasAudit(harness, 'message.edit', 'message', messageId),
        isTrue,
      );
    });

    test('message.recall 写审计', () async {
      final conversation = await createGroup(
        harness,
        owner.token,
        'recall group',
      );
      final messageId = await sendText(
        harness,
        owner.token,
        conversation,
        'recall me',
        'audit-recall-1',
      );
      await recallMessage(harness, owner.token, conversation, messageId);
      expect(
        await hasAudit(harness, 'message.recall', 'message', messageId),
        isTrue,
      );
    });

    test('provider.create 写审计', () async {
      final providerId = await createProvider(
        harness,
        owner.token,
        name: 'audit provider',
        apiKey: 'k',
      );
      expect(
        await hasAudit(harness, 'provider.create', 'provider', providerId),
        isTrue,
      );
    });

    test('group.name.set 写审计', () async {
      final conversation = await createGroup(
        harness,
        owner.token,
        'name group',
      );
      final response = await harness.handle(
        'PUT',
        fillPath(Routes.groupName, {'conversationId': conversation}),
        token: owner.token,
        body: <String, Object?>{'name': 'Renamed group'},
      );
      expectOk(response, 'group rename');
      expect(
        await hasAudit(harness, 'group.name.set', 'conversation', conversation),
        isTrue,
      );
    });

    test('group.announcement.set 写审计', () async {
      final conversation = await createGroup(
        harness,
        owner.token,
        'announce group',
      );
      final response = await harness.handle(
        'PUT',
        fillPath(Routes.groupAnnouncement, {'conversationId': conversation}),
        token: owner.token,
        body: <String, Object?>{'text': 'hello all'},
      );
      expectOk(response, 'group announcement');
      expect(
        await hasAudit(
          harness,
          'group.announcement.set',
          'conversation',
          conversation,
        ),
        isTrue,
      );
    });

    test('topic.create 写审计', () async {
      final conversation = await createGroup(
        harness,
        owner.token,
        'topic group',
      );
      final root = await sendText(
        harness,
        owner.token,
        conversation,
        'root topic message',
        'audit-topic-root',
      );
      final response = await harness.handle(
        'POST',
        fillPath(Routes.groupTopics, {'conversationId': conversation}),
        token: owner.token,
        body: <String, Object?>{'rootMessageId': root},
      );
      expectOk(response, 'topic create');
      final topicId = asMap(response)['id'] as String;
      expect(
        await hasAudit(harness, 'topic.create', 'topic', topicId),
        isTrue,
      );
    });

    test('topic.reference.associate 写审计', () async {
      final conversation = await createGroup(
        harness,
        owner.token,
        'topic ref group',
      );
      final root = await sendText(
        harness,
        owner.token,
        conversation,
        'root for reference',
        'audit-topic-ref-root',
      );
      final created = await harness.handle(
        'POST',
        fillPath(Routes.groupTopics, {'conversationId': conversation}),
        token: owner.token,
        body: <String, Object?>{'rootMessageId': root},
      );
      expectOk(created, 'topic create for reference');
      final topicId = asMap(created)['id'] as String;
      final reply = await sendText(
        harness,
        owner.token,
        conversation,
        'reply under topic',
        'audit-topic-ref-reply',
      );
      final response = await harness.handle(
        'POST',
        fillPath(Routes.topicReferences, {'topicId': topicId}),
        token: owner.token,
        body: <String, Object?>{'messageId': reply},
      );
      expectOk(response, 'topic reference associate');
      expect(
        await hasAudit(
          harness,
          'topic.reference.associate',
          'topic',
          topicId,
        ),
        isTrue,
      );
    });

    // 以下动作在源码中确有审计写入点，但本离线子集无法稳定触发，如实标未覆盖。
    test(
      '未覆盖：budget.configure',
      () {},
      skip: '需要 owner 的 AI 档案与预算配置链路；本子集未创建 AI 档案，未触发。',
    );
    test(
      '未覆盖：binding.set / binding.clear',
      () {},
      skip: '需要 AI 档案 + provider 绑定矩阵；本子集未装配该链路，未触发。',
    );
    test(
      '未覆盖：direct.open',
      () {},
      skip: '需要好友同意图与私聊实体；本子集未构建好友图，未触发。',
    );
    test(
      '未覆盖：friendship.request/accept/deny/block',
      () {},
      skip: '需要两个账号的好友申请/同意状态机；本子集未覆盖，未触发。',
    );
    test(
      '未覆盖：ai.social_level.configure',
      () {},
      skip: '需要 owner 的 AI 档案与 social-level 路由；本子集未创建 AI 档案，未触发。',
    );
    test(
      '未覆盖：group.owner.transfer / group.member.remove / group.ai.withdraw',
      () {},
      skip: '需要多成员群与 AI 成员移除路径；本子集未构建，未触发。',
    );
  });
}
