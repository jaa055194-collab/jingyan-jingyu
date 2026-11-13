/// 可见性与受众范围。
///
/// 服务端逐条判定，客户端过滤不算数（FR-27、NFR-09）。
library;

import 'result.dart';

/// 内容可见范围。
enum Audience {
  /// 仅自己可见（含"仅自己"的动态、日记默认可见性）。
  self,

  /// 好友可见（动态默认值）。
  friends,

  /// 圈内全部账号可见。
  circle,
}

/// 扩展方法：判定某个人能否看到该范围的内容。
extension AudienceVisibility on Audience {
  /// [isSelf] 为内容拥有者本人；[isFriend] 为与拥有者存在有效好友关系。
  ///
  /// 注意：拉黑的双向阻断由调用方先行判定，本方法不感知拉黑（FR-08）。
  bool allows({required bool isSelf, required bool isFriend}) => switch (this) {
        Audience.self => isSelf,
        Audience.friends => isSelf || isFriend,
        Audience.circle => true,
      };
}

/// 内容可见性判定的输入。
///
/// 把它作为服务方法的入参而不是散落的布尔参数，是为了让
/// "谁在看、看的是什么对象"在签名上就无法省略。
class ViewerContext {
  const ViewerContext({
    required this.viewerId,
    required this.ownerId,
    this.isFriend = false,
    this.isBlocked = false,
  });

  /// 请求者账号。
  final String viewerId;

  /// 内容拥有者账号。
  final String ownerId;

  /// 二者是否存在有效好友关系。
  final bool isFriend;

  /// 是否存在任一方向的拉黑；为 true 时一切非自我可见全部拒绝。
  final bool isBlocked;

  bool get isSelf => viewerId == ownerId;

  /// 综合判定。
  Result<bool> canSee(Audience audience) {
    if (isSelf) return const Ok<bool>(true);
    if (isBlocked) return const Ok<bool>(false);
    return Ok<bool>(audience.allows(isSelf: false, isFriend: isFriend));
  }
}
