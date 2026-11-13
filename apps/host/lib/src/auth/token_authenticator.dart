/// 框架阶段的认证占位实现。
///
/// 只认 `Authorization: Bearer <token>`，token 由 [StaticTokenAuthenticator.issue]
/// 在内存里登记。真正的邀请码、密码哈希、refresh token、设备上限（FR-05/06）
/// 由 M02-accounts 替换，替换时只需实现同一个 [Authenticator] 签名。
library;

import 'dart:convert';
import 'dart:math';

import 'package:jingyu_host_kit/jingyu_host_kit.dart';

/// 内存 token 认证。
class StaticTokenAuthenticator {
  StaticTokenAuthenticator({Random? random}) : _random = random ?? Random.secure();

  final Random _random;
  final Map<String, Principal> _tokens = {};

  /// 签发 token（128-bit 随机，base64url 无填充）。
  String issue(Principal principal) {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final token = base64Url.encode(bytes).replaceAll('=', '');
    _tokens[token] = principal;
    return token;
  }

  /// 吊销 token，立即失效。
  void revoke(String token) => _tokens.remove(token);

  /// 符合 [Authenticator] 签名。
  Future<Principal?> call(HostRequest request) async {
    final header = request.headers['authorization'];
    if (header == null || !header.startsWith('Bearer ')) return null;
    return _tokens[header.substring(7).trim()];
  }
}
