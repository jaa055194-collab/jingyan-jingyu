import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/brain/classifier.dart';
import 'package:jingyu_host/src/brain/meme_library.dart';
import 'package:jingyu_host/src/brain/meme_s1_responder.dart';
import 'package:jingyu_host/src/brain/router.dart';
import 'package:test/test.dart';

final AiId ai = AiId.parse('ai1');
final DateTime now = DateTime.utc(2026, 11, 15, 12);

IncomingMessage message(String text) => IncomingMessage(
  id: 'm1',
  text: text,
  conversationId: ConversationId.parse('c1'),
);

Meme meme(
  String id,
  MemeLayer layer,
  String reply, {
  List<String> keywords = const <String>[],
  List<String> regex = const <String>[],
  DateTime? expiresAt,
}) => Meme(
  id: id,
  layer: layer,
  reply: reply,
  keywords: keywords,
  regexTriggers: regex,
  expiresAt: expiresAt,
);

MemeS1Responder responder(
  List<Meme> memes, {
  DateTime? at,
  int maxReplyChars = 30,
}) => MemeS1Responder(
  memes: MemeLibrary(memes: memes),
  clock: FakeClock(at ?? now),
  maxReplyChars: maxReplyChars,
);

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

void main() {
  group('MemeS1Responder direct (FR-46 接梗 / FR-47)', () {
    test('active meme hit returns the meme reply', () async {
      final r = responder(<Meme>[
        meme('g1', MemeLayer.general, '笑死', keywords: <String>['开黑']),
      ]);
      final S1Reply reply = await r.replyTo(ai, message('开黑'), padding: false);
      expect(reply.text, '笑死');
      expect(reply.activityRefs, isEmpty);
    });

    test('expired meme is not used and falls back to rules', () async {
      final r = responder(<Meme>[
        meme(
          'g1',
          MemeLayer.general,
          '过期梗',
          keywords: <String>['开黑'],
          expiresAt: now.subtract(const Duration(minutes: 1)),
        ),
      ]);
      final S1Reply reply = await r.replyTo(ai, message('开黑'), padding: false);
      expect(reply.text, isNot('过期梗'));
      expect(reply.text, '愿意多说一点吗？'); // RulesS1Responder fallback
    });

    test('no meme hit falls back to the curated rules', () async {
      final r = responder(<Meme>[
        meme('g1', MemeLayer.general, '笑死', keywords: <String>['开黑']),
      ]);
      final S1Reply reply = await r.replyTo(ai, message('你好'), padding: false);
      expect(reply.text, '你好呀');
    });

    test('padding is always neutral even when a meme matches', () async {
      final r = responder(<Meme>[
        meme('g1', MemeLayer.general, '笑死', keywords: <String>['开黑']),
      ]);
      final S1Reply reply = await r.replyTo(ai, message('开黑'), padding: true);
      expect(reply.text, '嗯……');
    });

    test(
      'a too-long meme reply is clamped to 30 code points, Unicode-safe',
      () async {
        final r = responder(<Meme>[
          meme('g1', MemeLayer.general, '😀' * 40, keywords: <String>['开黑']),
        ]);
        final S1Reply reply = await r.replyTo(
          ai,
          message('开黑'),
          padding: false,
        );
        expect(reply.text.runes.length, 30);
        expect(reply.text.endsWith('…'), isTrue);
        expect(reply.text.contains('\uFFFD'), isFalse);
      },
    );

    test('empty text skips meme lookup and delegates', () async {
      final r = responder(<Meme>[
        meme('g1', MemeLayer.general, '笑死', regex: <String>['.*']),
      ]);
      final S1Reply reply = await r.replyTo(ai, message('   '), padding: false);
      expect(reply.text, isNot('笑死'));
    });

    test('personal layer wins over general on the same trigger', () async {
      final r = responder(<Meme>[
        meme('g1', MemeLayer.general, '通用', keywords: <String>['开黑']),
        meme('p1', MemeLayer.personal, '内部梗', keywords: <String>['开黑']),
      ]);
      final S1Reply reply = await r.replyTo(ai, message('开黑'), padding: false);
      expect(reply.text, '内部梗');
    });
  });

  group('MemeS1Responder through the real router (AC-33/AC-34)', () {
    test('simple meme hit is answered by S1 only, S2 never invoked', () async {
      final FakeS2 s2 = FakeS2();
      final router = RulesFirstBrainRouter(
        s1: responder(<Meme>[
          meme('g1', MemeLayer.general, '笑死', keywords: <String>['开黑']),
        ]),
        s2: s2,
      );
      final m = message('开黑');
      final d = await router.decide(ai, m, inGroup: false);
      expect(d.complexity, Complexity.simple);
      final out = await router.respond(ai, m, d).toList();
      expect(out.map((p) => p.source), <String>['s1']);
      expect(out.single.text, '笑死');
      expect(out.single.activityRefs, isEmpty);
      expect(s2.calls, 0);
    });

    test(
      'complex question uses neutral S1 padding, not a meme, then S2',
      () async {
        final FakeS2 s2 = FakeS2();
        final router = RulesFirstBrainRouter(
          s1: responder(<Meme>[
            meme('g1', MemeLayer.general, '笑死', keywords: <String>['吃饭']),
          ]),
          s2: s2,
        );
        final m = message('你吃饭了吗');
        final d = await router.decide(ai, m, inGroup: false);
        expect(d.complexity, Complexity.complex);
        final out = await router.respond(ai, m, d).toList();
        expect(out.map((p) => p.source), <String>['s1', 's2', 's2']);
        expect(out.first.text, '嗯……');
        expect(s2.calls, 1);
      },
    );
  });
}
