import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/lifecycle/quota.dart';
import 'package:test/test.dart';

void main() {
  Result<QuotaDecision> evaluate({
    int used = 0,
    int quota = 21474836480,
    UploadKind kind = UploadKind.file,
    int size = 1,
    int free = 100,
    int total = 100,
  }) => QuotaPolicy.evaluate(
    usedBytes: used,
    quotaBytes: quota,
    kind: kind,
    uploadBytes: size,
    diskFreeBytes: free,
    diskTotalBytes: total,
  );

  group('FR-63 quota policy', () {
    test('default quota is binary 20 GiB and warns at exactly 80%', () {
      final below = QuotaPolicy.evaluate(
        usedBytes: 17179869183,
        kind: UploadKind.file,
        uploadBytes: 1,
        diskFreeBytes: 10,
        diskTotalBytes: 100,
      );
      final boundary = QuotaPolicy.evaluate(
        usedBytes: 17179869184,
        kind: UploadKind.file,
        uploadBytes: 1,
        diskFreeBytes: 10,
        diskTotalBytes: 100,
      );
      expect(below.value.quotaWarning, isFalse);
      expect(boundary.value.quotaWarning, isTrue);
    });

    test(
      'configured quota warns based on current usage, not projected usage',
      () {
        expect(
          evaluate(used: 79, quota: 100, size: 52428801).value.quotaWarning,
          isFalse,
        );
        expect(evaluate(used: 80, quota: 100).value.quotaWarning, isTrue);
        expect(evaluate(used: 99, quota: 100, size: 52428801).isOk, isTrue);
      },
    );

    for (final kind in [UploadKind.file, UploadKind.video, UploadKind.live2d]) {
      test('$kind rejects only above binary 50 MiB at/above 100%', () {
        for (final used in [100, 101]) {
          expect(
            evaluate(used: used, quota: 100, kind: kind, size: 52428800).isOk,
            isTrue,
          );
          final result = evaluate(
            used: used,
            quota: 100,
            kind: kind,
            size: 52428801,
          );
          expect(result.failureOrNull?.code, FailureCode.budgetExhausted);
          expect(result.failureOrNull?.details['reason'], 'quota');
        }
      });
    }

    test('text, images and voice remain available beyond quota', () {
      for (final kind in [
        UploadKind.text,
        UploadKind.image,
        UploadKind.voice,
      ]) {
        final result = evaluate(
          used: 101,
          quota: 100,
          kind: kind,
          size: 52428801,
        );
        expect(result.isOk, isTrue, reason: kind.name);
        expect(result.value.quotaWarning, isTrue);
      }
    });

    test('only video, voice, files and Live2D consume quota', () {
      for (final kind in UploadKind.values) {
        final result = evaluate(kind: kind, size: 123);
        expect(
          result.value.countedBytes,
          [UploadKind.text, UploadKind.image].contains(kind) ? 0 : 123,
          reason: kind.name,
        );
      }
    });

    test('disk strictly below 10% stops every upload and signals warning', () {
      for (final kind in UploadKind.values) {
        final result = evaluate(kind: kind, free: 9);
        expect(result.failureOrNull?.code, FailureCode.budgetExhausted);
        expect(result.failureOrNull?.details['reason'], 'disk');
        expect(result.failureOrNull?.details['diskWarning'], isTrue);
        expect(evaluate(kind: kind, free: 10).isOk, isTrue);
      }
    });

    test('disk stop takes precedence over account quota rejection', () {
      expect(
        evaluate(
          used: 100,
          quota: 100,
          size: 52428801,
          free: 9,
        ).failureOrNull?.details['reason'],
        'disk',
      );
    });

    test('percentage checks preserve exact integer boundaries', () {
      expect(evaluate(used: 4, quota: 5).value.quotaWarning, isTrue);
      expect(evaluate(used: 3, quota: 5).value.quotaWarning, isFalse);
      expect(evaluate(free: 1, total: 11).isErr, isTrue);
      expect(evaluate(free: 1, total: 10).isOk, isTrue);
      // Multiplying these valid native ints by ten would overflow.
      expect(
        evaluate(free: 1000000000000000000, total: 9000000000000000000).isOk,
        isTrue,
      );
    });

    test('invalid byte counts and disk totals return invalidArgument', () {
      final cases = [
        evaluate(used: -1),
        evaluate(quota: -1),
        evaluate(quota: 0),
        evaluate(size: -1),
        evaluate(free: -1),
        evaluate(total: -1),
        evaluate(total: 0),
        evaluate(free: 101),
        evaluate(kind: UploadKind.text, size: -1),
        evaluate(used: -1, free: 0),
      ];
      for (final result in cases) {
        expect(result.failureOrNull?.code, FailureCode.invalidArgument);
      }
      expect(
        evaluate(size: 0, free: 0).failureOrNull?.details['reason'],
        'disk',
      );
      expect(evaluate(size: 0).isOk, isTrue);
    });

    test('decision exposes binary 8 MiB chunk sizing', () {
      expect(evaluate(size: 8388609).value.chunkSizeBytes, 8388608);
    });
  });

  group('per-account upload gate', () {
    test('fourth upload fails while other accounts have independent slots', () {
      final gate = UploadGate();
      for (var i = 0; i < 3; i++) {
        expect(gate.acquire('a').isOk, isTrue);
      }
      expect(gate.acquire('a').failureOrNull?.code, FailureCode.rateLimited);
      expect(gate.acquire('b').isOk, isTrue);
    });

    test('release restores one slot without affecting another account', () {
      final gate = UploadGate();
      final a = gate.acquire('a').value;
      gate.acquire('a');
      gate.acquire('a');
      final b = gate.acquire('b').value;
      gate.acquire('b');
      gate.acquire('b');
      expect(gate.release(a).isOk, isTrue);
      expect(gate.acquire('a').isOk, isTrue);
      expect(gate.acquire('a').isErr, isTrue);
      expect(gate.acquire('b').isErr, isTrue);
      expect(gate.release(b).isOk, isTrue);
      expect(gate.acquire('b').isOk, isTrue);
    });

    test('duplicate and foreign releases cannot create slots', () {
      final gate = UploadGate();
      final other = UploadGate();
      final permit = gate.acquire('a').value;
      expect(
        other.release(permit).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      gate.acquire('a');
      gate.acquire('a');
      expect(gate.acquire('a').isErr, isTrue);
      expect(gate.release(permit).isOk, isTrue);
      gate.acquire('a');
      expect(
        gate.release(permit).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(gate.acquire('a').isErr, isTrue);
    });

    test('empty and whitespace account ids cannot acquire slots', () {
      final gate = UploadGate();
      for (final id in ['', ' ', '\n\t']) {
        expect(
          gate.acquire(id).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
      }
    });
  });
}
