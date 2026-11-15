import 'package:jingyu_host/src/brain/classifier.dart';
import 'package:test/test.dart';

void main() {
  const RuleClassifier classifier = RuleClassifier();

  group('RuleClassifier rules', () {
    test('empty (or whitespace-only) text is unsure with empty reason', () {
      for (final String text in <String>['', '   ', '\n\t ']) {
        final Classification result = classifier.classify(text);
        expect(result.complexity, Complexity.unsure);
        expect(result.reasons, <String>['empty']);
      }
    });

    test('question markers make text complex', () {
      const List<String> questions = <String>[
        '你吃饭了吗',
        '这是什么？',
        'why is that?',
        '你好呢',
        '怎么弄',
        '为什么不动',
        '如何开始',
        '你是不是生气了',
        '多少钱',
        '哪里',
      ];
      for (final String text in questions) {
        final Classification result = classifier.classify(text);
        expect(
          result.complexity,
          Complexity.complex,
          reason: 'expected "$text" to be complex',
        );
        expect(result.reasons, contains('question'));
      }
    });

    test('question is evaluated before greeting ("你好吗")', () {
      final Classification result = classifier.classify('你好吗');
      expect(result.complexity, Complexity.complex);
      expect(result.reasons, contains('question'));
      expect(result.reasons, isNot(contains('greeting')));
    });

    test('long text at the threshold is complex, just below is not', () {
      final String below = 'a' * (classifier.longTextThreshold - 1);
      final String at = 'a' * classifier.longTextThreshold;

      final Classification belowResult = classifier.classify(below);
      expect(belowResult.complexity, Complexity.unsure);
      expect(belowResult.reasons, isNot(contains('longText')));

      final Classification atResult = classifier.classify(at);
      expect(atResult.complexity, Complexity.complex);
      expect(atResult.reasons, <String>['longText']);
    });

    test('custom longTextThreshold is honoured', () {
      const RuleClassifier short = RuleClassifier(longTextThreshold: 10);
      expect(short.classify('a' * 9).reasons, isNot(contains('longText')));
      expect(short.classify('a' * 10).complexity, Complexity.complex);
      expect(short.classify('a' * 10).reasons, <String>['longText']);
    });

    test('emotional / health words make text complex', () {
      const List<String> emotional = <String>[
        '我今天好累',
        '有点难过',
        '别生气了',
        '快崩溃了',
        '我头疼',
        '又失眠了',
        '好焦虑',
        '今天很开心',
        '好委屈',
      ];
      for (final String text in emotional) {
        final Classification result = classifier.classify(text);
        expect(
          result.complexity,
          Complexity.complex,
          reason: 'expected "$text" to be complex',
        );
        expect(result.reasons, contains('emotion'));
      }
    });

    test('short greetings / interjections are simple with greeting reason', () {
      const List<String> greetings = <String>[
        '你好',
        '在么',
        '早安',
        '晚安',
        '哈哈',
        '嗯',
        '哦',
        '早',
        'hi',
        'hello',
        'Hello',
      ];
      for (final String text in greetings) {
        final Classification result = classifier.classify(text);
        expect(
          result.complexity,
          Complexity.simple,
          reason: 'expected "$text" to be simple',
        );
        expect(result.reasons, contains('greeting'));
      }
    });

    test('very short non-question text is simple with short reason', () {
      final Classification result = classifier.classify('去散步');
      expect(result.complexity, Complexity.simple);
      expect(result.reasons, <String>['short']);
    });

    test('medium text with no rule is unsure with noRule reason', () {
      final Classification result = classifier.classify('今天天气很不错');
      expect(result.complexity, Complexity.unsure);
      expect(result.reasons, <String>['noRule']);
    });

    test('reasons are non-empty and stable across calls', () {
      const List<String> samples = <String>[
        '',
        '你好吗',
        '我今天好累',
        '你好',
        '去散步',
        '今天天气很不错',
      ];
      for (final String text in samples) {
        final Classification first = classifier.classify(text);
        final Classification second = classifier.classify(text);
        expect(first.reasons, isNotEmpty);
        expect(first.reasons, second.reasons);
        expect(first.complexity, second.complexity);
      }
    });

    test('inGroup does not change complexity but appends group reason', () {
      final List<String> samples = <String>[
        '',
        '你好吗',
        '我今天好累',
        '你好',
        '去散步',
        '今天天气很不错',
        'a' * 80,
      ];
      for (final String text in samples) {
        final Classification direct = classifier.classify(text);
        final Classification group = classifier.classify(text, inGroup: true);
        expect(group.complexity, direct.complexity);
        expect(group.reasons, contains('group'));
        expect(group.reasons.length, direct.reasons.length + 1);
        // The original reasons are preserved in order before 'group'.
        expect(group.reasons.sublist(0, direct.reasons.length), direct.reasons);
        expect(group.reasons.last, 'group');
      }
    });
  });
}
