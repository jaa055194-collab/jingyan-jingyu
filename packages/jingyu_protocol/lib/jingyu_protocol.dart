/// 鲸言鲸语线协议。
///
/// 三个目标：
/// 1. 双端与宿主共用同一套帧定义，避免"两边各写一份 JSON"；
/// 2. 解析失败必须显式失败（[Result]），不做宽松兜底；
/// 3. 版本号内建在信封里，为后续演进留位置。
library;

export 'src/codec.dart';
export 'src/error_codes.dart';
export 'src/frames.dart';
export 'src/routes.dart';
