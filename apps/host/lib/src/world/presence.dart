/// FR-36/FR-37 世界 presence：位置 2–5Hz 同步、拜访会话、门锁权威在宿主。
///
/// 位置权威在宿主：客户端只上报/插值，服务端是唯一状态源。拜访规则：
/// 好友可进小院；室内需邀请；单户同时访客上限 4；被拉黑方无法拜访（C-5）；
/// 主人不在时其 AI 可接待（默认开、可关）。门锁/被拒/超时回自家都记日志，
/// 不静默。宿主离线时位置冻结，恢复后续算，不补造"路上发生过什么"。
library;

import 'package:jingyu_core/jingyu_core.dart';

/// 三维位置。
class Position {
  const Position(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  Map<String, Object?> toJson() => {'x': x, 'y': y, 'z': z};
}

/// 形象动画状态（FR-40：idle / walk / wave / sit）。
enum PresenceMotion {
  idle('idle'),
  walk('walk'),
  sit('sit'),
  wave('wave');

  const PresenceMotion(this.wire);
  final String wire;
  static PresenceMotion? tryParse(String raw) {
    for (final motion in values) {
      if (motion.wire == raw) return motion;
    }
    return null;
  }
}

/// 拜访所在区域。
enum VisitLocation {
  yard('yard'),
  indoor('indoor');

  const VisitLocation(this.wire);
  final String wire;
}

/// 拜访会话状态。
enum VisitStatus {
  active('active'),
  ended('ended'),
  timedOut('timed_out'),
  denied('denied');

  const VisitStatus(this.wire);
  final String wire;
}

/// presence 上的一位置快照。
class PresenceRecord {
  const PresenceRecord({
    required this.residentId,
    required this.spaceId,
    required this.position,
    required this.motion,
    required this.updatedAt,
  });

  final String residentId;
  final String spaceId;
  final Position position;
  final PresenceMotion motion;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'residentId': residentId,
    'spaceId': spaceId,
    'position': position.toJson(),
    'motion': motion.wire,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

/// 一次拜访会话。
class VisitSession {
  const VisitSession({
    required this.visitId,
    required this.visitorId,
    required this.hostOwnerId,
    required this.location,
    required this.status,
    required this.startedAt,
    required this.endedAt,
  });

  final String visitId;
  final String visitorId;
  final String hostOwnerId;
  final VisitLocation location;
  final VisitStatus status;
  final DateTime startedAt;
  final DateTime? endedAt;

  bool get isActive => status == VisitStatus.active;

  Map<String, Object?> toJson() => {
    'visitId': visitId,
    'visitorId': visitorId,
    'hostOwnerId': hostOwnerId,
    'location': location.wire,
    'status': status.wire,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedAt': endedAt?.toUtc().toIso8601String(),
  };
}

/// presence 事件动作常量。门锁/被拒/超时回自家都需留痕（AC-22）。
abstract final class PresenceEventAction {
  static const String visitStarted = 'visit.started';
  static const String visitBlocked = 'visit.blocked';
  static const String visitNotFriend = 'visit.not_friend';
  static const String visitDoorLocked = 'visit.door_locked';
  static const String visitCapacityRejected = 'visit.capacity_rejected';
  static const String visitHostAbsent = 'visit.host_absent';
  static const String visitEnded = 'visit.ended';
  static const String visitTimeoutHome = 'visit.timeout_home';
}

/// 一条 presence 日志（不含正文；只记录动作与参与方）。
class PresenceEvent {
  const PresenceEvent({
    required this.action,
    required this.visitorId,
    required this.hostOwnerId,
    required this.visitId,
    required this.at,
    this.details = const <String, Object?>{},
  });

  final String action;
  final String? visitorId;
  final String? hostOwnerId;
  final String? visitId;
  final DateTime at;
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => {
    'action': action,
    'visitorId': visitorId,
    'hostOwnerId': hostOwnerId,
    'visitId': visitId,
    'at': at.toUtc().toIso8601String(),
    'details': details,
  };
}

/// 好友/拉黑/主人在场判定。由 social 模块提供真实实现。
abstract interface class VisitAccessPolicy {
  Future<bool> areFriends(String visitorId, String hostOwnerId);
  Future<bool> isBlocked(String visitorId, String hostOwnerId);

  /// 主人当前是否在场（在线）。
  Future<bool> isHostPresent(String hostOwnerId);

  /// 主人不在时其 AI 是否接待来访（默认开、可关）。
  Future<bool> aiReceivesWhileAbsent(String hostOwnerId);
}

/// 保守默认：没有任何好友关系。装配真实 social 策略前，不放开拜访。
class DefaultVisitAccessPolicy implements VisitAccessPolicy {
  const DefaultVisitAccessPolicy();

  @override
  Future<bool> areFriends(String visitorId, String hostOwnerId) async => false;

  @override
  Future<bool> isBlocked(String visitorId, String hostOwnerId) async => false;

  @override
  Future<bool> isHostPresent(String hostOwnerId) async => true;

  @override
  Future<bool> aiReceivesWhileAbsent(String hostOwnerId) async => true;
}

/// 单户同时访客上限（FR-37）。
const int maxVisitorsPerHost = 4;

/// Presence 服务契约：位置权威 + 拜访/门锁权威都在宿主。
abstract interface class PresenceService {
  /// 位置快照下发间隔，必须落在 2–5Hz（200–500ms，NFR-04）。
  Duration get syncInterval;

  /// 宿主在线/离线开关。离线时位置冻结，恢复后续算。
  Future<void> setOnline(bool online);

  /// 登记居民与其自家空间（用于超时/结束拜访后回家）。
  Future<Result<void>> registerResident({
    required String residentId,
    required String homeSpaceId,
  });

  /// 宿主权威地更新某居民位置。
  Future<Result<PresenceRecord>> move({
    required String residentId,
    required String spaceId,
    required Position position,
    required PresenceMotion motion,
  });

  /// 某空间内的位置快照（按 residentId 稳定排序）。
  Future<Result<List<PresenceRecord>>> positions(String spaceId);

  /// 单个居民当前快照。
  Future<Result<PresenceRecord>> record(String residentId);

  /// 按 visitId 取拜访会话（路由层据此做参与方鉴权）。
  Future<Result<VisitSession>> getVisit(String visitId);

  /// 主人给某访客发室内邀请，返回邀请 token。
  Future<Result<String>> grantInvitation({
    required String hostOwnerId,
    required String visitorId,
  });

  /// 发起拜访。小院需好友；室内需有效邀请；超出容量/被拉黑/主人不在且 AI 不接待则被拒。
  Future<Result<VisitSession>> requestVisit({
    required String visitorId,
    required String hostOwnerId,
    required VisitLocation location,
    String? invitationToken,
  });

  /// 主人侧的进行中拜访列表。
  Future<List<VisitSession>> activeVisits(String hostOwnerId);

  /// 正常结束拜访，访客回家。
  Future<Result<VisitSession>> endVisit(String visitId);

  /// 寻路卡住/超时回自家，并记日志（FR-36，不静默）。
  Future<Result<VisitSession>> timeoutVisit(String visitId);

  /// 日志，可按主人过滤。
  Future<List<PresenceEvent>> events({String? hostOwnerId});
}

/// 内存实现。
class InMemoryPresenceService implements PresenceService {
  InMemoryPresenceService({
    this.clock = const SystemClock(),
    VisitAccessPolicy? policy,
    String Function()? newId,
  }) : _policy = policy ?? const DefaultVisitAccessPolicy(),
       _newId = newId ?? _counterIds();

  final Clock clock;
  final VisitAccessPolicy _policy;
  final String Function() _newId;

  bool _online = true;
  final Map<String, String> _home = <String, String>{};
  final Map<String, PresenceRecord> _records = <String, PresenceRecord>{};
  final Map<String, VisitSession> _visits = <String, VisitSession>{};
  final Map<String, ({String visitorId, String hostOwnerId})> _invitations =
      <String, ({String visitorId, String hostOwnerId})>{};
  final List<PresenceEvent> _events = <PresenceEvent>[];

  static String Function() _counterIds() {
    var n = 0;
    return () => 'r${++n}';
  }

  @override
  Duration get syncInterval => const Duration(milliseconds: 250);

  @override
  Future<void> setOnline(bool online) async {
    _online = online;
  }

  @override
  Future<Result<void>> registerResident({
    required String residentId,
    required String homeSpaceId,
  }) async {
    try {
      validateId(residentId, kind: 'resident');
      validateId(homeSpaceId, kind: 'space');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'bad id');
    }
    _home[residentId] = homeSpaceId;
    _records.putIfAbsent(
      residentId,
      () => PresenceRecord(
        residentId: residentId,
        spaceId: homeSpaceId,
        position: const Position(0, 0, 0),
        motion: PresenceMotion.idle,
        updatedAt: clock.now().toUtc(),
      ),
    );
    return const Ok<void>(null);
  }

  @override
  Future<Result<PresenceRecord>> move({
    required String residentId,
    required String spaceId,
    required Position position,
    required PresenceMotion motion,
  }) async {
    if (!_online) {
      return err(FailureCode.unavailable, 'host offline: position frozen');
    }
    try {
      validateId(residentId, kind: 'resident');
      validateId(spaceId, kind: 'space');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'bad id');
    }
    if (!position.x.isFinite || !position.y.isFinite || !position.z.isFinite) {
      return err(FailureCode.invalidArgument, 'non-finite position');
    }
    if (!_records.containsKey(residentId)) {
      return err(FailureCode.notFound, 'resident not registered');
    }
    final updated = PresenceRecord(
      residentId: residentId,
      spaceId: spaceId,
      position: position,
      motion: motion,
      updatedAt: clock.now().toUtc(),
    );
    _records[residentId] = updated;
    return Ok(updated);
  }

  @override
  Future<Result<List<PresenceRecord>>> positions(String spaceId) async {
    try {
      validateId(spaceId, kind: 'space');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'bad space id');
    }
    final list =
        _records.values.where((record) => record.spaceId == spaceId).toList()
          ..sort((a, b) => a.residentId.compareTo(b.residentId));
    return Ok(List<PresenceRecord>.unmodifiable(list));
  }

  @override
  Future<Result<PresenceRecord>> record(String residentId) async {
    final record = _records[residentId];
    if (record == null) return err(FailureCode.notFound, 'resident not found');
    return Ok(record);
  }

  @override
  Future<Result<VisitSession>> getVisit(String visitId) async {
    final visit = _visits[visitId];
    if (visit == null) return err(FailureCode.notFound, 'visit not found');
    return Ok(visit);
  }

  @override
  Future<Result<String>> grantInvitation({
    required String hostOwnerId,
    required String visitorId,
  }) async {
    try {
      validateId(hostOwnerId, kind: 'owner');
      validateId(visitorId, kind: 'visitor');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'bad id');
    }
    final token = 'inv_${_newId()}';
    _invitations[token] = (visitorId: visitorId, hostOwnerId: hostOwnerId);
    return Ok(token);
  }

  @override
  Future<Result<VisitSession>> requestVisit({
    required String visitorId,
    required String hostOwnerId,
    required VisitLocation location,
    String? invitationToken,
  }) async {
    if (!_online) return err(FailureCode.unavailable, 'host offline');
    try {
      validateId(visitorId, kind: 'visitor');
      validateId(hostOwnerId, kind: 'owner');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'bad id');
    }
    final visitorRecord = _records[visitorId];
    if (visitorRecord == null || !_home.containsKey(visitorId)) {
      return err(FailureCode.notFound, 'visitor not registered');
    }
    if (await _policy.isBlocked(visitorId, hostOwnerId)) {
      _log(PresenceEventAction.visitBlocked, visitorId, hostOwnerId, null);
      return err(FailureCode.forbidden, 'blocked');
    }
    if (!await _policy.areFriends(visitorId, hostOwnerId)) {
      _log(PresenceEventAction.visitNotFriend, visitorId, hostOwnerId, null);
      return err(FailureCode.forbidden, 'not friends');
    }
    final activeCount = _visits.values
        .where((v) => v.hostOwnerId == hostOwnerId && v.isActive)
        .length;
    if (activeCount >= maxVisitorsPerHost) {
      _log(
        PresenceEventAction.visitCapacityRejected,
        visitorId,
        hostOwnerId,
        null,
      );
      return err(FailureCode.conflict, 'visit capacity reached');
    }
    if (location == VisitLocation.indoor) {
      final invitation = invitationToken == null
          ? null
          : _invitations[invitationToken];
      final valid =
          invitation != null &&
          invitation.visitorId == visitorId &&
          invitation.hostOwnerId == hostOwnerId;
      if (!valid) {
        _log(PresenceEventAction.visitDoorLocked, visitorId, hostOwnerId, null);
        return err(FailureCode.forbidden, 'indoor requires invitation');
      }
      if (!await _policy.isHostPresent(hostOwnerId)) {
        if (!await _policy.aiReceivesWhileAbsent(hostOwnerId)) {
          _log(
            PresenceEventAction.visitHostAbsent,
            visitorId,
            hostOwnerId,
            null,
          );
          return err(FailureCode.unavailable, 'host absent');
        }
      }
    }
    final now = clock.now().toUtc();
    final visit = VisitSession(
      visitId: 'visit_${_newId()}',
      visitorId: visitorId,
      hostOwnerId: hostOwnerId,
      location: location,
      status: VisitStatus.active,
      startedAt: now,
      endedAt: null,
    );
    _visits[visit.visitId] = visit;
    final hostSpace = _home[hostOwnerId] ?? hostOwnerId;
    _records[visitorId] = PresenceRecord(
      residentId: visitorId,
      spaceId: hostSpace,
      position: visitorRecord.position,
      motion: PresenceMotion.idle,
      updatedAt: now,
    );
    _log(
      PresenceEventAction.visitStarted,
      visitorId,
      hostOwnerId,
      visit.visitId,
    );
    return Ok(visit);
  }

  @override
  Future<List<VisitSession>> activeVisits(String hostOwnerId) async {
    final list =
        _visits.values
            .where((v) => v.hostOwnerId == hostOwnerId && v.isActive)
            .toList()
          ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return List<VisitSession>.unmodifiable(list);
  }

  @override
  Future<Result<VisitSession>> endVisit(String visitId) =>
      _finish(visitId, VisitStatus.ended, PresenceEventAction.visitEnded);

  @override
  Future<Result<VisitSession>> timeoutVisit(String visitId) => _finish(
    visitId,
    VisitStatus.timedOut,
    PresenceEventAction.visitTimeoutHome,
  );

  Future<Result<VisitSession>> _finish(
    String visitId,
    VisitStatus status,
    String action,
  ) async {
    final visit = _visits[visitId];
    if (visit == null) return err(FailureCode.notFound, 'visit not found');
    if (!visit.isActive) return err(FailureCode.conflict, 'visit not active');
    final ended = VisitSession(
      visitId: visit.visitId,
      visitorId: visit.visitorId,
      hostOwnerId: visit.hostOwnerId,
      location: visit.location,
      status: status,
      startedAt: visit.startedAt,
      endedAt: clock.now().toUtc(),
    );
    _visits[visitId] = ended;
    final home = _home[visit.visitorId];
    final current = _records[visit.visitorId];
    if (home != null && current != null) {
      _records[visit.visitorId] = PresenceRecord(
        residentId: visit.visitorId,
        spaceId: home,
        position: current.position,
        motion: PresenceMotion.idle,
        updatedAt: clock.now().toUtc(),
      );
    }
    _log(action, visit.visitorId, visit.hostOwnerId, visit.visitId);
    return Ok(ended);
  }

  @override
  Future<List<PresenceEvent>> events({String? hostOwnerId}) async {
    final list = hostOwnerId == null
        ? List<PresenceEvent>.of(_events)
        : _events.where((e) => e.hostOwnerId == hostOwnerId).toList();
    return List<PresenceEvent>.unmodifiable(list);
  }

  void _log(
    String action,
    String? visitorId,
    String? hostOwnerId,
    String? visitId,
  ) {
    _events.add(
      PresenceEvent(
        action: action,
        visitorId: visitorId,
        hostOwnerId: hostOwnerId,
        visitId: visitId,
        at: clock.now().toUtc(),
      ),
    );
  }
}
