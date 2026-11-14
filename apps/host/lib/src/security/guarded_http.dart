/// 请求时校验并固定 DNS 地址的出站传输；HTTPS 推荐，兼容现有 HTTP URL。
///
/// 仅复用 UrlGuard.isBlocked 的现有地址范围，不代表完整 SSRF 范围覆盖。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:jingyu_core/jingyu_core.dart';

import 'url_guard.dart';

/// 可信的连接策略。实现必须连接传入的已校验地址，不得再次解析域名。
abstract interface class PinnedConnector {
  Future<ConnectionTask<Socket>> startConnect(
    InternetAddress address,
    int port, {
    String? secureHost,
    SecurityContext? context,
  });
}

/// 原生连接：传入 InternetAddress 而非 host 字符串，避免连接时二次 DNS。
/// HTTPS 显式 secure(host:) 保留原域证书验证/SNI，绝不接受无效证书。
/// Dart secure() 移交 TCP 后，cancel 不能强制中断单个停滞握手；资源可能
/// 持续至对端断开。共享名额限制此类资源，满额时在 TCP 连接前失败关闭。
final class SocketPinnedConnector implements PinnedConnector {
  const SocketPinnedConnector();

  // Transport resource bound, not a product quota. Shared across connector
  // instances in this isolate; timeout/cancel cannot release a pending handshake.
  static const _maxActiveTlsHandshakes = 8;
  static int _activeTlsHandshakes = 0;

  @override
  Future<ConnectionTask<Socket>> startConnect(
    InternetAddress address,
    int port, {
    String? secureHost,
    SecurityContext? context,
  }) async {
    if (secureHost == null) return Socket.startConnect(address, port);
    if (_activeTlsHandshakes >= _maxActiveTlsHandshakes) {
      throw const SocketException('TLS handshake capacity exhausted');
    }
    _activeTlsHandshakes++;
    ConnectionTask<Socket> task;
    try {
      // Reserve before TCP starts, so rejection cannot create another socket.
      task = await Socket.startConnect(address, port);
    } catch (_) {
      _activeTlsHandshakes--;
      rethrow;
    }
    var cancelled = false;
    final secure = task.socket
        .then<Socket>((socket) async {
          if (cancelled) {
            socket.destroy();
            throw const _RequestExpired();
          }
          final tls = await SecureSocket.secure(
            socket,
            host: secureHost,
            context: context,
          );
          if (cancelled) {
            tls.destroy();
            throw const _RequestExpired();
          }
          return tls;
        })
        .whenComplete(() {
          // Only actual TCP/handshake settlement returns the resource slot.
          _activeTlsHandshakes--;
        });
    return ConnectionTask.fromSocket(secure, () {
      cancelled = true;
      task.cancel();
    });
  }
}

final class GuardedResponse {
  GuardedResponse({
    required this.statusCode,
    required Map<String, List<String>> headers,
    required List<int> body,
  }) : headers = Map.unmodifiable(
         headers.map(
           (key, values) => MapEntry(key, List<String>.unmodifiable(values)),
         ),
       ),
       body = List<int>.unmodifiable(body);

  final int statusCode;
  final Map<String, List<String>> headers;
  final List<int> body;
}

/// 每次请求均独立校验 URL/DNS，不信任保存配置时的校验结果。
///
/// 默认总时限 15 秒（包含 DNS、连接、TLS、响应头及响应流），响应体上限
/// 4 MiB，按交付的字节数限制；关闭自动解压，防止压缩后隐式膨胀。
/// 不自动重试、不跟随任何 3xx、不使用代理、不跨请求复用连接。
/// resolver / connector 是可信注入点，供无公网测试使用。
final class GuardedHttpTransport {
  GuardedHttpTransport({
    Resolver? resolver,
    SecurityContext? securityContext,
    PinnedConnector connector = const SocketPinnedConnector(),
    this.timeout = const Duration(seconds: 15),
    this.maxResponseBytes = 4 * 1024 * 1024,
  }) : _resolve = resolver ?? InternetAddress.lookup,
       _securityContext = securityContext,
       _connector = connector {
    if (timeout <= Duration.zero || maxResponseBytes <= 0) {
      throw ArgumentError('请求时限与响应体限额必须大于零');
    }
  }

  final Resolver _resolve;
  final SecurityContext? _securityContext;
  final PinnedConnector _connector;
  final Duration timeout;
  final int maxResponseBytes;

  Future<Result<GuardedResponse>> request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    HttpClient? client;
    ConnectionTask<Socket>? connection;
    var finished = false;

    Future<Result<GuardedResponse>> perform() async {
      if ((uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty ||
          uri.hasFragment ||
          uri.userInfo.isNotEmpty ||
          uri.authority.contains('@')) {
        return err(FailureCode.forbidden, '拒绝不安全的请求 URL');
      }
      final host = uri.host.toLowerCase();
      if (host == 'localhost' || host.endsWith('.localhost')) {
        return err(FailureCode.forbidden, '拒绝本机地址');
      }
      final literal = InternetAddress.tryParse(host);
      final addresses = literal == null ? await _resolve(host) : [literal];
      // A timed-out DNS operation may complete later, but must never connect.
      if (finished) throw const _RequestExpired();
      if (addresses.isEmpty) {
        return err(FailureCode.unavailable, 'DNS 无结果');
      }
      if (addresses.any(UrlGuard.isBlocked)) {
        return err(FailureCode.forbidden, '拒绝私有、环回或保留地址');
      }
      final pinned = addresses.first;
      final http = HttpClient()
        ..findProxy = ((_) => 'DIRECT')
        ..autoUncompress = false
        ..connectionTimeout = timeout;
      client = http;
      http.connectionFactory = (target, proxyHost, proxyPort) async {
        if (finished ||
            target.host.toLowerCase() != host ||
            target.port != uri.port ||
            target.scheme != uri.scheme ||
            proxyHost != null ||
            proxyPort != null) {
          throw const _RequestExpired();
        }
        final task = await _connector.startConnect(
          pinned,
          uri.port,
          secureHost: uri.scheme == 'https' ? host : null,
          context: _securityContext,
        );
        connection = task;
        if (finished) {
          task.cancel();
          // Consume possible cancellation errors on a late connection task.
          unawaited(
            task.socket.then<void>(
              (socket) => socket.destroy(),
              onError: (Object _, StackTrace _) {},
            ),
          );
          throw const _RequestExpired();
        }
        return task;
      };
      // TLS is established by the factory before any HTTP secrets are written.
      final outgoing = await http.openUrl(method, uri);
      outgoing.followRedirects = false;
      headers.forEach((name, value) => outgoing.headers.set(name, value));
      if (body != null) outgoing.add(body);
      final incoming = await outgoing.close();
      if (incoming.statusCode >= 300 && incoming.statusCode < 400) {
        return err(FailureCode.forbidden, '拒绝重定向响应');
      }
      if (incoming.contentLength > maxResponseBytes) {
        return err(FailureCode.unavailable, '响应体超过限额');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in incoming) {
        if (finished) throw const _RequestExpired();
        if (chunk.length > maxResponseBytes - bytes.length) {
          return err(FailureCode.unavailable, '响应体超过限额');
        }
        bytes.add(chunk);
      }
      final responseHeaders = <String, List<String>>{};
      incoming.headers.forEach((name, values) {
        responseHeaders[name] = List.of(values);
      });
      return Ok(
        GuardedResponse(
          statusCode: incoming.statusCode,
          headers: responseHeaders,
          body: bytes.takeBytes(),
        ),
      );
    }

    try {
      return await perform().timeout(timeout);
    } on TimeoutException {
      return err(FailureCode.unavailable, '出站请求超时');
    } catch (_) {
      // Never serialize exceptions: providers may embed URL, key or payload.
      return err(FailureCode.unavailable, '出站请求失败');
    } finally {
      finished = true;
      connection?.cancel();
      client?.close(force: true);
    }
  }
}

final class _RequestExpired implements Exception {
  const _RequestExpired();
}
