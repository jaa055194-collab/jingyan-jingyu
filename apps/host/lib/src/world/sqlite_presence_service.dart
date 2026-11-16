/// FR-36/FR-37 presence 的 SQLite 实现。与 `InMemoryPresenceService` 共用同一组契约测试。
///
/// 位置权威、拜访会话、门锁与日志都落库；`_online` 是宿主进程级状态（离线冻结）。
library;

import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'database_visit_access_policy.dart';
import 'presence.dart';

class SqlitePresenceService implements PresenceService {
  SqlitePresenceService({
    required this.database,
    this.clock = const SystemClock(),
    VisitAccessPolicy? policy,
  }) : _policy = policy ?? DatabaseVisitAccessPolicy(database: database);

  final Database database;
  final Clock clock;
  final VisitAccessPolicy _policy;

  bool _online = true;
  int _seq = 0;

  @override
  Duration get syncInterval => const Duration(milliseconds: 250);

  @override
  Future<void> setOnline(bool online) async {
    _online = online;
  }

  static VisitLocation _location(Object? raw) =>
      raw == VisitLocation.indoor.wire
      ? VisitLocation.indoor
      : VisitLocation.yard;

  static VisitStatus _status(Object? raw) => switch (raw) {
    'ended' => VisitStatus.ended,
    'timed_out' => VisitStatus.timedOut,
    'denied' => VisitStatus.denied,
    _ => VisitStatus.active,
  };

  PresenceRecord? _toRecord(Map<String, Object?> row) {
    try {
      return PresenceRecord(
        residentId: row['resident_id'] as String,
        spaceId: row['space_id'] as String,
        position: Position(
          (row['x'] as num).toDouble(),
          (row['y'] as num).toDouble(),
          (row['z'] as num).toDouble(),
        ),
        motion:
            PresenceMotion.tryParse(row['motion'] as String) ??
            PresenceMotion.idle,
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  VisitSession? _toVisit(Map<String, Object?> row) {
    try {
      final endedRaw = row['ended_at'];
      return VisitSession(
        visitId: row['visit_id'] as String,
        visitorId: row['visitor_id'] as String,
        hostOwnerId: row['host_owner_id'] as String,
        location: _location(row['location']),
        status: _status(row['status']),
        startedAt: DateTime.parse(row['started_at'] as String),
        endedAt: endedRaw is String ? DateTime.parse(endedRaw) : null,
      );
    } catch (_) {
      return null;
    }
  }

  PresenceEvent? _toEvent(Map<String, Object?> row) {
    try {
      final rawDetails = row['details'];
      final decoded = rawDetails is String ? jsonDecode(rawDetails) : null;
      return PresenceEvent(
        action: row['action'] as String,
        visitorId: row['visitor_id'] as String?,
        hostOwnerId: row['host_owner_id'] as String?,
        visitId: row['visit_id'] as String?,
        at: DateTime.parse(row['at'] as String),
        details: decoded is Map<String, dynamic>
            ? Map<String, Object?>.unmodifiable(decoded.cast<String, Object?>())
            : const <String, Object?>{},
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _log(
    String action,
    String? visitorId,
    String? hostOwnerId,
    String? visitId,
  ) async {
    await database.execute(
      'INSERT INTO world_presence_events('
      'action, visitor_id, host_owner_id, visit_id, at, details'
      ') VALUES(?,?,?,?,?,?)',
      [
        action,
        visitorId,
        hostOwnerId,
        visitId,
        clock.now().toUtc().toIso8601String(),
        '{}',
      ],
    );
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
    final now = clock.now().toUtc();
    await database.execute(
      'INSERT INTO world_presence('
      'resident_id, space_id, home_space_id, x, y, z, motion, updated_at'
      ') VALUES(?,?,?,0,0,0,?,?) '
      'ON CONFLICT(resident_id) DO UPDATE SET '
      'home_space_id=excluded.home_space_id',
      [
        residentId,
        homeSpaceId,
        homeSpaceId,
        PresenceMotion.idle.wire,
        now.toIso8601String(),
      ],
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
    final rows = await database.query(
      'SELECT resident_id FROM world_presence WHERE resident_id = ?',
      [residentId],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'resident not found');
    final now = clock.now().toUtc();
    await database.execute(
      'UPDATE world_presence SET space_id=?, x=?, y=?, z=?, motion=?, updated_at=? '
      'WHERE resident_id=?',
      [
        spaceId,
        position.x,
        position.y,
        position.z,
        motion.wire,
        now.toIso8601String(),
        residentId,
      ],
    );
    return Ok(
      PresenceRecord(
        residentId: residentId,
        spaceId: spaceId,
        position: position,
        motion: motion,
        updatedAt: now,
      ),
    );
  }

  @override
  Future<Result<List<PresenceRecord>>> positions(String spaceId) async {
    try {
      validateId(spaceId, kind: 'space');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'bad space id');
    }
    final rows = await database.query(
      'SELECT * FROM world_presence WHERE space_id = ? ORDER BY resident_id',
      [spaceId],
    );
    final records = <PresenceRecord>[];
    for (final row in rows) {
      final record = _toRecord(row);
      if (record == null) {
        return err(FailureCode.internal, 'corrupt presence row');
      }
      records.add(record);
    }
    return Ok(List<PresenceRecord>.unmodifiable(records));
  }

  @override
  Future<Result<PresenceRecord>> record(String residentId) async {
    final rows = await database.query(
      'SELECT * FROM world_presence WHERE resident_id = ?',
      [residentId],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'resident not found');
    final record = _toRecord(rows.single);
    if (record == null) {
      return err(FailureCode.internal, 'corrupt presence row');
    }
    return Ok(record);
  }

  @override
  Future<Result<VisitSession>> getVisit(String visitId) async {
    final rows = await database.query(
      'SELECT * FROM world_visits WHERE visit_id = ?',
      [visitId],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'visit not found');
    final visit = _toVisit(rows.single);
    if (visit == null) return err(FailureCode.internal, 'corrupt visit row');
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
    final now = clock.now().toUtc();
    final token = 'inv_${now.microsecondsSinceEpoch}_${++_seq}';
    await database.execute(
      'INSERT INTO world_invitations(token, visitor_id, host_owner_id, created_at) '
      'VALUES(?,?,?,?)',
      [token, visitorId, hostOwnerId, now.toIso8601String()],
    );
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
    final visitorRows = await database.query(
      'SELECT home_space_id FROM world_presence WHERE resident_id = ?',
      [visitorId],
    );
    if (visitorRows.isEmpty) {
      return err(FailureCode.notFound, 'visitor not registered');
    }
    if (await _policy.isBlocked(visitorId, hostOwnerId)) {
      await _log(
        PresenceEventAction.visitBlocked,
        visitorId,
        hostOwnerId,
        null,
      );
      return err(FailureCode.forbidden, 'blocked');
    }
    if (!await _policy.areFriends(visitorId, hostOwnerId)) {
      await _log(
        PresenceEventAction.visitNotFriend,
        visitorId,
        hostOwnerId,
        null,
      );
      return err(FailureCode.forbidden, 'not friends');
    }
    final countRows = await database.query(
      "SELECT COUNT(*) AS c FROM world_visits "
      "WHERE host_owner_id = ? AND status = 'active'",
      [hostOwnerId],
    );
    final activeCount = countRows.single['c'] as int;
    if (activeCount >= maxVisitorsPerHost) {
      await _log(
        PresenceEventAction.visitCapacityRejected,
        visitorId,
        hostOwnerId,
        null,
      );
      return err(FailureCode.conflict, 'visit capacity reached');
    }
    if (location == VisitLocation.indoor) {
      final invitation = invitationToken == null
          ? const <Map<String, Object?>>[]
          : await database.query(
              'SELECT visitor_id, host_owner_id FROM world_invitations WHERE token = ?',
              [invitationToken],
            );
      final valid =
          invitation.isNotEmpty &&
          invitation.single['visitor_id'] == visitorId &&
          invitation.single['host_owner_id'] == hostOwnerId;
      if (!valid) {
        await _log(
          PresenceEventAction.visitDoorLocked,
          visitorId,
          hostOwnerId,
          null,
        );
        return err(FailureCode.forbidden, 'indoor requires invitation');
      }
      if (!await _policy.isHostPresent(hostOwnerId)) {
        if (!await _policy.aiReceivesWhileAbsent(hostOwnerId)) {
          await _log(
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
    final visitId = 'visit_${now.microsecondsSinceEpoch}_${++_seq}';
    final hostRows = await database.query(
      'SELECT home_space_id FROM world_presence WHERE resident_id = ?',
      [hostOwnerId],
    );
    final hostSpace = hostRows.isEmpty
        ? hostOwnerId
        : hostRows.single['home_space_id'] as String;
    await database.execute(
      'UPDATE world_presence SET space_id=?, motion=?, updated_at=? WHERE resident_id=?',
      [hostSpace, PresenceMotion.idle.wire, now.toIso8601String(), visitorId],
    );
    await database.execute(
      'INSERT INTO world_visits('
      'visit_id, visitor_id, host_owner_id, location, status, started_at, ended_at'
      ') VALUES(?,?,?,?,?,?,NULL)',
      [
        visitId,
        visitorId,
        hostOwnerId,
        location.wire,
        VisitStatus.active.wire,
        now.toIso8601String(),
      ],
    );
    await _log(
      PresenceEventAction.visitStarted,
      visitorId,
      hostOwnerId,
      visitId,
    );
    return Ok(
      VisitSession(
        visitId: visitId,
        visitorId: visitorId,
        hostOwnerId: hostOwnerId,
        location: location,
        status: VisitStatus.active,
        startedAt: now,
        endedAt: null,
      ),
    );
  }

  @override
  Future<List<VisitSession>> activeVisits(String hostOwnerId) async {
    final rows = await database.query(
      "SELECT * FROM world_visits WHERE host_owner_id = ? AND status = 'active' "
      'ORDER BY started_at',
      [hostOwnerId],
    );
    final visits = <VisitSession>[];
    for (final row in rows) {
      final visit = _toVisit(row);
      if (visit != null) visits.add(visit);
    }
    return List<VisitSession>.unmodifiable(visits);
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
    final rows = await database.query(
      'SELECT * FROM world_visits WHERE visit_id = ?',
      [visitId],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'visit not found');
    final visit = _toVisit(rows.single);
    if (visit == null) return err(FailureCode.internal, 'corrupt visit row');
    if (!visit.isActive) return err(FailureCode.conflict, 'visit not active');
    final now = clock.now().toUtc();
    await database.execute(
      'UPDATE world_visits SET status=?, ended_at=? WHERE visit_id=?',
      [status.wire, now.toIso8601String(), visitId],
    );
    final homeRows = await database.query(
      'SELECT home_space_id FROM world_presence WHERE resident_id = ?',
      [visit.visitorId],
    );
    if (homeRows.isNotEmpty) {
      await database.execute(
        'UPDATE world_presence SET space_id=?, motion=?, updated_at=? '
        'WHERE resident_id=?',
        [
          homeRows.single['home_space_id'],
          PresenceMotion.idle.wire,
          now.toIso8601String(),
          visit.visitorId,
        ],
      );
    }
    await _log(action, visit.visitorId, visit.hostOwnerId, visit.visitId);
    return Ok(
      VisitSession(
        visitId: visit.visitId,
        visitorId: visit.visitorId,
        hostOwnerId: visit.hostOwnerId,
        location: visit.location,
        status: status,
        startedAt: visit.startedAt,
        endedAt: now,
      ),
    );
  }

  @override
  Future<List<PresenceEvent>> events({String? hostOwnerId}) async {
    final rows = hostOwnerId == null
        ? await database.query(
            'SELECT * FROM world_presence_events ORDER BY id',
          )
        : await database.query(
            'SELECT * FROM world_presence_events WHERE host_owner_id = ? ORDER BY id',
            [hostOwnerId],
          );
    final events = <PresenceEvent>[];
    for (final row in rows) {
      final event = _toEvent(row);
      if (event != null) events.add(event);
    }
    return List<PresenceEvent>.unmodifiable(events);
  }
}
