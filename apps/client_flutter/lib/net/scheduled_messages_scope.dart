import 'host_connection.dart';

/// Captured only after the authenticated editor rechecks the exact visible
/// group, account epoch, connection and route. A hidden session supplies no
/// API; the UI does not manufacture one from an arbitrary HostConnection.
class ScheduledMessagesScope {
  const ScheduledMessagesScope({
    required this.transport,
    required this.conversationId,
    required this.isCurrent,
    required this.canContactHost,
  });

  final HostConnection transport;
  final String conversationId;
  final bool Function() isCurrent;
  final bool Function() canContactHost;
}
