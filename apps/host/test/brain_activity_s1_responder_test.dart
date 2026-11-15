import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/brain/activity_s1_responder.dart';
import 'package:jingyu_host/src/brain/classifier.dart';
import 'package:jingyu_host/src/brain/router.dart';
import 'package:test/test.dart';

final AiId ai = AiId.parse('ai1');

IncomingMessage message(String text) => IncomingMessage(
  id: 'm1',
  text: text,
  conversationId: ConversationId.parse('c1'),
);

class Source {
  Source(this.activities);
  List<S1Activity> activities;
  int calls = 0;
  AiId? lastAi;

  Future<List<S1Activity>> lookup(AiId a) async {
    calls++;
    lastAi = a;
    return activities;
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

void main() {
  group('ActivityS1Responder direct (B-1 rule 5)', () {
    test('status query with a real activity cites id and summary', () async {
      final Source source = Source(<S1Activity>[
        const S1Activity(id: 'act-7', summary: '浇花'),
      ]);
      final r = ActivityS1Responder(activities: source.lookup);
      final S1Reply reply = await r.replyTo(
        ai,
        message('你在干嘛'),
        padding: false,
      );
      expect(reply.text, '刚在浇花');
      expect(reply.activityRefs, <String>['act-7']);
      expect(source.calls, 1);
      expect(source.lastAi, ai);
    });

    test('status query without a record never mentions an event', () async {
      final Source source = Source(<S1Activity>[]);
      final r = ActivityS1Responder(activities: source.lookup);
      final S1Reply reply = await r.replyTo(
        ai,
        message('你在干嘛'),
        padding: false,
      );
      expect(reply.text, '愿意多说一点吗？'); // RulesS1Responder fallback
      expect(reply.activityRefs, isEmpty);
      expect(reply.text.contains('浇花'), isFalse);
    });

    test('non-status message does not look up or cite activity', () async {
      final Source source = Source(<S1Activity>[
        const S1Activity(id: 'act-7', summary: '浇花'),
      ]);
      final r = ActivityS1Responder(activities: source.lookup);
      final S1Reply reply = await r.replyTo(ai, message('你好'), padding: false);
      expect(reply.text, '你好呀');
      expect(reply.activityRefs, isEmpty);
      expect(source.calls, 0);
    });

    test('padding is neutral and never looks up activity', () async {
      final Source source = Source(<S1Activity>[
        const S1Activity(id: 'act-7', summary: '浇花'),
      ]);
      final r = ActivityS1Responder(activities: source.lookup);
      final S1Reply reply = await r.replyTo(ai, message('你在干嘛'), padding: true);
      expect(reply.text, '嗯……');
      expect(reply.activityRefs, isEmpty);
      expect(source.calls, 0);
    });

    test('user-quoted event is not turned into a life-event claim', () async {
      final Source source = Source(<S1Activity>[
        const S1Activity(id: 'act-7', summary: '浇花'),
      ]);
      final r = ActivityS1Responder(activities: source.lookup);
      final S1Reply reply = await r.replyTo(
        ai,
        message('他说你刚浇完花'),
        padding: false,
      );
      expect(reply.activityRefs, isEmpty);
      expect(reply.text.contains('浇花'), isFalse);
      expect(source.calls, 0);
    });

    test('blank id or summary is skipped', () async {
      final Source source = Source(<S1Activity>[
        const S1Activity(id: '  ', summary: '浇花'),
        const S1Activity(id: 'act-8', summary: '   '),
      ]);
      final r = ActivityS1Responder(activities: source.lookup);
      final S1Reply reply = await r.replyTo(
        ai,
        message('你在干嘛'),
        padding: false,
      );
      expect(reply.activityRefs, isEmpty);
    });
  });

  group('ActivityS1Responder through the real router (AC-33)', () {
    test(
      'simple status query is answered by S1 with activityRefs, S2 not called',
      () async {
        final FakeS2 s2 = FakeS2();
        final router = RulesFirstBrainRouter(
          s1: ActivityS1Responder(
            activities: Source(<S1Activity>[
              const S1Activity(id: 'act-7', summary: '浇花'),
            ]).lookup,
          ),
          s2: s2,
        );
        final m = message('你在干嘛');
        final d = await router.decide(ai, m, inGroup: false);
        expect(d.complexity, Complexity.simple);
        final out = await router.respond(ai, m, d).toList();
        expect(out.map((p) => p.source), <String>['s1']);
        expect(out.single.text, '刚在浇花');
        expect(out.single.activityRefs, <String>['act-7']);
        expect(s2.calls, 0);
      },
    );
  });
}
