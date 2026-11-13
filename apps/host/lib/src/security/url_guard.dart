/// 出站 URL 防护（NFR-05，硬性）。
///
/// 凡按 URL 发起外部请求（模型、语音、生图、素材、链接预览、用户自填 base_url）
/// 都必须先过 [UrlGuard.check]，每一跳重定向后再查一次；DNS 解析结果同样校验。
library;

import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';

/// DNS 解析函数，便于测试替换。
typedef Resolver = Future<List<InternetAddress>> Function(String host);

/// 出站 URL 校验器。
class UrlGuard {
  UrlGuard({Resolver? resolver}) : _resolve = resolver ?? InternetAddress.lookup;

  final Resolver _resolve;

  /// 校验 URL：协议、主机字面量、DNS 解析结果。
  Future<Result<Uri>> check(String raw) async {
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme) {
      return err(FailureCode.invalidArgument, 'URL 不合法');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return err(FailureCode.forbidden, '只允许 http/https');
    }
    if (uri.host.isEmpty) {
      return err(FailureCode.invalidArgument, 'URL 缺少主机');
    }
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host.endsWith('.localhost')) {
      return err(FailureCode.forbidden, '拒绝本机地址');
    }

    final literal = InternetAddress.tryParse(host);
    final List<InternetAddress> addresses;
    if (literal != null) {
      addresses = [literal];
    } else {
      try {
        addresses = await _resolve(host);
      } on SocketException {
        return err(FailureCode.unavailable, 'DNS 解析失败');
      }
      if (addresses.isEmpty) {
        return err(FailureCode.unavailable, 'DNS 无结果');
      }
    }
    for (final address in addresses) {
      if (isBlocked(address)) {
        return err(FailureCode.forbidden, '拒绝私有、环回或保留地址');
      }
    }
    return Ok(uri);
  }

  /// 地址是否属于禁止出站的范围。
  static bool isBlocked(InternetAddress address) {
    final b = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return b[0] == 0 || // 0.0.0.0/8
          b[0] == 10 || // 10/8
          b[0] == 127 || // 环回
          (b[0] == 100 && b[1] >= 64 && b[1] <= 127) || // CGNAT（含 tailnet 100.64/10）
          (b[0] == 169 && b[1] == 254) || // 链路本地
          (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || // 172.16/12
          (b[0] == 192 && b[1] == 168) || // 192.168/16
          (b[0] == 192 && b[1] == 0 && b[2] == 0) || // 192.0.0/24
          (b[0] == 198 && (b[1] == 18 || b[1] == 19)) || // 基准测试
          b[0] >= 224; // 组播与保留
    }
    // IPv6
    final allZeroPrefix = b.sublist(0, 15).every((x) => x == 0);
    if (allZeroPrefix && (b[15] == 0 || b[15] == 1)) return true; // :: 与 ::1
    if ((b[0] & 0xfe) == 0xfc) return true; // fc00::/7
    if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return true; // fe80::/10
    if (b[0] == 0xff) return true; // 组播
    // IPv4 映射地址 ::ffff:a.b.c.d 按 IPv4 规则判
    final mapped = b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
    if (mapped) {
      return isBlocked(InternetAddress.fromRawAddress(b.sublist(12)));
    }
    return false;
  }
}
