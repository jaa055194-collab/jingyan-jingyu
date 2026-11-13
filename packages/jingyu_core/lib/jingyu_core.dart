/// 鲸言鲸语领域原语。
///
/// 这一层只放"全系统都必须认同的词汇与不变量"，不放业务编排：
/// 标识、结果类型、时钟、可见性范围、记忆分层、token 预算分层。
/// 需求依据见 `docs/architecture/01-layering.md`。
library;

export 'src/audience.dart';
export 'src/budget.dart';
export 'src/clock.dart';
export 'src/ids.dart';
export 'src/memory.dart';
export 'src/result.dart';
