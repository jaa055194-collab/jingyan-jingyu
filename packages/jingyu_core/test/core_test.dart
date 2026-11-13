import 'package:jingyu_core/jingyu_core.dart';
import 'package:test/test.dart';

void main() {
  group('标识', () {
    test('合法标识保留原值', () {
      expect(AccountId.parse('acc_01').value, 'acc_01');
      expect(MessageId.parse('m-1').kind, 'message');
    });

    test('非法标识抛 FormatException', () {
      for (final bad in ['', 'a b', 'a/b', 'a\$b', 'x' * 65, '标识']) {
        expect(() => AccountId.parse(bad), throwsFormatException,
            reason: '应拒绝 "$bad"');
      }
    });

    test('不同标识类型即使值相同也不相等', () {
      final account = AccountId.parse('same');
      final ai = AiId.parse('same');
      expect(account == ai, isFalse);
      expect(account == AccountId.parse('same'), isTrue);
    });
  });

  group('Result', () {
    test('Ok 传递值，Err 传递失败', () {
      final okValue = ok<int>(3).map((v) => v * 2);
      expect(okValue.valueOrNull, 6);
      expect(okValue.isOk, isTrue);

      final failed = err<int>(FailureCode.forbidden, '无权限')
          .map((v) => v * 2);
      expect(failed.failureOrNull?.code, FailureCode.forbidden);
      expect(failed.isErr, isTrue);
    });

    test('flatMap 在失败时短路', () {
      var called = false;
      final result = err<int>(FailureCode.notFound, '不存在').flatMap((v) {
        called = true;
        return ok<String>('$v');
      });
      expect(called, isFalse);
      expect(result.failureOrNull?.code, FailureCode.notFound);
    });
  });

  group('可见性', () {
    test('self 只有本人可见', () {
      expect(Audience.self.allows(isSelf: true, isFriend: false), isTrue);
      expect(Audience.self.allows(isSelf: false, isFriend: true), isFalse);
    });

    test('friends 本人与好友可见', () {
      expect(Audience.friends.allows(isSelf: false, isFriend: true), isTrue);
      expect(Audience.friends.allows(isSelf: false, isFriend: false), isFalse);
    });

    test('circle 圈内全部可见', () {
      expect(Audience.circle.allows(isSelf: false, isFriend: false), isTrue);
    });

    test('拉黑阻断一切非自我可见', () {
      const viewer = ViewerContext(
        viewerId: 'a',
        ownerId: 'b',
        isFriend: true,
        isBlocked: true,
      );
      expect(viewer.canSee(Audience.circle).valueOrNull, isFalse);
      expect(
        const ViewerContext(viewerId: 'b', ownerId: 'b', isBlocked: true)
            .canSee(Audience.self)
            .valueOrNull,
        isTrue,
      );
    });
  });

  group('记忆分层', () {
    const policy = MemoryPolicy();

    test('"别记"是禁止采集，不是降级到 T2', () {
      expect(policy.collectionDecision(userOptedOut: true),
          CollectionDecision.deny);
      expect(policy.collectionDecision(userOptedOut: false),
          CollectionDecision.allow);
    });

    test('重叠分层取最严格者', () {
      expect(
        policy.resolveTier([MemoryTier.t0, MemoryTier.t2, MemoryTier.t1]),
        MemoryTier.t2,
      );
      expect(policy.resolveTier([MemoryTier.t0]), MemoryTier.t0);
      expect(policy.resolveTier(const []), MemoryTier.t0);
    });

    test('只有用户确认/用户陈述可默认 active', () {
      expect(policy.mayActivateByDefault(EvidenceLevel.userConfirmed), isTrue);
      expect(policy.mayActivateByDefault(EvidenceLevel.userStated), isTrue);
      expect(policy.mayActivateByDefault(EvidenceLevel.inferred), isFalse);
      expect(policy.mayActivateByDefault(EvidenceLevel.modelClaim), isFalse);
    });

    test('T1 即使证据够格也要 pending', () {
      expect(
        policy.initialStatus(
          tier: MemoryTier.t1,
          level: EvidenceLevel.userStated,
        ),
        MemoryStatus.pending,
      );
      expect(
        policy.initialStatus(
          tier: MemoryTier.t0,
          level: EvidenceLevel.userStated,
        ),
        MemoryStatus.active,
      );
      expect(
        policy.initialStatus(
          tier: MemoryTier.t0,
          level: EvidenceLevel.inferred,
        ),
        MemoryStatus.pending,
      );
    });

    test('pending 不注入；T2 只给主人自己的 AI', () {
      expect(
        policy.mayInject(
          status: MemoryStatus.pending,
          tier: MemoryTier.t1,
          forOwnerAi: true,
        ),
        isFalse,
      );
      expect(
        policy.mayInject(
          status: MemoryStatus.active,
          tier: MemoryTier.t2,
          forOwnerAi: false,
        ),
        isFalse,
      );
      expect(
        policy.mayInject(
          status: MemoryStatus.active,
          tier: MemoryTier.t2,
          forOwnerAi: true,
        ),
        isTrue,
      );
    });

    test('T2 不进导出包', () {
      expect(policy.mayExport(tier: MemoryTier.t1), isTrue);
      expect(policy.mayExport(tier: MemoryTier.t2), isFalse);
    });

    test('状态机只允许既定迁移', () {
      expect(policy.canTransition(MemoryStatus.pending, MemoryStatus.active),
          isTrue);
      expect(policy.canTransition(MemoryStatus.pending, MemoryStatus.deleted),
          isFalse);
      expect(
          policy.canTransition(MemoryStatus.active, MemoryStatus.superseded),
          isTrue);
      expect(policy.canTransition(MemoryStatus.rejected, MemoryStatus.pending),
          isTrue);
      expect(policy.canTransition(MemoryStatus.deleted, MemoryStatus.pending),
          isFalse);
    });

    test('scope 键区分私聊/群/话题', () {
      expect(
        const PrivateScope(aiId: 'ai1', ownerId: 'u1').key,
        'private:ai1:u1',
      );
      expect(
        const GroupScope(aiId: 'ai1', conversationId: 'c1').key,
        'group:ai1:c1',
      );
      expect(
        const TopicScope(aiId: 'ai1', conversationId: 'c1', topicId: 't1').key,
        'topic:ai1:c1:t1',
      );
    });
  });

  group('预算', () {
    test('按默认占比切分日预算', () {
      final layers = splitDailyBudget(1000);
      expect(layers[BudgetLayer.b0Life]!.totalTokens, 100);
      expect(layers[BudgetLayer.b1FastBrain]!.totalTokens, 150);
      expect(layers[BudgetLayer.b2DeepChat]!.totalTokens, 600);
      expect(layers[BudgetLayer.b3Proactive]!.totalTokens, 100);
      expect(layers[BudgetLayer.b4Maintenance]!.totalTokens, 50);
    });

    test('80% 提示、100% 降级', () {
      const warn = LayerBudget(
        layer: BudgetLayer.b2DeepChat,
        totalTokens: 100,
        usedTokens: 80,
      );
      expect(warn.level, DegradeLevel.warn);
      const full = LayerBudget(
        layer: BudgetLayer.b2DeepChat,
        totalTokens: 100,
        usedTokens: 100,
      );
      expect(full.level, DegradeLevel.degraded);
      expect(full.tryConsume(1), isFalse);
    });

    test('日切键按指定时区偏移换算', () {
      final clock = FakeClock(DateTime.utc(2026, 11, 13, 20, 30));
      expect(currentDayKey(clock), '2026-11-13');
      expect(
        currentDayKey(clock, utcOffset: const Duration(hours: 8)),
        '2026-11-14',
      );
    });
  });
}
