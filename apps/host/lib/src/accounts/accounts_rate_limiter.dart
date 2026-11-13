import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

/// Process-local fixed-window admission control for authentication routes.
/// The HTTP boundary must supply a trusted peer IP, never a forwarded header.
/// Identifier keys are hashed to avoid retaining invitation credentials.
class AccountsRateLimiter {
  AccountsRateLimiter({
    required this.clock,
    this.limit = 30,
    this.window = const Duration(minutes: 1),
    this.capacity = 10000,
  }) {
    if (limit < 1 || capacity < 1 || window <= Duration.zero) {
      throw ArgumentError('invalid rate limiter configuration');
    }
  }

  final Clock clock;
  final int limit;
  final Duration window;
  final int capacity;
  final Map<String, _Bucket> _buckets = {};

  bool allow({required String ip, String? account, String? invite}) {
    final now = clock.now();
    _buckets.removeWhere((_, bucket) => !now.isBefore(bucket.until));
    final keys = [
      _key('ip', ip),
      if (account != null) _key('account', account),
      if (invite != null) _key('invite', invite),
    ];
    if (keys.any((key) => (_buckets[key]?.count ?? 0) >= limit)) {
      return false;
    }
    final missing = keys.where((key) => !_buckets.containsKey(key)).length;
    // Fail closed under identifier churn instead of evicting active limits.
    if (_buckets.length + missing > capacity) return false;
    for (final key in keys) {
      final bucket = _buckets.putIfAbsent(key, () => _Bucket(now.add(window)));
      bucket.count++;
    }
    return true;
  }

  String _key(String kind, String value) =>
      '$kind:${sha256.convert(utf8.encode(value))}';
}

class _Bucket {
  _Bucket(this.until);
  final DateTime until;
  int count = 0;
}
