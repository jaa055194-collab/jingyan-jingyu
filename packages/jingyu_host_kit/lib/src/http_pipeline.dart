/// 请求管线：认证 → 访问级别 → 处理函数 → 异常兜底。
///
/// 与 `dart:io` 解耦：宿主应用把 HttpRequest 转成 [HostRequest] 后调用 [Pipeline.handle]。
library;

import 'package:jingyu_core/jingyu_core.dart';

import 'router.dart';

/// 由请求头解析调用者。返回 null 表示未认证。
typedef Authenticator = Future<Principal?> Function(HostRequest request);

/// 中间件：包装处理函数。
typedef Middleware = Handler Function(Handler next);

/// 记录未捕获异常。实现不得记录请求体（可能含正文）。
typedef ErrorSink = void Function(Object error, StackTrace stack, HostRequest request);

/// 请求管线。
class Pipeline {
  Pipeline({
    required this.router,
    required this.authenticate,
    this.middlewares = const <Middleware>[],
    ErrorSink? onError,
  }) : onError = onError ?? _ignore;

  final Router router;
  final Authenticator authenticate;
  final List<Middleware> middlewares;
  final ErrorSink onError;

  static void _ignore(Object error, StackTrace stack, HostRequest request) {}

  /// 处理一次请求。
  Future<HostResponse> handle(HostRequest request) async {
    final match = router.match(request.method, request.path);
    if (match == null) {
      return HostResponse.failure(const Failure(FailureCode.notFound, 'no route'));
    }

    try {
      Principal? principal;
      if (match.access != Access.public) {
        principal = await authenticate(request);
        if (principal == null) {
          return HostResponse.failure(
              const Failure(FailureCode.unauthenticated, 'login required'));
        }
        if (match.access == Access.admin && !principal.isAdmin) {
          return HostResponse.failure(
              const Failure(FailureCode.forbidden, 'admin only'));
        }
      }

      Handler handler = match.handler;
      for (final middleware in middlewares.reversed) {
        handler = middleware(handler);
      }
      return await handler(
        request.copyWith(principal: principal, pathParams: match.pathParams),
      );
    } catch (error, stack) {
      onError(error, stack, request);
      return HostResponse.failure(const Failure(FailureCode.internal, 'internal'));
    }
  }
}
