import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/brain/pacing.dart';
import 'package:test/test.dart';

void main() {
  final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 15, 12, 0, 0));

  group('HumanPacing.delayFor', () {
    test('default delay stays within the 1s..4s human window', () {
      final HumanPacing pacing = HumanPacing(clock: clock);
      final List<String> samples = <String>[
        '',
        '你好',
        '哈哈哈',
        '今天天气很不错呀我们出去走走吧',
        'a' * 200,
      ];
      for (final String text in samples) {
        final Duration delay = pacing.delayFor(text);
        expect(
          delay >= const Duration(seconds: 1),
          isTrue,
          reason: 'delay for "$text" must be >= 1s, was $delay',
        );
        expect(
          delay <= const Duration(seconds: 4),
          isTrue,
          reason: 'delay for "$text" must be <= 4s, was $delay',
        );
      }
    });

    test('is deterministic for the same clock instant and text', () {
      final HumanPacing pacing = HumanPacing(clock: clock);
      final Duration first = pacing.delayFor('你好呀');
      final Duration second = pacing.delayFor('你好呀');
      expect(first, second);
    });

    test('disabled pacing always returns Duration.zero', () {
      final HumanPacing pacing = HumanPacing(clock: clock, enabled: false);
      for (final String text in <String>['', '你好', 'a' * 200]) {
        expect(pacing.delayFor(text), Duration.zero);
      }
    });

    test('custom bounds are honoured', () {
      final HumanPacing pacing = HumanPacing(
        clock: clock,
        min: const Duration(milliseconds: 2000),
        max: const Duration(milliseconds: 2500),
      );
      for (final String text in <String>['x', '你好', 'a' * 50]) {
        final Duration delay = pacing.delayFor(text);
        expect(delay >= const Duration(milliseconds: 2000), isTrue);
        expect(delay <= const Duration(milliseconds: 2500), isTrue);
      }
    });

    test('degenerate min == max returns exactly that duration', () {
      final HumanPacing pacing = HumanPacing(
        clock: clock,
        min: const Duration(seconds: 2),
        max: const Duration(seconds: 2),
      );
      expect(pacing.delayFor('anything'), const Duration(seconds: 2));
    });

    test('min > max falls back to min instead of throwing', () {
      final HumanPacing pacing = HumanPacing(
        clock: clock,
        min: const Duration(seconds: 3),
        max: const Duration(seconds: 1),
      );
      expect(pacing.delayFor('anything'), const Duration(seconds: 3));
    });
  });
}
