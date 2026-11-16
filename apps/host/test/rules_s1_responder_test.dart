import 'package:jingyu_host/src/brain/s1_responder.dart';
import 'package:test/test.dart';

void main() {
  test(
    'curated support uses complete normalized catalog not short fallback',
    () {
      const rules = RulesS1Responder();
      for (final text in ['你好', ' HELLO!! ', '谢谢。', '👍']) {
        expect(rules.supports(text), isTrue);
        expect(rules.curatedReply(text), isNotNull);
      }
      expect(rules.curatedReply(' HELLO!! ')!.text, '你好呀');
      expect(rules.curatedReply('短句'), isNull);
      for (final text in ['短句', '你好怎么做', '不要你好', '你好？', '']) {
        expect(rules.supports(text), isFalse);
      }
    },
  );
}
