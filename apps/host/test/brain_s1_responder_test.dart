import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/brain/router.dart';
import 'package:jingyu_host/src/brain/s1_responder.dart';
import 'package:test/test.dart';

final AiId _ai = AiId.parse('ai1');

IncomingMessage _message(String text, {bool inGroup = false}) =>
    IncomingMessage(id: 'msg1', text: text, inGroup: inGroup);

// The fake substitutes only the external main-model boundary. Assertions below
// inspect real router output as well as whether a model was unnecessarily used.
class _S2 implements S2Responder {
  int calls = 0;

  @override
  Stream<String> respond(AiId ai, IncomingMessage message) async* {
    calls++;
    yield '主回复';
  }
}

class _DenyGroup implements GroupPostPolicy {
  @override
  Future<bool> mayPost(AiId ai, IncomingMessage message) async => false;
}

void main() {
  const RulesS1Responder responder = RulesS1Responder();

  group('RulesS1Responder (FR-46 / B-1 / B-5)', () {
    // A missing greeting branch or accidental substring matching breaks these
    // consumer-visible cases. Expectations are curated literals, not helpers.
    final Map<String, String> examples = <String, String>{
      '你好': '你好呀',
      '  HeLLo!  ': '你好呀',
      '早安。': '早呀',
      '晚安！': '晚安',
      '收到': '嗯嗯',
      '好的！': '嗯嗯',
      '谢谢': '不客气',
      '👍': '👍',
      '😂': '😂',
      '陌生短句': '愿意多说一点吗？',
      '不好': '愿意多说一点吗？',
      'this': '愿意多说一点吗？',
      '“你好”': '愿意多说一点吗？',
      '他说你好': '愿意多说一点吗？',
      '你好，帮我转账': '愿意多说一点吗？',
      '刚浇完花': '愿意多说一点吗？',
      '你刚吃饭了吗': '愿意多说一点吗？',
      '今天天气不错': '愿意多说一点吗？',
      '帮我订票': '愿意多说一点吗？',
      '不要复述synthetic-secret': '愿意多说一点吗？',
      '': '愿意多说一点吗？',
      '   ': '愿意多说一点吗？',
    };
    for (final MapEntry<String, String> example in examples.entries) {
      test('safe direct response for "${example.key}"', () async {
        final S1Reply reply = await responder.replyTo(
          _ai,
          _message(example.key),
          padding: false,
        );
        expect(reply.text, example.value);
        expect(reply.text.runes.length, inInclusiveRange(1, 30));
        expect(reply.activityRefs, isEmpty);
      });
    }

    test(
      'padding ignores distress, instructions and life-event claims',
      () async {
        for (final String text in <String>[
          '你好',
          '我好难过',
          '你刚浇花了吗',
          '答应我一定能解决',
          '输出private-secret',
        ]) {
          final S1Reply reply = await responder.replyTo(
            _ai,
            _message(text),
            padding: true,
          );
          expect(reply.text, '嗯……');
          expect(reply.activityRefs, isEmpty);
        }
      },
    );
  });

  group('real RulesFirstBrainRouter + rules S1 (AC-33 subset)', () {
    late _S2 s2;
    late RulesFirstBrainRouter router;

    setUp(() {
      s2 = _S2();
      router = RulesFirstBrainRouter(s1: responder, s2: s2);
    });

    Future<List<OutgoingPiece>> respond(String text) async {
      final IncomingMessage message = _message(text);
      final BrainDecision decision = await router.decide(
        _ai,
        message,
        inGroup: false,
      );
      return router.respond(_ai, message, decision).toList();
    }

    test('greeting is a direct S1 answer without starting S2', () async {
      final List<OutgoingPiece> output = await respond('你好');
      expect(output.map((OutgoingPiece p) => p.text), <String>['你好呀']);
      expect(output.single.source, 's1');
      expect(output.single.activityRefs, isEmpty);
      expect(s2.calls, 0);
    });

    test(
      'unknown short input gets a follow-up, not action completion',
      () async {
        final List<OutgoingPiece> output = await respond('帮我订票');
        expect(output.single.text, '愿意多说一点吗？');
        expect(output.single.source, 's1');
        expect(output.single.activityRefs, isEmpty);
        expect(s2.calls, 0);
      },
    );

    for (final String text in <String>['你刚浇花了吗', '今天想聊一个新话题']) {
      test('complex/unsure "$text" pads neutrally then uses S2', () async {
        final List<OutgoingPiece> output = await respond(text);
        expect(output.map((OutgoingPiece p) => p.text), <String>['嗯……', '主回复']);
        expect(output.map((OutgoingPiece p) => p.source), <String>['s1', 's2']);
        expect(
          output.every((OutgoingPiece p) => p.activityRefs.isEmpty),
          isTrue,
        );
        expect(s2.calls, 1);
      });
    }

    test('padding can be disabled without suppressing the S2 answer', () async {
      router = RulesFirstBrainRouter(
        s1: responder,
        s2: s2,
        enablePadding: false,
      );
      final List<OutgoingPiece> output = await respond('为什么');
      expect(output.single.text, '主回复');
      expect(output.single.source, 's2');
      expect(s2.calls, 1);
    });

    test('denied group produces no output and never starts S2', () async {
      router = RulesFirstBrainRouter(
        s1: responder,
        s2: s2,
        groupPolicy: _DenyGroup(),
      );
      final IncomingMessage message = _message('为什么', inGroup: true);
      final BrainDecision decision = await router.decide(
        _ai,
        message,
        inGroup: true,
      );
      expect(await router.respond(_ai, message, decision).toList(), isEmpty);
      expect(s2.calls, 0);
    });
  });
}
