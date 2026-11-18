import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// One notification item. Metadata only; never contains private body, message
/// text, or blob bytes.
class NotificationItem {
  const NotificationItem({
    required this.kind,
    required this.title,
    required this.status,
    required this.createdAt,
    required this.refId,
  });

  final String kind;
  final String title;
  final String status;
  final String createdAt;
  final String refId;

  factory NotificationItem.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('通知响应无效');
    }
    const keys = {'kind', 'title', 'status', 'createdAt', 'refId'};
    final kind = json['kind'];
    final title = json['title'];
    final status = json['status'];
    final createdAt = json['createdAt'];
    final refId = json['refId'];
    if (json.length != keys.length ||
        json.keys.any((key) => !keys.contains(key)) ||
        kind is! String ||
        kind.isEmpty ||
        title is! String ||
        title.isEmpty ||
        status is! String ||
        status.isEmpty ||
        createdAt is! String ||
        createdAt.isEmpty ||
        refId is! String ||
        refId.isEmpty) {
      throw const FormatException('通知响应无效');
    }
    return NotificationItem(
      kind: kind,
      title: title,
      status: status,
      createdAt: createdAt,
      refId: refId,
    );
  }
}

/// Read-only adapter for the host notifications/inbox route.
///
/// Host contract (owner-scoped, pending friend invitations only):
/// `GET /api/v1/notifications?limit=` -> `[{kind, title, status, createdAt,
/// refId}]`. No private content is requested or surfaced.
class NotificationApi {
  NotificationApi(this.connection);

  final HostConnection connection;

  Future<List<NotificationItem>> readNotifications({
    bool retryAuthentication = true,
    int limit = 50,
  }) async {
    if (limit < 1 || limit > 100) {
      throw const FormatException('通知数量参数非法');
    }
    try {
      final rows = await connection.requestList(
        'GET',
        Routes.notifications,
        query: {'limit': '$limit'},
        retryAuthentication: retryAuthentication,
      );
      return List<NotificationItem>.unmodifiable(
        rows.map(NotificationItem.fromJson),
      );
    } on FormatException {
      throw const FormatException('通知响应无效');
    } on SocketException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on HttpException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on TlsException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on TimeoutException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    }
  }
}
