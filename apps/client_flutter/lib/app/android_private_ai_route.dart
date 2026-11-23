import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../features/chat/android_private_ai_screen.dart';
import '../net/android_private_chat_sync_api.dart';
import '../net/android_private_model_api.dart';
import '../net/owner_ai_direct_api.dart';
import '../net/owner_ai_readiness_api.dart';
import '../net/owner_model_proactive_api.dart';
import '../net/owner_reply_preferences_api.dart';
import '../net/owner_rule_greeting_api.dart';
import '../net/owner_social_level_api.dart';
import 'android_private_ai_chat_controller.dart';
import 'runtime.dart';
import 'shell_view_model.dart';

/// Builds one Android-only self-AI route. The route owns controller disposal and
/// never publishes into the ordinary conversation list.
class AndroidPrivateAiRoute extends StatefulWidget {
  const AndroidPrivateAiRoute({
    super.key,
    required this.runtime,
    required this.ai,
    required this.interaction,
  });

  final ClientRuntime runtime;
  final ShellOwnedAi ai;
  final Object interaction;

  @override
  State<AndroidPrivateAiRoute> createState() => _AndroidPrivateAiRouteState();
}

class _AndroidPrivateAiRouteState extends State<AndroidPrivateAiRoute> {
  late final AndroidPrivateAiChatController chat;
  final AndroidPrivateModelApi _model = AndroidPrivateModelApi();

  @override
  void initState() {
    super.initState();
    final runtime = widget.runtime;
    final ai = widget.ai;
    final interaction = widget.interaction;
    final owner = runtime.connectedAccountId;
    final session = runtime.ownAiSessionContext;
    bool isCurrent() =>
        mounted &&
        runtime.authenticated &&
        !runtime.locked &&
        runtime.connectedAccountId == owner &&
        runtime.ownAiSessionContext == session &&
        identical(runtime.ownAiDirectContext, interaction) &&
        runtime.ownAiAccounts.any(
          (row) => row.accountId == ai.accountId && !row.disabled,
        );
    chat = AndroidPrivateAiChatController(
      aiName: ai.displayName,
      session: runtime,
      isSessionCurrent: isCurrent,
      isHostOnline: () => runtime.online,
      read: () => runtime.readAndroidPrivateAiVault('chat', ai.accountId),
      write: (record) =>
          runtime.writeAndroidPrivateAiVault('chat', ai.accountId, record),
      loadProfile: () => _loadProfile(runtime, ai, owner, isCurrent),
      loadBehavior: (profile) => _loadBehavior(runtime, profile, isCurrent),
      parseEndpoint: AndroidPrivateModelApi.parseEndpoint,
      generate: (endpoint, model, key, persona, text, history) => _model.reply(
        endpoint: endpoint,
        model: model,
        apiKey: key,
        persona: persona,
        text: text,
        history: history,
      ),
      closeModel: _model.close,
      list: (profile, after) {
        final connection = runtime.connection;
        if (connection == null) throw const FormatException('宿主未连接');
        return AndroidPrivateChatSyncApi(connection).list(profile, after);
      },
      push: (profile, id, user, assistant) {
        final connection = runtime.connection;
        if (connection == null) throw const FormatException('宿主未连接');
        return AndroidPrivateChatSyncApi(connection)
            .push(profile, exchangeId: id, user: user, assistant: assistant);
      },
    );
    unawaited(chat.initialize());
  }

  @override
  void dispose() {
    chat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AndroidPrivateAiScreen(chat: chat);
}

Future<PrivateAiProfile> _loadProfile(
  ClientRuntime runtime,
  ShellOwnedAi ai,
  String? owner,
  bool Function() isCurrent,
) async {
  final connection = runtime.connection;
  bool canRead() =>
      isCurrent() &&
      runtime.online &&
      identical(runtime.connection, connection);
  if (connection == null || owner == null || !canRead()) {
    throw const FormatException('宿主未连接');
  }
  final identity = await OwnerAiDirectApi(connection).registerOrResolve(
    ai.accountId,
    expectedOwnerAccountId: owner,
    retryAuthentication: false,
  );
  if (!canRead()) throw const FormatException('会话已变更');
  final readiness = OwnerAiReadinessApi(connection);
  final persona = await readiness.readPersona(
    identity,
    retryAuthentication: false,
  );
  if (!canRead()) throw const FormatException('会话已变更');
  final card = persona.value;
  if (card == null) {
    throw const FormatException('人格尚未配置');
  }
  final bindings = await readiness.readBindings(
    identity,
    retryAuthentication: false,
  );
  if (!canRead()) throw const FormatException('会话已变更');
  final chatBinding = bindings.value
      ?.where((row) => row.capability == 'chat')
      .firstOrNull;
  String? endpoint;
  if (chatBinding != null) {
    final provider = await readiness.readProvider(
      identity,
      chatBinding.providerId,
      retryAuthentication: false,
    );
    if (!canRead()) throw const FormatException('会话已变更');
    final candidate = _completionsUrl(provider.value?.baseUrl);
    if (candidate != null && provider.value?.enabled == true) {
      try {
        endpoint = AndroidPrivateModelApi.parseEndpoint(candidate).toString();
      } on FormatException {
        // A valid server base URL is not necessarily a supported phone endpoint.
      }
    }
  }
  final p0 = card.layers['p0']!;
  final p1 = card.layers['p1']!;
  final p2 = card.layers['p2']!;
  String line(String name, Map<String, String> layer) =>
      '$name：${layer.entries.map((entry) => '${entry.key}=${entry.value}').join('；')}';
  return (
    profileId: identity.profileId,
    personaName: p0['name'] ?? p0['称呼'] ?? ai.displayName,
    personaText: [
      line('P0 核心', p0),
      line('P1 风格', p1),
      line('P2 情绪', p2),
    ].join('\n'),
    personaVersion: card.version,
    model: chatBinding?.model,
    endpoint: endpoint,
  );
}

Future<String?> _loadBehavior(
  ClientRuntime runtime,
  String profile,
  bool Function() isCurrent,
) async {
  final connection = runtime.connection;
  bool canRead() =>
      isCurrent() &&
      runtime.online &&
      identical(runtime.connection, connection);
  if (connection == null || !canRead()) return null;
  final results = await Future.wait<Object>([
    OwnerSocialLevelApi(connection).read(profile),
    OwnerReplyPreferencesApi(connection).read(profile),
    OwnerRuleGreetingApi(connection).readSettings(profile),
    OwnerModelProactiveApi(connection).readSettings(profile),
  ]).timeout(const Duration(seconds: 5), onTimeout: () => const []);
  if (!canRead() || results.isEmpty) return null;
  final lines = <String>[];
  if (results[0] case OwnerSocialLevelSnapshot social) {
    lines.add('社交等级：${social.level?.wire ?? '未设置'}');
  }
  if (results[1] case OwnerReplyPreferenceResult(state: final state?)) {
    final length = switch (state.length) {
      OwnerReplyLength.brief => '简短',
      OwnerReplyLength.detailed => '详细',
      null => '默认长度',
    };
    final format = switch (state.format) {
      OwnerReplyFormat.paragraphs => '分段',
      OwnerReplyFormat.bullets => '列表',
      null => '默认排版',
    };
    lines.add('私聊回复偏好：${state.enabled ? '$length · $format' : '关闭'}');
  }
  if (results[2] case GreetingSettingsLoaded(:final state)) {
    lines.add(
      '规则问候：${state.globalBlocked
          ? '被账户级停止'
          : state.enabled
          ? '开启'
          : '关闭'}',
    );
  }
  if (results[3] case ProactiveSettingsLoaded(:final state)) {
    lines.add(
      '模型主动联系：${state.globalBlocked
          ? '被账户级停止'
          : state.enabled
          ? '开启'
          : '关闭'}',
    );
  }
  return lines.isEmpty ? null : lines.join('\n');
}

String? _completionsUrl(String? base) {
  if (base == null || base.trim().isEmpty) return null;
  final trimmed = base.trim().replaceAll(RegExp(r'/+$'), '');
  if (trimmed.endsWith('/chat/completions')) return trimmed;
  return '$trimmed/chat/completions';
}
