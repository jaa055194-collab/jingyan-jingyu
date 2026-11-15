import 'shell_view_model.dart';

/// Maps the host's group (`/conversations`) and direct (`/direct-conversations`)
/// payloads into the shell's conversation list.
///
/// Group payloads carry `name`; direct payloads only carry the two account ids,
/// so they get a stable neutral label instead of inventing a display name.
List<ShellConversation> mapConversations({
  required Object? groups,
  required Object? directs,
}) {
  final byId = <String, ShellConversation>{};

  void add(Map raw, {required bool direct}) {
    final id = raw['id'];
    if (id is! String || id.isEmpty) return;
    final name = raw['name'] is String ? (raw['name'] as String).trim() : '';
    final title = name.isNotEmpty
        ? name
        : direct
        ? '私聊'
        : '会话';
    byId[id] = ShellConversation(
      id: id,
      title: title,
      kind: direct ? 'direct' : 'group',
      ownerAccountId: !direct && raw['ownerAccountId'] is String
          ? raw['ownerAccountId'] as String
          : null,
    );
  }

  if (groups is List) {
    for (final item in groups) {
      if (item is Map) add(item, direct: false);
    }
  }
  if (directs is List) {
    for (final item in directs) {
      if (item is Map) add(item, direct: true);
    }
  }
  final result = byId.values.toList()
    ..sort((a, b) => a.title.compareTo(b.title));
  return result;
}
