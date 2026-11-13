/// 与传输层无关的路由：`HostRequest` → `HostResponse`。
///
/// 不直接依赖 `dart:io`，因此模块可以在纯单元测试里调用自己的路由。
library;

import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

/// 已认证的调用者。认证中间件负责填充；未认证请求为 null。
class Principal {
  const Principal({required this.accountId, required this.deviceId, this.isAdmin = false});

  final String accountId;
  final String deviceId;

  /// 运维管理员（FR-07：只做运维，不看正文）。
  final bool isAdmin;
}

/// 请求。
class HostRequest {
  HostRequest({
    required this.method,
    required this.path,
    this.query = const <String, String>{},
    this.headers = const <String, String>{},
    this.body,
    this.principal,
    Map<String, String>? pathParams,
  }) : pathParams = pathParams ?? <String, String>{};

  final String method;
  final String path;
  final Map<String, String> query;

  /// 头部名一律小写。
  final Map<String, String> headers;

  /// 已解析的 JSON 体；非 JSON 请求为 null。
  final Object? body;

  final Principal? principal;

  /// 路由匹配出的路径参数，例如 `{conversationId}`。
  final Map<String, String> pathParams;

  HostRequest copyWith({Principal? principal, Map<String, String>? pathParams}) =>
      HostRequest(
        method: method,
        path: path,
        query: query,
        headers: headers,
        body: body,
        principal: principal ?? this.principal,
        pathParams: pathParams ?? this.pathParams,
      );

  /// 把 JSON 体取成对象；不是对象时返回 invalidArgument。
  Result<Map<String, Object?>> jsonObject() {
    final value = body;
    if (value is Map<String, Object?>) return Ok(value);
    if (value is Map) return Ok({...value.cast<String, Object?>()});
    return err(FailureCode.invalidArgument, '请求体必须是 JSON 对象');
  }
}

/// 响应。
class HostResponse {
  const HostResponse(this.status, {this.json, this.headers = const <String, String>{}});

  final int status;
  final Object? json;
  final Map<String, String> headers;

  factory HostResponse.ok(Object? json) => HostResponse(200, json: json);

  /// 由失败生成错误响应：只带错误码，不带内部说明（NFR-06、NFR-10）。
  factory HostResponse.failure(Failure failure) {
    final code = ErrorCode.fromFailure(failure.code);
    return HostResponse(code.httpStatus, json: {'error': code.wire});
  }

  /// 由 Result 生成响应。
  static HostResponse fromResult<T>(Result<T> result, [Object? Function(T value)? encode]) =>
      switch (result) {
        Ok<T>(:final value) => HostResponse.ok(encode == null ? value : encode(value)),
        Err<T>(:final failure) => HostResponse.failure(failure),
      };

  String encodeBody() => json == null ? '' : jsonEncode(json);
}

/// 处理函数。
typedef Handler = Future<HostResponse> Function(HostRequest request);

/// 路由访问级别。
enum Access {
  /// 无需登录（仅健康检查、登录本身）。
  public,

  /// 需要登录。
  authenticated,

  /// 需要运维管理员。
  admin,
}

class _Route {
  _Route(this.method, this.pattern, this.access, this.handler, this.owner)
      : segments = pattern.split('/').where((s) => s.isNotEmpty).toList();

  final String method;
  final String pattern;
  final Access access;
  final Handler handler;
  final String owner;
  final List<String> segments;

  Map<String, String>? match(String method, List<String> pathSegments) {
    if (method != this.method || pathSegments.length != segments.length) {
      return null;
    }
    final params = <String, String>{};
    for (var i = 0; i < segments.length; i++) {
      final expected = segments[i];
      final actual = pathSegments[i];
      if (expected.startsWith('{') && expected.endsWith('}')) {
        params[expected.substring(1, expected.length - 1)] = Uri.decodeComponent(actual);
      } else if (expected != actual) {
        return null;
      }
    }
    return params;
  }
}

/// 路由匹配结果。
class RouteMatch {
  const RouteMatch(this.access, this.handler, this.pathParams, this.owner);

  final Access access;
  final Handler handler;
  final Map<String, String> pathParams;
  final String owner;
}

/// 路由表。
class Router {
  final List<_Route> _routes = <_Route>[];
  String _currentOwner = 'host';

  /// 由注册表在 `mount` 前设置，用于冲突报错。
  set currentOwner(String owner) => _currentOwner = owner;

  /// 声明路由。[pattern] 必须取自 `Routes`，参数写作 `{name}`。
  /// 默认要求登录：公开路由必须显式写 [Access.public]。
  void add(String method, String pattern, Handler handler, {Access access = Access.authenticated}) {
    final upper = method.toUpperCase();
    final candidate = _Route(upper, pattern, access, handler, _currentOwner);
    for (final route in _routes) {
      if (route.method == upper && _sameShape(route.segments, candidate.segments)) {
        throw StateError('路由冲突：$upper $pattern（${candidate.owner}）与 ${route.pattern}（${route.owner}）');
      }
    }
    _routes.add(candidate);
  }

  void get(String pattern, Handler handler, {Access access = Access.authenticated}) =>
      add('GET', pattern, handler, access: access);

  void post(String pattern, Handler handler, {Access access = Access.authenticated}) =>
      add('POST', pattern, handler, access: access);

  void put(String pattern, Handler handler, {Access access = Access.authenticated}) =>
      add('PUT', pattern, handler, access: access);

  void delete(String pattern, Handler handler, {Access access = Access.authenticated}) =>
      add('DELETE', pattern, handler, access: access);

  /// 匹配。返回 null 表示 404；路径存在但方法不对也按 404 处理，避免探测。
  RouteMatch? match(String method, String path) {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    for (final route in _routes) {
      final params = route.match(method.toUpperCase(), segments);
      if (params != null) {
        return RouteMatch(route.access, route.handler, params, route.owner);
      }
    }
    return null;
  }

  /// 已声明的路由清单（诊断用）。
  List<String> describe() => [for (final r in _routes) '${r.method} ${r.pattern} [${r.access.name}] <${r.owner}>'];

  static bool _sameShape(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final aParam = a[i].startsWith('{');
      final bParam = b[i].startsWith('{');
      if (aParam && bParam) continue;
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
