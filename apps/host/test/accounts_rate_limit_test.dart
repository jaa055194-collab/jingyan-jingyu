import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_rate_limiter.dart';
import 'package:test/test.dart';

void main() {
  test('FR-05 IP, account and invitation have independent limits', () {
    final clock = FakeClock(DateTime.utc(2026));
    final limiter = AccountsRateLimiter(clock: clock, limit: 2);
    expect(limiter.allow(ip: 'a', account: 'u1'), isTrue);
    expect(limiter.allow(ip: 'b', account: 'u1'), isTrue);
    expect(limiter.allow(ip: 'c', account: 'u1'), isFalse);
    expect(limiter.allow(ip: 'a', account: 'u2'), isTrue);
    expect(limiter.allow(ip: 'a', account: 'u3'), isFalse);
    expect(limiter.allow(ip: 'd', invite: 'code'), isTrue);
    expect(limiter.allow(ip: 'e', invite: 'code'), isTrue);
    expect(limiter.allow(ip: 'f', invite: 'code'), isFalse);
    clock.advance(const Duration(minutes: 1));
    expect(limiter.allow(ip: 'a', account: 'u1', invite: 'code'), isTrue);
  });

  test('FR-05 denied combinations do not consume unrelated quotas', () {
    final limiter = AccountsRateLimiter(
      clock: FakeClock(DateTime.utc(2026)),
      limit: 1,
    );
    expect(limiter.allow(ip: 'a', account: 'u1'), isTrue);
    expect(limiter.allow(ip: 'b', account: 'u1'), isFalse);
    expect(limiter.allow(ip: 'b', account: 'u2'), isTrue);
  });
}
