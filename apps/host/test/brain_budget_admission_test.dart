import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/brain/budget_policy.dart';
import 'package:jingyu_host/src/brain/classifier.dart';
import 'package:jingyu_host/src/brain/pacing.dart';
import 'package:jingyu_host/src/brain/router.dart';
import 'package:test/test.dart';

final AiId ai = AiId.parse('ai1');
final ConversationId privateConv = ConversationId.parse('private1');

IncomingMessage message(String text, {bool inGroup = false}) => IncomingMessage(
  id: 'message1',
  text: text,
  conversationId: inGroup ? ConversationId.parse('group1') : privateConv,
  senderId: AccountId.parse('user1'),
  inGroup: inGroup,
);

class FakeS1 implements S1Responder {
  final List<bool> paddingFlags = <bool>[];
  int calls = 0;
  S1Reply reply = const S1Reply('你好呀');
  S1Reply padding = const S1Reply('嗯……');

  @override
  Future<S1Reply> replyTo(
    AiId ai,
    IncomingMessage message, {
    required bool padding,
  }) async {
    calls++;
    paddingFlags.add(padding);
    return padding ? this.padding : reply;
  }
}

class FakeS2 implements S2Responder {
  int calls = 0;
  final List<String> chunks = <String>['主', '回复'];

  @override
  Stream<String> respond(AiId ai, IncomingMessage message) async* {
    calls++;
    for (final String chunk in chunks) {
      yield chunk;
    }
  }
}

class FakeGroup implements GroupPostPolicy {
  FakeGroup(this.allowed);
  final bool allowed;
  int calls = 0;

  @override
  Future<bool> mayPost(AiId ai, IncomingMessage message) async {
    calls++;
    return allowed;
  }
}

class FakeAdmission implements BrainAdmission {
  FakeAdmission(this.result);
  Result<BrainDisposition> result;
  int calls = 0;
  Complexity? lastComplexity;
  ConversationId? lastConversation;

  @override
  Future<Result<BrainDisposition>> admit(
    AiId ai, {
    required ConversationId? conversationId,
    required Complexity complexity,
  }) async {
    calls++;
    lastConversation = conversationId;
    lastComplexity = complexity;
    return result;
  }
}

RulesFirstBrainRouter buildRouter({
  FakeS1? s1,
  FakeS2? s2,
  FakeGroup? group,
  BrainAdmission? admission,
  HumanPacing? pacing,
  bool enablePadding = true,
  List<Duration>? sleeps,
}) => RulesFirstBrainRouter(
  s1: s1 ?? FakeS1(),
  s2: s2 ?? FakeS2(),
  groupPolicy: group,
  admission: admission,
  pacing: pacing,
  enablePadding: enablePadding,
  sleep: (Duration d) async {
    sleeps?.add(d);
  },
);

void main() {
  group('BrainBudgetPolicy boundaries', () {
    Future<BrainDisposition> decide(
      BrainBudgetSnapshot snapshot,
      Complexity complexity,
    ) async {
      final Result<BrainDisposition> r = await BrainBudgetPolicy(
        snapshot: (_, _) async => Ok<BrainBudgetSnapshot>(snapshot),
      ).admit(ai, conversationId: privateConv, complexity: complexity);
      return r.value;
    }

    test('normal budget proceeds on every complexity', () async {
      const BrainBudgetSnapshot s = BrainBudgetSnapshot();
      expect(await decide(s, Complexity.simple), BrainDisposition.proceed);
      expect(await decide(s, Complexity.complex), BrainDisposition.proceed);
      expect(await decide(s, Complexity.unsure), BrainDisposition.proceed);
    });

    test('B2 exhausted keeps owner private slow replies', () async {
      const BrainBudgetSnapshot s = BrainBudgetSnapshot(
        slowLayerExhausted: true,
        trustedOwnerPrivate: true,
      );
      expect(await decide(s, Complexity.complex), BrainDisposition.proceed);
      expect(await decide(s, Complexity.unsure), BrainDisposition.proceed);
    });

    test('B2 exhausted defers non-owner slow replies', () async {
      const BrainBudgetSnapshot s = BrainBudgetSnapshot(
        slowLayerExhausted: true,
      );
      expect(await decide(s, Complexity.complex), BrainDisposition.deferSlow);
      expect(await decide(s, Complexity.unsure), BrainDisposition.deferSlow);
    });

    test('B2 exhaustion never blocks a simple S1 reply', () async {
      const BrainBudgetSnapshot s = BrainBudgetSnapshot(
        slowLayerExhausted: true,
      );
      expect(await decide(s, Complexity.simple), BrainDisposition.proceed);
    });

    test('global hard stop is silent for every complexity and owner', () async {
      const BrainBudgetSnapshot s = BrainBudgetSnapshot(
        globalHardStop: true,
        trustedOwnerPrivate: true,
      );
      expect(await decide(s, Complexity.simple), BrainDisposition.silent);
      expect(await decide(s, Complexity.complex), BrainDisposition.silent);
    });

    test('capability hard stop is silent even for owner private', () async {
      const BrainBudgetSnapshot s = BrainBudgetSnapshot(
        capabilityHardStop: true,
        trustedOwnerPrivate: true,
      );
      expect(await decide(s, Complexity.complex), BrainDisposition.silent);
    });

    test('resolver failure propagates as Err', () async {
      final Result<BrainDisposition> r = await BrainBudgetPolicy(
        snapshot: (_, _) async =>
            err<BrainBudgetSnapshot>(FailureCode.internal, 'boom'),
      ).admit(ai, conversationId: privateConv, complexity: Complexity.complex);
      expect(r, isA<Err<BrainDisposition>>());
    });
  });

  group('RulesFirstBrainRouter admission seam', () {
    test('proceed leaves the reviewed routing unchanged', () async {
      final FakeS1 s1 = FakeS1();
      final FakeS2 s2 = FakeS2();
      final FakeAdmission admission = FakeAdmission(
        const Ok<BrainDisposition>(BrainDisposition.proceed),
      );
      final router = buildRouter(s1: s1, s2: s2, admission: admission);

      final d = await router.decide(ai, message('你吃饭了吗'), inGroup: false);
      final out = await router.respond(ai, message('你吃饭了吗'), d).toList();

      expect(out.map((p) => p.source), <String>['s1', 's2', 's2']);
      expect(s1.paddingFlags, <bool>[true]);
      expect(s2.calls, 1);
      expect(admission.calls, 1);
      expect(admission.lastComplexity, Complexity.complex);
    });

    test(
      'deferSlow emits only a single S2 "稍后回" without padding or model',
      () async {
        final FakeS1 s1 = FakeS1();
        final FakeS2 s2 = FakeS2();
        final List<Duration> sleeps = <Duration>[];
        final router = buildRouter(
          s1: s1,
          s2: s2,
          // Pacing is enabled so the empty `sleeps` proves the defer path
          // really skips pacing rather than skipping it only because it is off.
          pacing: HumanPacing(clock: FakeClock(DateTime.utc(2026, 11, 15))),
          admission: FakeAdmission(
            const Ok<BrainDisposition>(BrainDisposition.deferSlow),
          ),
          sleeps: sleeps,
        );

        final d = await router.decide(ai, message('你吃饭了吗'), inGroup: false);
        final out = await router.respond(ai, message('你吃饭了吗'), d).toList();

        expect(out, hasLength(1));
        expect(out.single.source, 's2');
        expect(out.single.text, '稍后回');
        expect(out.single.activityRefs, isEmpty);
        expect(s1.calls, 0);
        expect(s2.calls, 0);
        expect(sleeps, isEmpty);
      },
    );

    test('silent hard stop suppresses even a simple greeting', () async {
      final FakeS1 s1 = FakeS1();
      final FakeS2 s2 = FakeS2();
      final router = buildRouter(
        s1: s1,
        s2: s2,
        admission: FakeAdmission(
          const Ok<BrainDisposition>(BrainDisposition.silent),
        ),
      );

      final d = await router.decide(ai, message('你好'), inGroup: false);
      final out = await router.respond(ai, message('你好'), d).toList();

      expect(out, isEmpty);
      expect(s1.calls, 0);
      expect(s2.calls, 0);
    });

    test(
      'silent hard stop suppresses complex replies before padding',
      () async {
        final FakeS1 s1 = FakeS1();
        final FakeS2 s2 = FakeS2();
        final router = buildRouter(
          s1: s1,
          s2: s2,
          admission: FakeAdmission(
            const Ok<BrainDisposition>(BrainDisposition.silent),
          ),
        );

        final d = await router.decide(ai, message('你吃饭了吗'), inGroup: false);
        final out = await router.respond(ai, message('你吃饭了吗'), d).toList();

        expect(out, isEmpty);
        expect(s1.calls, 0);
        expect(s2.calls, 0);
      },
    );

    test('unsure escalates then defers when B2 is exhausted', () async {
      final FakeS2 s2 = FakeS2();
      final router = buildRouter(
        s2: s2,
        admission: FakeAdmission(
          const Ok<BrainDisposition>(BrainDisposition.deferSlow),
        ),
      );

      final m = message('今天天气很不错');
      final d = await router.decide(ai, m, inGroup: false);
      expect(d.complexity, Complexity.unsure);
      final out = await router.respond(ai, m, d).toList();
      expect(out.map((p) => p.text), <String>['稍后回']);
      expect(s2.calls, 0);
    });

    test('group denial short-circuits before budget admission', () async {
      final FakeGroup group = FakeGroup(false);
      final FakeAdmission admission = FakeAdmission(
        const Ok<BrainDisposition>(BrainDisposition.proceed),
      );
      final router = buildRouter(group: group, admission: admission);

      final m = message('你吃饭了吗', inGroup: true);
      final d = await router.decide(ai, m, inGroup: true);
      final out = await router.respond(ai, m, d).toList();

      expect(out, isEmpty);
      expect(group.calls, 1);
      expect(admission.calls, 0);
    });

    test('resolver error fails closed without any reply', () async {
      final FakeS1 s1 = FakeS1();
      final FakeS2 s2 = FakeS2();
      final router = buildRouter(
        s1: s1,
        s2: s2,
        admission: FakeAdmission(
          err<BrainDisposition>(FailureCode.budgetExhausted, 'lookup failed'),
        ),
      );

      final d = await router.decide(ai, message('你吃饭了吗'), inGroup: false);
      final out = await router.respond(ai, message('你吃饭了吗'), d).toList();

      expect(out, isEmpty);
      expect(s1.calls, 0);
      expect(s2.calls, 0);
    });

    test(
      'a thrown resolver fails closed without escaping the stream',
      () async {
        final FakeS1 s1 = FakeS1();
        final FakeS2 s2 = FakeS2();
        final router = buildRouter(
          s1: s1,
          s2: s2,
          admission: BrainBudgetPolicy(
            snapshot: (_, _) async => throw StateError('adapter bug'),
          ),
        );

        final d = await router.decide(ai, message('你吃饭了吗'), inGroup: false);
        final out = await router.respond(ai, message('你吃饭了吗'), d).toList();
        expect(out, isEmpty);
        expect(s1.calls, 0);
        expect(s2.calls, 0);
      },
    );

    test(
      'real policy: B2 exhaustion still lets a simple greeting reach S1',
      () async {
        final FakeS1 s1 = FakeS1();
        final FakeS2 s2 = FakeS2();
        final router = buildRouter(
          s1: s1,
          s2: s2,
          admission: BrainBudgetPolicy(
            snapshot: (_, _) async => const Ok<BrainBudgetSnapshot>(
              BrainBudgetSnapshot(slowLayerExhausted: true),
            ),
          ),
        );

        final d = await router.decide(ai, message('你好'), inGroup: false);
        expect(d.complexity, Complexity.simple);
        final out = await router.respond(ai, message('你好'), d).toList();
        expect(out.map((p) => p.source), <String>['s1']);
        expect(s1.calls, 1);
        expect(s2.calls, 0);
      },
    );

    test(
      'real policy: capability hard stop silences a simple greeting',
      () async {
        final FakeS1 s1 = FakeS1();
        final FakeS2 s2 = FakeS2();
        final router = buildRouter(
          s1: s1,
          s2: s2,
          admission: BrainBudgetPolicy(
            snapshot: (_, _) async => const Ok<BrainBudgetSnapshot>(
              BrainBudgetSnapshot(capabilityHardStop: true),
            ),
          ),
        );

        final d = await router.decide(ai, message('你好'), inGroup: false);
        final out = await router.respond(ai, message('你好'), d).toList();
        expect(out, isEmpty);
        expect(s1.calls, 0);
        expect(s2.calls, 0);
      },
    );
  });
}
