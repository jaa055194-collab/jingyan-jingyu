import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/brain/classifier.dart';
import 'package:jingyu_host/src/brain/pacing.dart';
import 'package:jingyu_host/src/brain/router.dart';
import 'package:test/test.dart';

final AiId ai = AiId.parse('ai1');

IncomingMessage message(
  String text, {
  bool inGroup = false,
  bool mentioned = false,
}) => IncomingMessage(
  id: 'msg1',
  text: text,
  conversationId: ConversationId.parse('conv1'),
  senderId: AccountId.parse('user1'),
  inGroup: inGroup,
  mentioned: mentioned,
  roundId: 'round1',
);

class FakeS1Responder implements S1Responder {
  final List<bool> paddingFlags = <bool>[];
  S1Reply reply = const S1Reply('你好呀');
  S1Reply paddingReply = const S1Reply('嗯……让我想想');

  @override
  Future<S1Reply> replyTo(
    AiId ai,
    IncomingMessage message, {
    required bool padding,
  }) async {
    paddingFlags.add(padding);
    return padding ? paddingReply : reply;
  }
}

class FakeS2Responder implements S2Responder {
  int calls = 0;
  List<String> chunks = <String>['主回复'];

  @override
  Stream<String> respond(AiId ai, IncomingMessage message) async* {
    calls++;
    for (final String chunk in chunks) {
      yield chunk;
    }
  }
}

class FakeGroupPolicy implements GroupPostPolicy {
  FakeGroupPolicy({required this.allowed});

  final bool allowed;
  int calls = 0;

  @override
  Future<bool> mayPost(AiId ai, IncomingMessage message) async {
    calls++;
    return allowed;
  }
}

HumanPacing enabledPacing(FakeClock clock) => HumanPacing(clock: clock);

RulesFirstBrainRouter buildRouter({
  FakeS1Responder? s1,
  FakeS2Responder? s2,
  GroupPostPolicy? groupPolicy,
  HumanPacing? pacing,
  bool enablePadding = true,
  List<Duration>? sleeps,
}) {
  return RulesFirstBrainRouter(
    s1: s1 ?? FakeS1Responder(),
    s2: s2 ?? FakeS2Responder(),
    groupPolicy: groupPolicy,
    pacing: pacing,
    enablePadding: enablePadding,
    sleep: (Duration d) async {
      sleeps?.add(d);
    },
  );
}

void main() {
  group('RulesFirstBrainRouter.decide', () {
    test('simple greeting -> simple, no padding', () async {
      final RulesFirstBrainRouter router = buildRouter();
      final BrainDecision d = await router.decide(ai, message('你好'), inGroup: false);
      expect(d.complexity, Complexity.simple);
      expect(d.sendPadding, isFalse);
      expect(d.reasons, contains('greeting'));
    });

    test('question -> complex with padding by default', () async {
      final RulesFirstBrainRouter router = buildRouter();
      final BrainDecision d = await router.decide(ai, message('你吃饭了吗'), inGroup: false);
      expect(d.complexity, Complexity.complex);
      expect(d.sendPadding, isTrue);
      expect(d.reasons, contains('question'));
    });

    test('unsure (no rule) -> unsure with padding by default', () async {
      final RulesFirstBrainRouter router = buildRouter();
      final BrainDecision d =
          await router.decide(ai, message('今天天气很不错'), inGroup: false);
      expect(d.complexity, Complexity.unsure);
      expect(d.sendPadding, isTrue);
      expect(d.reasons, contains('noRule'));
    });

    test('padding disabled -> complex keeps complexity but sendPadding false', () async {
      final RulesFirstBrainRouter router = buildRouter(enablePadding: false);
      final BrainDecision d = await router.decide(ai, message('你吃饭了吗'), inGroup: false);
      expect(d.complexity, Complexity.complex);
      expect(d.sendPadding, isFalse);
    });

    test('inGroup appends the group reason without changing complexity', () async {
      final RulesFirstBrainRouter router = buildRouter();
      final BrainDecision d = await router.decide(ai, message('你好'), inGroup: true);
      expect(d.complexity, Complexity.simple);
      expect(d.reasons, contains('group'));
    });

    test('BrainDecision.reasons is unmodifiable', () async {
      final RulesFirstBrainRouter router = buildRouter();
      final BrainDecision d = await router.decide(ai, message('你好'), inGroup: false);
      expect(() => d.reasons.add('x'), throwsUnsupportedError);
    });
  });

  group('RulesFirstBrainRouter.respond routing (AC-33)', () {
    test('simple -> only S1, S2 never invoked', () async {
      final FakeS1Responder s1 = FakeS1Responder();
      final FakeS2Responder s2 = FakeS2Responder();
      final RulesFirstBrainRouter router = buildRouter(s1: s1, s2: s2);

      final BrainDecision d = await router.decide(ai, message('你好'), inGroup: false);
      final List<OutgoingPiece> out = await router.respond(ai, message('你好'), d).toList();

      expect(out, hasLength(1));
      expect(out.single.source, 's1');
      expect(out.single.text, '你好呀');
      expect(s1.paddingFlags, <bool>[false]);
      expect(s2.calls, 0, reason: 'simple replies must not invoke S2');
    });

    test('complex with padding -> S1 padding then S2 pieces', () async {
      final FakeS1Responder s1 = FakeS1Responder();
      final FakeS2Responder s2 = FakeS2Responder()..chunks = <String>['主', '回复'];
      final RulesFirstBrainRouter router = buildRouter(s1: s1, s2: s2);
      final IncomingMessage m = message('你吃饭了吗');

      final BrainDecision d = await router.decide(ai, m, inGroup: false);
      final List<OutgoingPiece> out = await router.respond(ai, m, d).toList();

      expect(out, hasLength(3));
      expect(out[0].source, 's1');
      expect(out[0].text, '嗯……让我想想');
      expect(out[1].source, 's2');
      expect(out[2].source, 's2');
      expect(s1.paddingFlags, <bool>[true]);
      expect(s2.calls, 1);
    });

    test('complex with padding disabled -> no S1, only S2', () async {
      final FakeS1Responder s1 = FakeS1Responder();
      final FakeS2Responder s2 = FakeS2Responder();
      final RulesFirstBrainRouter router =
          buildRouter(s1: s1, s2: s2, enablePadding: false);
      final IncomingMessage m = message('你吃饭了吗');

      final BrainDecision d = await router.decide(ai, m, inGroup: false);
      final List<OutgoingPiece> out = await router.respond(ai, m, d).toList();

      expect(out.every((OutgoingPiece p) => p.source == 's2'), isTrue);
      expect(s1.paddingFlags, isEmpty);
      expect(s2.calls, 1);
    });

    test('unsure escalates to S2', () async {
      final FakeS2Responder s2 = FakeS2Responder();
      final RulesFirstBrainRouter router = buildRouter(s2: s2);
      final IncomingMessage m = message('今天天气很不错');

      final BrainDecision d = await router.decide(ai, m, inGroup: false);
      await router.respond(ai, m, d).toList();

      expect(d.complexity, Complexity.unsure);
      expect(s2.calls, 1);
    });

    test('S1 activityRefs are carried onto the outbound piece', () async {
      final FakeS1Responder s1 = FakeS1Responder()
        ..reply = const S1Reply('我刚浇完花', activityRefs: <String>['act-42']);
      final RulesFirstBrainRouter router = buildRouter(s1: s1);
      final IncomingMessage m = message('你在干嘛');

      final BrainDecision d = await router.decide(ai, m, inGroup: false);
      final List<OutgoingPiece> out = await router.respond(ai, m, d).toList();

      expect(out.first.source, 's1');
      expect(out.first.activityRefs, <String>['act-42']);
    });
  });

  group('Group gating', () {
    test('denied group post yields no output and no responder calls', () async {
      final FakeS1Responder s1 = FakeS1Responder();
      final FakeS2Responder s2 = FakeS2Responder();
      final FakeGroupPolicy policy = FakeGroupPolicy(allowed: false);
      final RulesFirstBrainRouter router =
          buildRouter(s1: s1, s2: s2, groupPolicy: policy);
      final IncomingMessage m = message('你吃饭了吗', inGroup: true);

      final BrainDecision d = await router.decide(ai, m, inGroup: true);
      final List<OutgoingPiece> out = await router.respond(ai, m, d).toList();

      expect(out, isEmpty);
      expect(policy.calls, 1);
      expect(s1.paddingFlags, isEmpty);
      expect(s2.calls, 0);
    });

    test('allowed group post proceeds normally', () async {
      final FakeGroupPolicy policy = FakeGroupPolicy(allowed: true);
      final RulesFirstBrainRouter router = buildRouter(groupPolicy: policy);
      final IncomingMessage m = message('你好', inGroup: true);

      final BrainDecision d = await router.decide(ai, m, inGroup: true);
      final List<OutgoingPiece> out = await router.respond(ai, m, d).toList();

      expect(policy.calls, 1);
      expect(out, hasLength(1));
    });

    test('private messages never consult the group policy', () async {
      final FakeGroupPolicy policy = FakeGroupPolicy(allowed: false);
      final RulesFirstBrainRouter router = buildRouter(groupPolicy: policy);
      final IncomingMessage m = message('你好', inGroup: false);

      final BrainDecision d = await router.decide(ai, m, inGroup: false);
      final List<OutgoingPiece> out = await router.respond(ai, m, d).toList();

      expect(policy.calls, 0);
      expect(out, hasLength(1));
    });
  });

  group('Pacing integration', () {
    test('complex path waits a human-like delay before S2', () async {
      final List<Duration> sleeps = <Duration>[];
      final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 15, 12));
      final RulesFirstBrainRouter router = buildRouter(
        pacing: enabledPacing(clock),
        sleeps: sleeps,
      );
      final IncomingMessage m = message('你吃饭了吗');

      final BrainDecision d = await router.decide(ai, m, inGroup: false);
      await router.respond(ai, m, d).toList();

      expect(sleeps, hasLength(1));
      expect(sleeps.single >= const Duration(seconds: 1), isTrue);
      expect(sleeps.single <= const Duration(seconds: 4), isTrue);
    });

    test('disabled pacing emits no delay but still replies', () async {
      final List<Duration> sleeps = <Duration>[];
      final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 15, 12));
      final RulesFirstBrainRouter router = buildRouter(
        pacing: HumanPacing(clock: clock, enabled: false),
        sleeps: sleeps,
      );
      final IncomingMessage m = message('你好');

      final BrainDecision d = await router.decide(ai, m, inGroup: false);
      final List<OutgoingPiece> out = await router.respond(ai, m, d).toList();

      expect(sleeps, isEmpty);
      expect(out, hasLength(1));
    });

    test('no pacing configured means no delay', () async {
      final List<Duration> sleeps = <Duration>[];
      final RulesFirstBrainRouter router = buildRouter(sleeps: sleeps);
      final IncomingMessage m = message('你吃饭了吗');

      final BrainDecision d = await router.decide(ai, m, inGroup: false);
      await router.respond(ai, m, d).toList();

      expect(sleeps, isEmpty);
    });
  });
}
