import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// Outcome of one `GET /auth/devices` read.
///
/// [loaded] means the host returned a fully valid list (which may be empty).
/// Every other value means no list may be rendered or inferred.
enum DeviceSessionsStatus { loaded, unauthenticated, unavailable, malformed }

/// One device row. Metadata only: the host never sends tokens here, and this
/// type has no field that could retain one.
class DeviceSummary {
  const DeviceSummary({
    required this.id,
    required this.deviceName,
    required this.lastUsedAt,
    this.current = false,
  });

  /// Validated device id (1–64 URL-safe characters).
  final String id;
  final String deviceName;

  /// Host-reported `lastUsedAt`, always UTC.
  final DateTime lastUsedAt;

  /// True only when the host explicitly marks this row as the current device.
  ///
  /// The host's device list currently omits any current-device marker, so this
  /// stays false and the UI must not guess.
  final bool current;

  @override
  String toString() => 'DeviceSummary($id, current=$current)';
}

/// Immutable read result. Excludes transport text, tokens and upstream bodies.
class DeviceSessionsRead {
  const DeviceSessionsRead(this.status, [this.devices = const []]);

  DeviceSessionsRead.loaded(List<DeviceSummary> devices)
    : this(
        DeviceSessionsStatus.loaded,
        List<DeviceSummary>.unmodifiable(devices),
      );

  final DeviceSessionsStatus status;
  final List<DeviceSummary> devices;

  @override
  String toString() => 'DeviceSessionsRead(${status.name})';
}

/// Outcome of one explicit `POST /auth/devices/{deviceId}/revoke`.
enum DeviceRevokeStatus {
  /// The host confirmed the device is gone. Never assumed.
  revoked,
  unauthenticated,
  notFound,
  unavailable,
  malformed,
}

/// One revoke attempt's outcome for exactly one device id.
class DeviceRevokeOutcome {
  const DeviceRevokeOutcome(this.status, this.deviceId);

  const DeviceRevokeOutcome.revoked(String deviceId)
    : this(DeviceRevokeStatus.revoked, deviceId);
  const DeviceRevokeOutcome.unauthenticated(String deviceId)
    : this(DeviceRevokeStatus.unauthenticated, deviceId);
  const DeviceRevokeOutcome.notFound(String deviceId)
    : this(DeviceRevokeStatus.notFound, deviceId);
  const DeviceRevokeOutcome.unavailable(String deviceId)
    : this(DeviceRevokeStatus.unavailable, deviceId);
  const DeviceRevokeOutcome.malformed(String deviceId)
    : this(DeviceRevokeStatus.malformed, deviceId);

  final DeviceRevokeStatus status;
  final String deviceId;

  bool get confirmed => status == DeviceRevokeStatus.revoked;

  @override
  String toString() => 'DeviceRevokeOutcome(${status.name}, $deviceId)';
}

/// Typed access to the host device-session routes.
///
/// Reads `GET /auth/devices`; the only write is an explicit remote sign-off for
/// one device id (`POST /auth/devices/{deviceId}/revoke`). Parsing is strict:
/// the response must be the host's plain array of exactly `id`, `deviceName`,
/// `lastUsedAt` (plus an optional boolean `current`), ids must be valid device
/// ids, names non-empty and timestamps strict UTC. Unknown or foreign keys,
/// duplicates and malformed values make the whole read [malformed] rather than
/// partially trusted.
///
/// No method throws transport errors at the UI: every failure becomes a typed
/// outcome. Revoke never renews or replays after a 401; retrying requires a new
/// explicit user action.
class DeviceSessionsApi {
  DeviceSessionsApi(this.connection);

  final HostConnection connection;

  static final _utcTimestamp = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?Z$',
  );
  static final _control = RegExp(r'[\x00-\x1f\x7f-\x9f]');

  /// Read the caller's signed-in devices.
  Future<DeviceSessionsRead> listDevices() async {
    final List<Object?> rows;
    try {
      rows = await connection.requestList('GET', Routes.authDevices);
    } on HostRequestException catch (error) {
      return DeviceSessionsRead(
        switch (error.failure.code) {
          FailureCode.unauthenticated ||
          FailureCode.forbidden => DeviceSessionsStatus.unauthenticated,
          _ => DeviceSessionsStatus.unavailable,
        },
      );
    } on FormatException {
      return const DeviceSessionsRead(DeviceSessionsStatus.malformed);
    } on TimeoutException {
      return const DeviceSessionsRead(DeviceSessionsStatus.unavailable);
    } on TlsException {
      return const DeviceSessionsRead(DeviceSessionsStatus.unavailable);
    } on SocketException {
      return const DeviceSessionsRead(DeviceSessionsStatus.unavailable);
    } on HttpException {
      return const DeviceSessionsRead(DeviceSessionsStatus.unavailable);
    }
    try {
      final devices = <DeviceSummary>[];
      final seen = <String>{};
      for (final row in rows) {
        final device = _parseDevice(row);
        if (!seen.add(device.id)) throw const FormatException();
        devices.add(device);
      }
      return DeviceSessionsRead.loaded(devices);
    } on FormatException {
      return const DeviceSessionsRead(DeviceSessionsStatus.malformed);
    }
  }

  /// Explicitly sign one device off. Returns a typed outcome; never throws for
  /// transport or host failures.
  Future<DeviceRevokeOutcome> revokeDevice(String deviceId) async {
    final String id;
    try {
      id = DeviceId.parse(deviceId).value;
    } on FormatException {
      // Local argument rejection happens before any request is issued.
      throw const FormatException('设备标识非法');
    }
    try {
      final body = await connection.request(
        'POST',
        Routes.authDeviceRevoke.replaceFirst(
          '{deviceId}',
          Uri.encodeComponent(id),
        ),
        retryAuthentication: false,
        allowEmptySuccess: true,
      );
      // The host answers a void success with an empty body; a documented
      // acknowledgement is also accepted. Anything else is not confirmation.
      if (body.isEmpty || (body.length == 1 && body['revoked'] == true)) {
        return DeviceRevokeOutcome.revoked(id);
      }
      return DeviceRevokeOutcome.malformed(id);
    } on HostRequestException catch (error) {
      return DeviceRevokeOutcome(
        switch (error.failure.code) {
          FailureCode.unauthenticated ||
          FailureCode.forbidden => DeviceRevokeStatus.unauthenticated,
          FailureCode.notFound => DeviceRevokeStatus.notFound,
          _ => DeviceRevokeStatus.unavailable,
        },
        id,
      );
    } on FormatException {
      return DeviceRevokeOutcome.malformed(id);
    } on TimeoutException {
      return DeviceRevokeOutcome.unavailable(id);
    } on TlsException {
      return DeviceRevokeOutcome.unavailable(id);
    } on SocketException {
      return DeviceRevokeOutcome.unavailable(id);
    } on HttpException {
      return DeviceRevokeOutcome.unavailable(id);
    }
  }

  static DeviceSummary _parseDevice(Object? value) {
    if (value is! Map) throw const FormatException();
    if (value.keys.any((key) => key is! String)) throw const FormatException();
    final row = value.cast<String, Object?>();
    const required = {'id', 'deviceName', 'lastUsedAt'};
    if (!required.every(row.containsKey) ||
        row.keys.any((key) => !required.contains(key) && key != 'current')) {
      throw const FormatException();
    }
    final rawId = row['id'];
    final rawName = row['deviceName'];
    final rawUsed = row['lastUsedAt'];
    final rawCurrent = row['current'];
    if (rawId is! String ||
        rawName is! String ||
        rawUsed is! String ||
        (row.containsKey('current') && rawCurrent is! bool)) {
      throw const FormatException();
    }
    final id = DeviceId.parse(rawId).value;
    // The host trims names on registration and bounds them at 100 characters.
    if (rawName.trim().isEmpty ||
        rawName.trim().length > 100 ||
        _control.hasMatch(rawName)) {
      throw const FormatException();
    }
    return DeviceSummary(
      id: id,
      deviceName: rawName,
      lastUsedAt: _parseUtc(rawUsed),
      current: rawCurrent == true,
    );
  }

  /// Strict RFC 3339 UTC: `YYYY-MM-DDTHH:MM:SS[.ffffff]Z`, real calendar values.
  static DateTime _parseUtc(String raw) {
    final match = _utcTimestamp.firstMatch(raw);
    if (match == null) throw const FormatException();
    int field(int group) => int.parse(match.group(group)!);
    final year = field(1),
        month = field(2),
        day = field(3),
        hour = field(4),
        minute = field(5),
        second = field(6);
    final fraction = match.group(7);
    final micros = fraction == null
        ? 0
        : int.parse(fraction.padRight(6, '0'));
    final parsed = DateTime.utc(year, month, day, hour, minute, second, 0, micros);
    // DateTime.utc normalizes overflow (e.g. 02-30 -> 03-02); reject that.
    if (parsed.year != year ||
        parsed.month != month ||
        parsed.day != day ||
        parsed.hour != hour ||
        parsed.minute != minute ||
        parsed.second != second) {
      throw const FormatException();
    }
    return parsed;
  }
}
