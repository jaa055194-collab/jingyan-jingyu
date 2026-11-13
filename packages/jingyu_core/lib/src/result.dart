/// 统一的结果类型。
///
/// 框架内的可预期失败（校验失败、无权限、配额耗尽……）一律用返回值表达，
/// 不用异常穿透模块边界；异常只保留给真正的程序缺陷。
library;

/// 失败原因分类。
///
/// 这些分类直接对应协议错误码（见 `jingyu_protocol`），
/// 新增分类时必须同步协议层映射，否则客户端会收到未定义的码。
enum FailureCode {
  /// 入参不合法（含标识格式、字段缺失、类型不符）。
  invalidArgument,

  /// 未登录、token 过期或已吊销。
  unauthenticated,

  /// 已登录但无权限（含跨用户、拉黑、可见性判定失败）。
  forbidden,

  /// 目标不存在，或存在但请求者不可见——对外统一按不存在回答，避免探测。
  notFound,

  /// 与当前状态冲突（重复兑换、版本号不匹配等）。
  conflict,

  /// 触发限流。
  rateLimited,

  /// 预算或用量额度不足：分层预算降级、FR-58 硬停。
  budgetExhausted,

  /// 模型/语音/生图能力不可用。注意：不可用不等于可以换绑或换音色。
  modelUnavailable,

  /// 宿主内部错误。对外不暴露细节。
  internal,

  /// 依赖服务暂时不可用（宿主离线、隧道中断）。
  unavailable,
}

/// 一次失败的结构化描述。
///
/// [details] 只放可安全外发的机器可读字段：禁止写入正文、音频、API key
/// （NFR-06、NFR-10）。
class Failure {
  const Failure(
    this.code,
    this.message, {
    this.details = const <String, Object?>{},
  });

  final FailureCode code;

  /// 面向开发者的简短说明；服务端对外返回时按 [FailureCode] 映射固定文案。
  final String message;

  final Map<String, Object?> details;

  Failure withDetail(String key, Object? value) => Failure(
        code,
        message,
        details: {...details, key: value},
      );

  @override
  String toString() => 'Failure(${code.name}, $message)';
}

/// 成功或失败。
sealed class Result<T> {
  const Result();

  /// 成功值。
  ///
  /// 只能在已判定为 [Ok] 的路径上使用；失败时抛 [StateError]。
  /// 需要"失败就继续传递"时请用 [map] / [flatMap]，不要用本取值器。
  T get value;

  /// 成功值；失败时为 null。
  T? get valueOrNull;

  /// 失败信息；成功时为 null。
  Failure? get failureOrNull;

  bool get isOk => this is Ok<T>;

  bool get isErr => this is Err<T>;

  /// 变换成功值，失败原样传递。
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
        Ok<T>(:final value) => Ok<R>(transform(value)),
        Err<T>(:final failure) => Err<R>(failure),
      };

  /// 在成功值上继续可能失败的计算。
  Result<R> flatMap<R>(Result<R> Function(T value) next) => switch (this) {
        Ok<T>(:final value) => next(value),
        Err<T>(:final failure) => Err<R>(failure),
      };

  /// 取值，失败时抛出用于程序缺陷场景的异常。业务路径不要用它。
  T unwrap() => value;
}

/// 成功。
final class Ok<T> extends Result<T> {
  const Ok(this.value);

  /// 成功值。
  @override
  final T value;

  @override
  T get valueOrNull => value;

  @override
  Failure? get failureOrNull => null;

  @override
  String toString() => 'Ok($value)';
}

/// 失败。
final class Err<T> extends Result<T> {
  const Err(this.failure);

  /// 失败信息。
  final Failure failure;

  @override
  T get value =>
      throw StateError('对 Err 调用了 value：$failure');

  @override
  T? get valueOrNull => null;

  @override
  Failure get failureOrNull => failure;

  @override
  String toString() => 'Err($failure)';
}

/// 快捷构造。
Result<T> ok<T>(T value) => Ok<T>(value);

/// 快捷构造。
Result<T> err<T>(FailureCode code, String message,
        [Map<String, Object?> details = const {}]) =>
    Err<T>(Failure(code, message, details: details));
