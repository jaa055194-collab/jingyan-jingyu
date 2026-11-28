import 'package:material_ui/material_ui.dart';

import '../../app/android_private_ai_chat_port.dart';

const _profileDisclosure = '需要连接宿主，未登记时会建立档案；不会开启宿主私聊授权。';
const _providerDisclosure =
    '发送时，手机会把当前输入、所选本人 AI 的人格、最近最多 5 轮本机私聊直接发往所填的模型服务，不含群聊或与他人的消息。'
    '宿主离线也能直连；本机不运行大模型，仍需网络访问模型服务。';
const _retentionDisclosure =
    '本机仅保留最近约 48 轮记录。待同步记录满时会暂停发送，直至你开启同步并完成上传；不会丢弃待同步记录。';
const _sessionExpired = '会话已失效';
const _sessionRecovery = '已隐藏私聊记录和输入，请返回后重新进入。';

String? _nonEmpty(String? value) =>
    value?.trim().isNotEmpty == true ? value : null;

String _personaLabel(AndroidPrivateAiChatPort chat) {
  if (_nonEmpty(chat.personaText) == null) return '未加载';
  final name = _nonEmpty(chat.personaName) ?? '未命名';
  final version = chat.personaVersion;
  return version == null ? name : '$name · 版本 $version';
}

String _syncSummary(
  AndroidPrivateAiChatPort chat,
  List<PrivateAiExchange> exchanges,
) {
  final synced = exchanges.where((turn) => turn.seq != null).length;
  return '同步${chat.syncEnabled ? '已开启' : '已关闭'}'
      ' · 已同步 $synced 轮 · 仅本机 ${exchanges.length - synced} 轮';
}

/// Presentation only. The Android route owns initialization and disposal of
/// [chat]. No host/model requests are made merely by opening this screen.
class AndroidPrivateAiScreen extends StatelessWidget {
  const AndroidPrivateAiScreen({super.key, required this.chat});

  final AndroidPrivateAiChatPort chat;

  @override
  Widget build(BuildContext context) =>
      _PrivateAiSession(key: ObjectKey(chat), chat: chat);
}

enum _ChatMenu { welcome, model, persona, sync }

class _PrivateAiSession extends StatefulWidget {
  const _PrivateAiSession({super.key, required this.chat});

  final AndroidPrivateAiChatPort chat;

  @override
  State<_PrivateAiSession> createState() => _PrivateAiSessionState();
}

class _PrivateAiSessionState extends State<_PrivateAiSession> {
  final _draft = TextEditingController();
  final _history = ScrollController();
  var _invalidated = false;
  var _running = false;
  String? _localNotice;
  DialogRoute<void>? _dialog;

  AndroidPrivateAiChatPort get _chat => widget.chat;
  bool get _current => mounted && !_invalidated && _chat.isCurrent;
  bool get _working => _running || _chat.busy;
  bool get _canReadProfile =>
      _current && _chat.initialized && _chat.online && !_working;
  bool get _canSend => _current && _blockReason == null;

  bool get _pendingAtLimit =>
      _chat.exchanges.where((turn) => turn.seq == null).length >= 48;

  String? get _blockReason {
    if (_working) return '正在处理，请稍候';
    if (!_chat.initialized) return '本机私聊数据尚未读取';
    if (_pendingAtLimit) return '本机待同步记录已满（约 48 轮），请先开启同步并同步';
    if (_nonEmpty(_chat.personaText) == null) return '请先读取本人 AI 的人格';
    if (_nonEmpty(_chat.endpoint) == null ||
        _nonEmpty(_chat.model) == null ||
        !_chat.keyConfigured) {
      return '请先设置模型、地址与本机密钥';
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _invalidated = !_chat.isCurrent;
    _chat.addListener(_chatChanged);
  }

  void _chatChanged() {
    if (!_chat.isCurrent && !_invalidated) {
      _invalidated = true;
      _draft.clear();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _chat.removeListener(_chatChanged);
    _draft.dispose();
    _history.dispose();
    final dialog = _dialog;
    if (dialog != null) {
      // The route is pinned to this exact port even if a parent swaps ports.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (dialog.isActive) dialog.navigator?.removeRoute(dialog);
      });
    }
    super.dispose();
  }

  Future<void> _run(
    Future<bool> Function() action, {
    required String fallback,
    String? unsent,
  }) async {
    setState(() {
      _running = true;
      _localNotice = null;
    });
    var accepted = false;
    try {
      accepted = await action();
    } catch (_) {
      // The port normally returns a sanitized notice. Never expose exception
      // payloads in a screen that handles credentials and private text.
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      if (_current && !accepted && _chat.notice == null) {
        _localNotice = fallback;
      }
    });
    if (unsent == null || !_current) return;
    if (!accepted) {
      // A send that did not complete puts its text back, unless something
      // new was typed meanwhile.
      if (_draft.text.isEmpty) {
        _draft.value = TextEditingValue(
          text: unsent,
          selection: TextSelection.collapsed(offset: unsent.length),
        );
      }
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current && _history.hasClients) {
        _history.jumpTo(_history.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final unsent = _draft.text;
    final text = unsent.trim();
    if (!_canSend ||
        text.isEmpty ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    // Empty the draft as the send starts, so nothing typed later can extend
    // the text being sent.
    _draft.clear();
    await _run(
      () => _chat.send(text),
      fallback: '未完成发送，草稿仍在。请检查模型服务的网络后重试。',
      unsent: unsent,
    );
  }

  Future<void> _readProfile() async {
    if (!_canReadProfile) return;
    await _run(_chat.loadHostProfile, fallback: '档案未读取，请检查宿主连接后重试。');
  }

  Future<void> _select(_ChatMenu item) async {
    if (!_current ||
        _dialog != null ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    if ((item == _ChatMenu.model || item == _ChatMenu.sync) &&
        (!_chat.initialized || _working)) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ListenableBuilder(
        listenable: _chat,
        builder: (context, _) {
          if (!_current) {
            return AlertDialog(
              scrollable: true,
              title: const Text(_sessionExpired),
              content: const Text(_sessionRecovery),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('关闭'),
                ),
              ],
            );
          }
          return switch (item) {
            _ChatMenu.welcome => _welcomeDialog(context),
            _ChatMenu.model => _ModelSettings(
              chat: _chat,
              isCurrent: () => _current,
            ),
            _ChatMenu.persona => _personaDialog(context),
            _ChatMenu.sync => _SyncSettings(
              chat: _chat,
              isCurrent: () => _current,
            ),
          };
        },
      ),
    );
    _dialog = route;
    try {
      await Navigator.of(context).push(route);
    } finally {
      if (identical(_dialog, route)) _dialog = null;
    }
  }

  Widget _welcomeDialog(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('欢迎使用私聊我的 AI'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('这是 Android 专属的本人 AI 私聊：只与你自己已登记的 AI 对话，不进入群聊，也不会发给其他人。'),
          const SizedBox(height: 8),
          const Text('模型请求由手机直接发往你填写的模型服务；本机不运行大模型，需要网络访问该服务。宿主离线时仍可发送。'),
          const SizedBox(height: 8),
          const Text('API 密钥只在本机加密保存。默认只在本机保留最近约 48 轮；开启同步后仅同步对话记录，不含密钥。'),
          const SizedBox(height: 8),
          const Text(_profileDisclosure),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    );
  }

  Widget _personaDialog(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('当前人格'),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '人格：${_personaLabel(_chat)}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Text(_nonEmpty(_chat.personaText) ?? '还没有可用于私聊的人格。'),
          if (_chat.behaviorSnapshot case final String snapshot) ...[
            const SizedBox(height: 16),
            Text(
              '宿主活人感设置 · 上次读取',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(snapshot),
            const Text('本机直连不运行宿主的问候或主动联系。'),
          ],
          const SizedBox(height: 16),
          const Text('修改人格或活人感设置，请返回“我的 AI”并连接宿主。'),
          const SizedBox(height: 8),
          const Text(_profileDisclosure),
          if (!_chat.online) const Text('宿主离线，暂时无法读取。'),
          if (_chat.notice case final String notice) _Notice(notice),
          TextButton.icon(
            key: const Key('private-ai-refresh-profile'),
            onPressed: _canReadProfile ? _readProfile : null,
            icon: const Icon(Icons.refresh),
            label: const Text('读取宿主档案'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final showPrivate = _current;
    final title = AppBar(
      title: const Text(
        '私聊我的 AI',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        if (showPrivate)
          PopupMenuButton<_ChatMenu>(
            key: const Key('private-ai-menu'),
            tooltip: '私聊设置',
            onSelected: _select,
            itemBuilder: (context) => [
              const PopupMenuItem(
                key: Key('private-ai-welcome'),
                value: _ChatMenu.welcome,
                child: Text('欢迎与说明'),
              ),
              PopupMenuItem(
                key: const Key('private-ai-model-settings'),
                value: _ChatMenu.model,
                enabled: _chat.initialized && !_working,
                child: const Text('模型设置'),
              ),
              const PopupMenuItem(
                key: Key('private-ai-persona'),
                value: _ChatMenu.persona,
                child: Text('查看人格'),
              ),
              PopupMenuItem(
                key: const Key('private-ai-sync-settings'),
                value: _ChatMenu.sync,
                enabled: _chat.initialized && !_working,
                child: const Text('会话同步'),
              ),
            ],
          ),
      ],
    );
    if (!showPrivate) {
      return Scaffold(
        appBar: title,
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '$_sessionExpired。$_sessionRecovery',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final exchanges = _chat.exchanges;
    final pending = exchanges.where((turn) => turn.seq == null).length;
    final notice = _chat.notice ?? _localNotice;
    final theme = Theme.of(context);
    final name = _nonEmpty(_chat.aiName) ?? '我的 AI';
    final model = _nonEmpty(_chat.model) ?? '未配置';
    final persona = _personaLabel(_chat);
    final reason = _blockReason;
    return Scaffold(
      appBar: title,
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxHeight < 300;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ColoredBox(
                      color: theme.colorScheme.surfaceContainerLow,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        // Stacked so each value gets the full width and can
                        // wrap on a narrow screen or with large text.
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _SummaryText(
                              '模型：$model',
                              maxLines: compact ? 1 : 2,
                            ),
                            const SizedBox(height: 2),
                            _SummaryText(
                              '人格：$persona',
                              maxLines: compact ? 1 : 2,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_working)
                      const LinearProgressIndicator(semanticsLabel: '正在处理私聊请求'),
                    Expanded(
                      child: ListView(
                        controller: _history,
                        padding: const EdgeInsets.all(16),
                        children: [
                          Text(name, style: theme.textTheme.titleMedium),
                          const SizedBox(height: 4),
                          Text(
                            '${_chat.online ? '宿主在线' : '宿主离线'} · '
                            '${_chat.keyConfigured ? '已保存本机密钥' : '未保存本机密钥'}',
                            style: theme.textTheme.bodySmall,
                          ),
                          Text(
                            _syncSummary(_chat, exchanges),
                            style: theme.textTheme.bodySmall,
                          ),
                          if (pending > 0)
                            Text(
                              '本机待同步 $pending 轮（上限约 48）；达到上限后会暂停发送，不会丢失记录。',
                              style: theme.textTheme.bodySmall,
                            ),
                          if (exchanges.isEmpty ||
                              reason != null && !_working) ...[
                            const SizedBox(height: 16),
                            Text(
                              reason ?? '还没有私聊记录',
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            const Text(_providerDisclosure),
                            if (_chat.initialized &&
                                _nonEmpty(_chat.personaText) == null) ...[
                              const SizedBox(height: 8),
                              const Text(_profileDisclosure),
                              if (!_chat.online) const Text('宿主离线，暂时无法读取。'),
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: OutlinedButton.icon(
                                  key: const Key('private-ai-load-profile'),
                                  onPressed: _canReadProfile
                                      ? _readProfile
                                      : null,
                                  icon: const Icon(Icons.sync),
                                  label: const Text('读取宿主档案'),
                                ),
                              ),
                            ] else if (_chat.initialized &&
                                !_chat.keyConfigured) ...[
                              const SizedBox(height: 8),
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: FilledButton(
                                  onPressed: _working
                                      ? null
                                      : () => _select(_ChatMenu.model),
                                  child: const Text('设置模型与密钥'),
                                ),
                              ),
                            ],
                          ],
                          if (exchanges.isNotEmpty) const SizedBox(height: 16),
                          for (final turn in exchanges)
                            _ExchangeView(aiName: name, turn: turn),
                        ],
                      ),
                    ),
                    if (notice != null && notice.isNotEmpty)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: compact ? 44 : 96,
                        ),
                        child: SingleChildScrollView(
                          child: _Notice(
                            notice,
                            isError:
                                _chat.notice == null && _localNotice != null,
                          ),
                        ),
                      ),
                    // A Material rather than a plain box, so the hint's ink
                    // response is painted on this surface instead of under it.
                    Material(
                      color: theme.colorScheme.surfaceContainerLow,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _ComposerHint(
                              reason ?? '直连模型服务 · 不在本机运行大模型',
                              maxLines: compact ? 1 : 2,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: TextField(
                                    key: const Key('private-ai-draft'),
                                    controller: _draft,
                                    enabled: _chat.initialized && !_working,
                                    minLines: 1,
                                    maxLines: compact ? 2 : 4,
                                    decoration: const InputDecoration(
                                      labelText: '输入私聊消息',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ValueListenableBuilder<TextEditingValue>(
                                  valueListenable: _draft,
                                  builder: (context, value, _) =>
                                      IconButton.filled(
                                        key: const Key('private-ai-send'),
                                        tooltip: '发送给模型',
                                        icon: const Icon(Icons.send_outlined),
                                        onPressed:
                                            _canSend &&
                                                value.text.trim().isNotEmpty
                                            ? _send
                                            : null,
                                      ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryText extends StatelessWidget {
  const _SummaryText(this.value, {this.maxLines = 2});

  final String value;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Text(
    value,
    style: Theme.of(context).textTheme.labelLarge,
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
  );
}

/// The line above the composer. A long reason for a disabled send expands in
/// place instead of staying cut off on a narrow screen or with large text.
class _ComposerHint extends StatefulWidget {
  const _ComposerHint(this.text, {required this.maxLines});

  final String text;
  final int maxLines;

  @override
  State<_ComposerHint> createState() => _ComposerHintState();
}

class _ComposerHintState extends State<_ComposerHint> {
  var _expanded = false;

  @override
  void didUpdateWidget(_ComposerHint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: widget.maxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final truncated = painter.didExceedMaxLines;
        painter.dispose();
        final text = Text(
          widget.text,
          key: const Key('private-ai-composer-hint'),
          style: style,
          maxLines: _expanded ? null : widget.maxLines,
          overflow: _expanded ? null : TextOverflow.ellipsis,
        );
        if (!truncated && !_expanded) return text;
        return Semantics(
          button: true,
          expanded: _expanded,
          child: InkWell(
            key: const Key('private-ai-composer-hint-toggle'),
            onTap: () => setState(() => _expanded = !_expanded),
            // A full-size touch target, even for one short line of text.
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: kMinInteractiveDimension,
              ),
              child: Row(
                children: [
                  Expanded(child: text),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    semanticLabel: _expanded ? '收起' : '展开全文',
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ExchangeView extends StatelessWidget {
  const _ExchangeView({required this.aiName, required this.turn});

  final String aiName;
  final PrivateAiExchange turn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _bubble(context, '你', turn.user, sent: true),
          const SizedBox(height: 8),
          _bubble(context, aiName, turn.assistant, sent: false),
          const SizedBox(height: 4),
          Text(
            turn.seq == null ? '待同步（仅本机）' : '已同步 #${turn.seq}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(
    BuildContext context,
    String speaker,
    String text, {
    required bool sent,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Align(
      alignment: sent
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: Container(
        margin: EdgeInsetsDirectional.only(
          start: sent ? 32 : 0,
          end: sent ? 0 : 32,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: sent ? colors.primaryContainer : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              speaker,
              style: theme.textTheme.labelMedium?.copyWith(
                color: sent
                    ? colors.onPrimaryContainer
                    : colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: sent ? colors.onPrimaryContainer : colors.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.message, {this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      child: ColoredBox(
        color: isError ? colors.errorContainer : colors.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: isError
                  ? colors.onErrorContainer
                  : colors.onSecondaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}

class _ModelSettings extends StatefulWidget {
  const _ModelSettings({required this.chat, required this.isCurrent});

  final AndroidPrivateAiChatPort chat;
  final bool Function() isCurrent;

  @override
  State<_ModelSettings> createState() => _ModelSettingsState();
}

class _ModelSettingsState extends State<_ModelSettings> {
  late final _url = TextEditingController(text: widget.chat.endpoint ?? '');
  late final _model = TextEditingController(text: widget.chat.model ?? '');
  final _key = TextEditingController();
  var _saving = false;
  String? _urlError, _modelError, _error;

  bool get _editable =>
      widget.isCurrent() &&
      widget.chat.initialized &&
      !widget.chat.busy &&
      !_saving;

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_editable || ModalRoute.of(context)?.isCurrent == false) return;
    final endpoint = _url.text.trim();
    final model = _model.text.trim();
    final key = _key.text;
    final uri = Uri.tryParse(endpoint);
    final validUrl =
        uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        !uri.authority.contains('@') &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        uri.path.endsWith('/chat/completions') &&
        !RegExp(r'\s').hasMatch(endpoint);
    setState(() {
      _error = null;
      _urlError = validUrl
          ? null
          : '请填以 /chat/completions 结尾的完整 HTTPS 地址。不能含账号、查询参数或片段。';
      _modelError = model.isNotEmpty ? null : '请输入模型名称。';
      _saving = validUrl && model.isNotEmpty;
    });
    if (!_saving) return;
    var saved = false;
    try {
      // Only the control layer knows whether a saved key belongs to this URL.
      saved = await widget.chat.configure(
        endpoint: endpoint,
        model: model,
        apiKey: key.isEmpty ? null : key,
      );
    } catch (_) {
      // Do not expose exception details or the credential in error text.
    }
    if (!mounted || !widget.isCurrent()) return;
    if (saved && ModalRoute.of(context)?.isCurrent != false) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _saving = false;
      _error = widget.chat.notice ?? '未保存模型设置，请检查后重试。';
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      scrollable: true,
      title: const Text('模型设置'),
      content: SizedBox(
        width: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(_providerDisclosure),
            const SizedBox(height: 16),
            TextField(
              key: const Key('private-ai-endpoint'),
              controller: _url,
              enabled: _editable,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'HTTPS 对话接口地址',
                hintText: 'https://示例/v1/chat/completions',
                helperText: '完整地址，以 /chat/completions 结尾',
                helperMaxLines: 3,
                errorText: _urlError,
                errorMaxLines: 4,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('private-ai-model'),
              controller: _model,
              enabled: _editable,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: '模型名称',
                errorText: _modelError,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('private-ai-api-key'),
              controller: _key,
              enabled: _editable,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              enableIMEPersonalizedLearning: false,
              autofillHints: null,
              keyboardType: TextInputType.visiblePassword,
              decoration: const InputDecoration(
                labelText: 'API 密钥',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.chat.keyConfigured
                  ? '密钥已加密保存在本机。地址不变时留空可沿用，更换地址须重新输入。'
                  : '请在手机上输入密钥，只在本机加密保存；不沿用宿主密钥，也不上传到宿主。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error case final String error) ...[
              const SizedBox(height: 8),
              _Notice(error, isError: true),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('private-ai-configure'),
          onPressed: _editable ? _save : null,
          child: Text(_saving ? '正在保存…' : '确认并保存'),
        ),
      ],
    ),
  );
}

class _SyncSettings extends StatefulWidget {
  const _SyncSettings({required this.chat, required this.isCurrent});

  final AndroidPrivateAiChatPort chat;
  final bool Function() isCurrent;

  @override
  State<_SyncSettings> createState() => _SyncSettingsState();
}

class _SyncSettingsState extends State<_SyncSettings> {
  var _working = false;
  String? _error;

  AndroidPrivateAiChatPort get _chat => widget.chat;
  bool get _editable =>
      widget.isCurrent() && _chat.initialized && !_chat.busy && !_working;
  bool get _canSync => _editable && _chat.online && _chat.syncEnabled;

  Future<void> _run(Future<void> Function() action) async {
    if (!_editable) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted && widget.isCurrent()) _error = '同步操作未完成，请重试。';
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    title: const Text('会话同步'),
    content: SizedBox(
      width: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('默认关闭。开启后，只同步这段私聊的往返记录到宿主，不上传 API 密钥或模型设置。'),
          const SizedBox(height: 8),
          const Text(
            '打开此聊天页时，手动同步、成功发送后或宿主恢复连接时会上传和拉取。同一账号下同一个 AI 的已同步记录可在另一台 Android 恢复。',
          ),
          const SizedBox(height: 8),
          const Text(_retentionDisclosure),
          const SizedBox(height: 8),
          SwitchListTile(
            key: const Key('private-ai-sync-switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('同步私聊记录'),
            value: _chat.syncEnabled,
            onChanged: _editable
                ? (enabled) => _run(() => _chat.setSyncEnabled(enabled))
                : null,
          ),
          Text(_syncSummary(_chat, _chat.exchanges)),
          if (!_chat.online) const Text('宿主离线，暂时无法同步。'),
          if (_chat.notice case final String notice) ...[
            const SizedBox(height: 8),
            _Notice(notice),
          ] else if (_error case final String error) ...[
            const SizedBox(height: 8),
            _Notice(error, isError: true),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
      FilledButton(
        key: const Key('private-ai-sync-now'),
        onPressed: _canSync
            ? () {
                if (_canSync) _run(_chat.sync);
              }
            : null,
        child: const Text('立即同步'),
      ),
    ],
  );
}
