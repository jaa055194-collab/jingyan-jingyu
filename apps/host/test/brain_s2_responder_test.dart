import 'dart:async';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/brain/domain_packs.dart';
import 'package:jingyu_host/src/brain/router.dart';
import 'package:jingyu_host/src/brain/s1_responder.dart';
import 'package:jingyu_host/src/brain/s2_responder.dart';
import 'package:test/test.dart';

final AiId ai = AiId.parse('ai1');
final AiId otherAi = AiId.parse('ai2');
IncomingMessage message(String text, {bool inGroup = false}) => IncomingMessage(
  id: 'message1',
  text: text,
  senderId: AccountId.parse('user1'),
  conversationId: ConversationId.parse('conversation1'),
  inGroup: inGroup,
);

DomainPackRegistry registry({String glossary = '异步任务', int maxChars = 500}) =>
    DomainPackRegistry(
      packs: <DomainPack>[
        DomainPack(
          domain: '编程',
          keywords: <String>['Dart'],
          glossary: glossary,
        ),
      ],
      knownDomains: <String>['球赛'],
      maxChars: maxChars,
    );

class Generation implements S2Generation {
  final List<DomainInjection> domains = <DomainInjection>[];
  final List<AiId> ais = <AiId>[];
  final List<IncomingMessage> messages = <IncomingMessage>[];
  Stream<String> Function()? output;

  @override
  Stream<String> respond(
    AiId ai,
    IncomingMessage message, {
    required DomainInjection domain,
  }) {
    ais.add(ai);
    messages.add(message);
    domains.add(domain);
    return output?.call() ?? Stream<String>.fromIterable(<String>['主', '回复']);
  }
}

class DenyGroup implements GroupPostPolicy {
  @override
  Future<bool> mayPost(AiId ai, IncomingMessage message) async => false;
}

void main() {
  test(
    'AC-34 supplies a separate per-turn card and preserves stream chunks',
    () async {
      final generation = Generation();
      final responder = DomainAwareS2Responder(
        domains: (_, _) async => registry(),
        generation: generation,
      );
      final incoming = message('Dart 怎么用？');
      expect(await responder.respond(ai, incoming).toList(), <String>[
        '主',
        '回复',
      ]);
      expect(generation.messages.single, same(incoming));
      expect(incoming.text, 'Dart 怎么用？');
      final domain = generation.domains.single;
      expect(domain.status, DomainInjectionStatus.injected);
      expect(domain.domain, '编程');
      expect(domain.text, '术语：异步任务');
      expect(domain.ephemeral, isTrue);
    },
  );

  test(
    'AC-34 known domain without a card refuses without generation',
    () async {
      final generation = Generation();
      final responder = DomainAwareS2Responder(
        domains: (_, _) async => registry(),
        generation: generation,
      );
      expect(await responder.respond(ai, message('球赛谁赢？')).toList(), <String>[
        '这个我不熟',
      ]);
      expect(generation.domains, isEmpty);
    },
  );

  test('AC-34 unrelated next turn does not retain the earlier card', () async {
    final generation = Generation();
    final responder = DomainAwareS2Responder(
      domains: (_, _) async => registry(),
      generation: generation,
    );
    await responder.respond(ai, message('Dart')).drain<void>();
    await responder.respond(ai, message('今天心情如何？')).drain<void>();
    expect(generation.domains.last.status, DomainInjectionStatus.none);
    expect(generation.domains.last.text, isEmpty);
    expect(generation.domains.first.text, '术语：异步任务');
  });

  test(
    'AC-34 caps an oversized configured registry at 500 Unicode code points',
    () async {
      final generation = Generation();
      final responder = DomainAwareS2Responder(
        domains: (_, _) async => registry(glossary: '😀' * 700, maxChars: 1000),
        generation: generation,
      );
      await responder.respond(ai, message('Dart')).drain<void>();
      final text = generation.domains.single.text;
      expect(text.runes.length, 500);
      expect(text, '术语：${'😀' * 496}…');
      expect(text.contains('\uFFFD'), isFalse);
    },
  );

  test(
    'AC-01 resolves current AI and message on every turn without a shared cache',
    () async {
      final generation = Generation();
      final lookups = <IncomingMessage>[];
      final responder = DomainAwareS2Responder(
        domains: (currentAi, incoming) async {
          lookups.add(incoming);
          return currentAi == ai
              ? registry(glossary: incoming.id)
              : DomainPackRegistry();
        },
        generation: generation,
      );
      final first = message('Dart');
      final second = message('Dart');
      await responder.respond(ai, first).drain<void>();
      await responder.respond(otherAi, second).drain<void>();
      expect(lookups, <IncomingMessage>[first, second]);
      expect(generation.ais, <AiId>[ai, otherAi]);
      expect(generation.domains.first.text, '术语：message1');
      expect(generation.domains.last.status, DomainInjectionStatus.none);
    },
  );

  test(
    'AC-01 same AI in different conversations receives distinct cards',
    () async {
      final generation = Generation();
      final responder = DomainAwareS2Responder(
        domains: (_, incoming) async =>
            registry(glossary: incoming.conversationId!.value),
        generation: generation,
      );
      for (final id in <String>['private1', 'group2']) {
        await responder
            .respond(
              ai,
              IncomingMessage(
                id: 'msg-$id',
                text: 'Dart',
                conversationId: ConversationId.parse(id),
              ),
            )
            .drain<void>();
      }
      expect(generation.domains.map((d) => d.text), <String>[
        '术语：private1',
        '术语：group2',
      ]);
    },
  );

  test('AC-01 concurrent registry lookups keep cards request-local', () async {
    final first = Completer<DomainPackRegistry>();
    final second = Completer<DomainPackRegistry>();
    final generation = Generation();
    final responder = DomainAwareS2Responder(
      domains: (currentAi, _) => currentAi == ai ? first.future : second.future,
      generation: generation,
    );
    final one = responder.respond(ai, message('Dart')).toList();
    final two = responder.respond(otherAi, message('Dart')).toList();
    second.complete(registry(glossary: 'second'));
    await two;
    first.complete(registry(glossary: 'first'));
    await one;
    expect(generation.ais, <AiId>[otherAi, ai]);
    expect(generation.domains.map((d) => d.text), <String>[
      '术语：second',
      '术语：first',
    ]);
  });

  test('lookup failure emits no answer and never starts generation', () async {
    final failure = StateError('lookup denied');
    final generation = Generation();
    final responder = DomainAwareS2Responder(
      domains: (_, _) async => throw failure,
      generation: generation,
    );
    await expectLater(
      responder.respond(ai, message('Dart')),
      emitsError(same(failure)),
    );
    expect(generation.domains, isEmpty);
  });

  test('generation error after a chunk is propagated without retry', () async {
    final failure = StateError('generation failed');
    final generation = Generation()
      ..output = () async* {
        yield 'partial';
        throw failure;
      };
    final responder = DomainAwareS2Responder(
      domains: (_, _) async => registry(),
      generation: generation,
    );
    await expectLater(
      responder.respond(ai, message('Dart')),
      emitsInOrder(<Object>['partial', emitsError(same(failure)), emitsDone]),
    );
    expect(generation.domains, hasLength(1));
  });

  test(
    'cancelling during lookup never starts generation after resolution',
    () async {
      final lookup = Completer<DomainPackRegistry>();
      final started = Completer<void>();
      final generation = Generation();
      final responder = DomainAwareS2Responder(
        domains: (_, _) {
          started.complete();
          return lookup.future;
        },
        generation: generation,
      );
      final subscription = responder
          .respond(ai, message('Dart'))
          .listen((_) {});
      await started.future;
      await subscription.cancel(); // Must not wait for the resolver to settle.
      lookup.complete(registry());
      await lookup.future;
      await Future<void>.value();
      expect(generation.domains, isEmpty);
    },
  );

  test('cancelling S2 cancels the generation subscription', () async {
    final cancelled = Completer<void>();
    final controller = StreamController<String>(
      onCancel: () => cancelled.complete(),
    );
    addTearDown(() {
      unawaited(controller.close());
    });
    final generation = Generation()..output = () => controller.stream;
    final responder = DomainAwareS2Responder(
      domains: (_, _) async => registry(),
      generation: generation,
    );
    final subscription = responder.respond(ai, message('Dart')).listen((_) {});
    // Wait for the real generation subscription, not a time-based sleep.
    final subscribed = Completer<void>();
    controller.onListen = () => subscribed.complete();
    await subscribed.future;
    await subscription.cancel();
    await cancelled.future;
    expect(generation.domains, hasLength(1));
  });

  test(
    'AC-33 real router keeps S1 padding then domain-aware S2 chunks',
    () async {
      final generation = Generation();
      final router = RulesFirstBrainRouter(
        s1: const RulesS1Responder(),
        s2: DomainAwareS2Responder(
          domains: (_, _) async => registry(),
          generation: generation,
        ),
      );
      final incoming = message('Dart 怎么用？');
      final decision = await router.decide(ai, incoming, inGroup: false);
      final pieces = await router.respond(ai, incoming, decision).toList();
      expect(pieces.map((p) => p.source), <String>['s1', 's2', 's2']);
      expect(pieces.map((p) => p.text), <String>['嗯……', '主', '回复']);
      expect(generation.domains.single.text, '术语：异步任务');
    },
  );

  test('AC-33 simple and denied-group routes never resolve domains', () async {
    var lookups = 0;
    final generation = Generation();
    final router = RulesFirstBrainRouter(
      s1: const RulesS1Responder(),
      s2: DomainAwareS2Responder(
        domains: (_, _) async {
          lookups++;
          return registry();
        },
        generation: generation,
      ),
      groupPolicy: DenyGroup(),
    );
    for (final incoming in <IncomingMessage>[
      message('你好'),
      message('Dart？', inGroup: true),
    ]) {
      final decision = await router.decide(
        ai,
        incoming,
        inGroup: incoming.inGroup,
      );
      final pieces = await router.respond(ai, incoming, decision).toList();
      expect(
        pieces.map((p) => p.source),
        incoming.inGroup ? isEmpty : <String>['s1'],
      );
    }
    expect(lookups, 0);
    expect(generation.domains, isEmpty);
  });
}
