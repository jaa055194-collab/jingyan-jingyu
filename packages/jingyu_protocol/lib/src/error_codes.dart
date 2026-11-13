/// 协议错误码。
///
/// 客户端只依据这些码做分支；人类可读文案由客户端本地化，服务端不返回文案，
/// 以免把内部信息（正文、路径、key）带出去（NFR-06、NFR-10）。
library;

import 'package:jingyu_core/jingyu_core.dart';

/// 线协议错误码。
enum ErrorCode {
  /// 入参不合法。
  invalidArgument('invalid_argument', 400),

  /// 未认证。
  unauthenticated('unauthenticated', 401),

  /// 无权限。
  forbidden('forbidden', 403),

  /// 不存在或不可见。
  notFound('not_found', 404),

  /// 状态冲突。
  conflict('conflict', 409),

  /// 限流。
  rateLimited('rate_limited', 429),

  /// 预算/额度不足。
  budgetExhausted('budget_exhausted', 429),

  /// 能力不可用。
  modelUnavailable('model_unavailable', 503),

  /// 依赖不可用。
  unavailable('unavailable', 503),

  /// 宿主内部错误。
  internal('internal', 500);

  const ErrorCode(this.wire, this.httpStatus);

  /// 线上字符串。
  final String wire;

  /// 对应的 HTTP 状态码（WebSocket 用 1008/1011 语义另行处理）。
  final int httpStatus;

  /// 由领域失败分类映射。
  static ErrorCode fromFailure(FailureCode code) => switch (code) {
        FailureCode.invalidArgument => ErrorCode.invalidArgument,
        FailureCode.unauthenticated => ErrorCode.unauthenticated,
        FailureCode.forbidden => ErrorCode.forbidden,
        FailureCode.notFound => ErrorCode.notFound,
        FailureCode.conflict => ErrorCode.conflict,
        FailureCode.rateLimited => ErrorCode.rateLimited,
        FailureCode.budgetExhausted => ErrorCode.budgetExhausted,
        FailureCode.modelUnavailable => ErrorCode.modelUnavailable,
        FailureCode.internal => ErrorCode.internal,
        FailureCode.unavailable => ErrorCode.unavailable,
      };

  /// 由线上字符串还原；未知码按 internal 处理并保留原因。
  static ErrorCode? tryParse(String wire) {
    for (final code in ErrorCode.values) {
      if (code.wire == wire) return code;
    }
    return null;
  }
}
