import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../data/file_persistence.dart';
import '../data/account_snapshots.dart';
import '../attachments/attachment_content.dart';
import '../net/account_auth.dart';
import '../net/attachment_api.dart';
import '../net/attachment_send_flow.dart';
import '../net/attachment_upload_api.dart';
import '../net/host_connection.dart';
import '../net/group_api.dart';
import '../net/own_ai_api.dart';
import '../net/owner_ai_direct_api.dart';
import '../platform/native_platform.dart';
import 'conversation_mapping.dart';
import 'shell_view_model.dart';

class ClientRuntime extends ShellViewModel with WidgetsBindingObserver {
  final native = NativePlatform();
  final authenticator = AccountAuthenticator();
  late Directory _dataRoot;
  late FilePersistence _settingsStorage;
  Future<void>? _refreshWork;
  // A completed refresh also supersedes visibility seen by an earlier shortcut.
  int _refreshGeneration = 0;
  int _historySyncEpoch = 0;
  int _attachmentSelectionRevision = 0;
  _AttachmentDraft? _attachmentDraft;
  Future<bool>? _renewWork;
  Future<void> _secureTail = Future<void>.value();
  ClientCredentials? _credentials;
  ({int generation, ClientCredentials source, ClientCredentials rotated})?
  _pendingRenewal;
  int _generation = 0;
  bool _disposed = false;
  bool _switching = false;
  bool _earlyLockRequested = false;
  bool _earlyLogoutRequested = false;
  bool _initialSessionRestore = true;
  ShellIncomingShare? _sharedText;
  String? _shareNotice;
  Object _shareEpoch = Object();
  _ShareInteractionContext? _shareContext;
  late FilePersistence storage;
  late ClientShellController shell;
  late AppLockController appLock;
  late ConversationConsentController consent;
  PluginHost? plugins;
  HostConnection? connection;
  Timer? reconnect;
  Map<String, Object?> preferences = {};
  List<ShellConversation> _conversations = [];
  List<ShellOwnedAi> _ownAiAccounts = [];
  String? _ownAiNotice;
  bool _ownAiLoaded = false;
  final _ownAiDirect = <String, ShellOwnAiDirectState>{};
  Object _ownAiDirectEpoch = Object();

  void _invalidateOwnAiDirect() {
    _ownAiDirectEpoch = Object();
    _ownAiDirect.clear();
  }

  @override
  Object? get ownAiDirectContext =>
      authenticated && !locked && !_switching && !_disposed
      ? _ownAiDirectEpoch
      : null;
  @override
  ShellOwnAiDirectState ownAiDirectState(String aiAccountId) =>
      !authenticated || locked || _switching || _disposed
      ? const ShellOwnAiDirectState()
      : _ownAiDirect[aiAccountId] ?? const ShellOwnAiDirectState();

  @override
  Object? get ownAiSessionContext => authenticated ? _generation : null;
  @override
  bool get ownAiLoaded => _ownAiLoaded;
  @override
  List<ShellOwnedAi> get ownAiAccounts => List.unmodifiable(_ownAiAccounts);
  @override
  String? get ownAiNotice => _ownAiNotice;
  bool _ready = false, _busy = false, _online = false, _onboarded = false;
  bool _chatEntered = false;
  bool _sessionRejected = false;
  bool _controllersReady = false;
  String? _error, _selected, _preview;
  String _draft = '';
  final _draftRevisions = <String, int>{};
  ({
    ClientShellController shell,
    int generation,
    String group,
    String text,
    String target,
    String id,
  })?
  _pendingMention;
  @override
  bool get ready => _ready;
  @override
  bool get busy => _busy;
  @override
  bool get onboarded => _onboarded && !_sessionRejected;
  @override
  bool get chatEntered => _chatEntered;
  @override
  String? get connectedAccountId =>
      _sessionRejected ? null : _credentials?.accountId;
  @override
  bool get locked => _controllersReady && appLock.isLocked;
  @override
  bool get online => _online;
  @override
  String? get error => _error;

  bool get _shareIntakeOpen =>
      !_disposed &&
      !_switching &&
      !_sessionRejected &&
      !_earlyLogoutRequested &&
      (_initialSessionRestore || authenticated);

  ShellIncomingShare? get _sharedTextView => _sharedText;

  bool get _canShowSharedText =>
      _controllersReady &&
      authenticated &&
      !_sessionRejected &&
      !locked &&
      !_switching &&
      !_disposed;

  @override
  ShellIncomingShare? get incomingSharedText =>
      _canShowSharedText ? _sharedTextView : null;

  @override
  String? get incomingShareNotice => _canShowSharedText ? _shareNotice : null;

  @override
  Object? get shareInteractionContext {
    if (!_canShowSharedText || _sharedText == null) return null;
    final context = _shareContext;
    if (context != null &&
        identical(context.epoch, _shareEpoch) &&
        identical(context.credentials, _credentials) &&
        identical(context.share, _sharedText)) {
      return context;
    }
    final next = _ShareInteractionContext(
      _shareEpoch,
      _credentials,
      _sharedText!,
    );
    _shareContext = next;
    return next;
  }

  void _invalidateSharedTextContext({bool discard = false}) {
    _shareEpoch = Object();
    _shareContext = null;
    if (discard) {
      _sharedText = null;
      _shareNotice = null;
    }
  }

  void _registerNativeHandler() {
    NativePlatform.channel.setMethodCallHandler((call) async {
      if (_disposed) return;
      if (call.method == 'event') {
        final type = (call.arguments as Map?)?['type'];
        if (type == 'lock') {
          _invalidateSharedTextContext();
          if (!_controllersReady) {
            _earlyLockRequested = true;
          } else {
            appLock.lock();
            notifyListeners();
          }
        } else if (type == 'logout') {
          _invalidateSharedTextContext(discard: true);
          if (_initialSessionRestore) {
            _earlyLogoutRequested = true;
            return;
          }
          await _logout();
        }
      } else if (call.method == 'shareReceived') {
        _acceptSharePayload(call.arguments);
      }
    });
  }

  void _acceptSharePayload(Object? raw) {
    if (!_shareIntakeOpen) return;
    if (_sharedText != null) {
      _shareNotice = '已有分享待处理';
      if (_canShowSharedText) notifyListeners();
      return;
    }
    if (raw is! Map ||
        !raw.containsKey('text') ||
        raw['text'] is! String ||
        (raw['text'] as String).trim().isEmpty ||
        (raw['mimeType'] != null && raw['mimeType'] != 'text/plain') ||
        (raw['uris'] != null &&
            (raw['uris'] is! List || (raw['uris'] as List).isNotEmpty))) {
      _shareNotice = '无法使用此分享内容';
      if (_canShowSharedText) notifyListeners();
      return;
    }
    final text = raw['text'] as String;
    if (utf8.encode(text).length > 64 * 1024) {
      _shareNotice = '分享内容过长，无法暂存';
      if (_canShowSharedText) notifyListeners();
      return;
    }
    _sharedText = ShellIncomingShare(text: text);
    _shareNotice = null;
    _invalidateSharedTextContext();
    if (_canShowSharedText) notifyListeners();
  }

  @override
  Future<void> discardSharedText() async {
    _invalidateSharedTextContext(discard: true);
    notifyListeners();
  }

  @override
  Future<bool> useSharedTextInDraft(
    String conversationId, {
    required Object interactionContext,
  }) async {
    final pending = _sharedText;
    if (!_canShowSharedText ||
        _busy ||
        pending == null ||
        !identical(interactionContext, shareInteractionContext)) {
      return false;
    }
    final sessionShell = shell;
    final generation = _generation;
    final selected = _selected;
    final targetRevision = _draftRevisions[conversationId] ?? 0;
    var saved = false;
    void checkActive() {
      if (!_canShowSharedText ||
          !_current(generation) ||
          !identical(shell, sessionShell) ||
          !identical(_sharedText, pending) ||
          !identical(interactionContext, shareInteractionContext) ||
          _selected != selected ||
          (_draftRevisions[conversationId] ?? 0) != targetRevision ||
          !_conversations.any(
            (conversation) => conversation.id == conversationId,
          )) {
        throw const _SharedTextInterrupted();
      }
      if (sessionShell.draftFor(conversationId).isNotEmpty ||
          (_selected == conversationId && _draft.isNotEmpty)) {
        throw const _SharedTextInterrupted();
      }
    }

    try {
      checkActive();
      _busy = true;
      notifyListeners();
      await sessionShell.saveDraft(
        conversationId,
        pending.text,
        checkActive: checkActive,
      );
      saved = true;
      final canPublish =
          _canShowSharedText &&
          _current(generation) &&
          identical(shell, sessionShell) &&
          identical(interactionContext, shareInteractionContext) &&
          _selected == selected &&
          (_draftRevisions[conversationId] ?? 0) == targetRevision &&
          _conversations.any(
            (conversation) => conversation.id == conversationId,
          );
      if (identical(_sharedText, pending)) {
        _invalidateSharedTextContext(discard: true);
      }
      if (!canPublish) return false;
      _selected = conversationId;
      _draft = pending.text;
      _draftRevisions[conversationId] = targetRevision + 1;
      unawaited(_clearAttachmentSelection());
      return true;
    } on _SharedTextInterrupted {
      return false;
    } catch (_) {
      if (_current(generation) && !saved) _shareNotice = '分享草稿保存失败';
      return false;
    } finally {
      if (_current(generation)) _busy = false;
      notifyListeners();
    }
  }

  @override
  String? get selectedConversationId => _selected;

  @override
  String draftFor(String conversationId) {
    if (_selected == conversationId) return _draft;
    return _controllersReady ? shell.draftFor(conversationId) : '';
  }

  @override
  List<ShellConversation> get conversations => !_controllersReady
      ? _conversations
      : [
          for (final conversation in _conversations)
            ShellConversation(
              id: conversation.id,
              title: conversation.title,
              preview: conversation.preview,
              unread: _unreadFor(conversation.id),
              kind: conversation.kind,
              ownerAccountId: conversation.ownerAccountId,
            ),
        ];

  /// The cache is already pruned to the visible history floor, so every cached
  /// canonical row above the read position is genuinely unread. The user's own
  /// messages never badge, and outbox/dropped rows are not canonical messages.
  int _unreadFor(String conversationId) {
    final read = shell.readSeqFor(conversationId);
    final self = connectedAccountId;
    var count = 0;
    for (final message in shell.messagesFor(conversationId)) {
      if (message.seq > read && message.senderId != self) count++;
    }
    return count;
  }

  @override
  List<ShellMessage> get messages => _selected == null
      ? []
      : [
          for (final message in shell.messagesFor(_selected!))
            ShellMessage(
              id: message.messageId,
              text: _messageLabel(message.kind, message.body),
              attachmentId: message.body['attachmentId'] is String
                  ? message.body['attachmentId'] as String
                  : null,
              attachmentName: _attachmentName(message.kind, message.body),
              imageAttachment:
                  message.kind == MessageKind.image &&
                  message.body['attachmentId'] is String &&
                  message.body['recalled'] != true,
            ),
          for (final item in shell.outbox.items.where(
            (e) => e.conversationId == _selected,
          ))
            ShellMessage(
              id: item.clientMsgId,
              text: _messageLabel(item.kind, item.body),
              outgoing: true,
              status: '等待补传',
            ),
          for (final drop in shell.dropped.where(
            (e) => e.item.conversationId == _selected,
          ))
            ShellMessage(
              id: drop.item.clientMsgId,
              text: _messageLabel(drop.item.kind, drop.item.body, fallback: ''),
              outgoing: true,
              status: '发送失败',
            ),
        ];
  static String? _attachmentName(MessageKind kind, Map<String, Object?> body) {
    if (kind != MessageKind.image && kind != MessageKind.file) return null;
    if (body['attachmentId'] is! String) return null;
    final name = body['name'];
    return name is String ? FileAttachmentContent.safeDisplayName(name) : null;
  }

  static String _messageLabel(
    MessageKind kind,
    Map<String, Object?> body, {
    String? fallback,
  }) {
    final text = body['text'];
    if (text != null) return text.toString();
    final name = body['name'];
    if ((kind == MessageKind.image || kind == MessageKind.file) &&
        body['attachmentId'] is String &&
        name is String) {
      return FileAttachmentContent.safeDisplayName(name);
    }
    return fallback ?? '[${kind.wire}]';
  }

  @override
  Future<MessageImage?> openImageAttachment(String messageId) async {
    final conversationId = _selected;
    final sessionConnection = connection;
    final sessionShell = shell;
    if (conversationId == null ||
        sessionConnection == null ||
        _busy ||
        !authenticated ||
        locked ||
        _switching ||
        _sessionRejected ||
        !_online) {
      return null;
    }
    final generation = _generation;
    final epoch = _historySyncEpoch;
    bool current() =>
        _current(generation) &&
        generation == _generation &&
        epoch == _historySyncEpoch &&
        _selected == conversationId &&
        identical(connection, sessionConnection) &&
        identical(shell, sessionShell) &&
        authenticated &&
        !locked &&
        !_switching &&
        !_sessionRejected &&
        _online;
    final visible = sessionShell
        .messagesFor(conversationId)
        .any(
          (message) =>
              message.messageId == messageId &&
              message.kind == MessageKind.image &&
              message.body['attachmentId'] is String &&
              message.body['recalled'] != true,
        );
    if (!visible || !current()) return null;
    try {
      final image = await AttachmentApi(
        sessionConnection,
      ).readMessageImage(conversationId: conversationId, messageId: messageId);
      // A lock, switch or reconnect while the bytes were in flight discards
      // them instead of publishing a stale plaintext image.
      return current() ? image : null;
    } catch (_) {
      return null;
    }
  }

  @override
  int get queuedCount => _controllersReady ? shell.outbox.items.length : 0;
  @override
  String get draft => _draft;
  @override
  bool get aiConsentGranted =>
      _selected != null &&
      !consent.requiresConsent(_selected!, MessageKind.image, isAi: true);
  @override
  bool get appLockEnabled => _controllersReady && appLock.enabled;
  @override
  bool get hideNotificationBody =>
      _controllersReady && appLock.hideNotificationBody;
  @override
  bool get autoStart => preferences['autoStart'] == true;
  @override
  ThemeMode get themeMode =>
      ThemeMode.values
          .where((e) => e.name == preferences['theme'])
          .firstOrNull ??
      ThemeMode.system;
  @override
  double get fontScale => (preferences['fontScale'] as num? ?? 1).toDouble();
  @override
  String? get roomPreview => _preview;
  Future<void> initialize() async {
    final generation = _generation;
    WidgetsBinding.instance.addObserver(this);
    _registerNativeHandler();
    try {
      final nativeState = await native.invoke<Object?>('initialize');
      if (nativeState is Map && nativeState['pendingShare'] != null) {
        _acceptSharePayload(nativeState['pendingShare']);
      }
      if (!_current(generation)) return;
      final directory = await native.invoke<String>('getDataDirectory');
      if (directory == null) throw const FileSystemException('本地目录不可用');
      _dataRoot = Directory(directory);
      // App lock and presentation preferences are device-wide. Message state
      // and consent are isolated per authenticated host/account/device.
      _settingsStorage = FilePersistence(File('$directory/settings.json'));
      await _migrateSettings();
      if (!_current(generation)) return;
      preferences =
          (await _settingsStorage.read())['preferences']
              as Map<String, Object?>? ??
          {};
      appLock = _OwnAiEpochAppLock(
        persistence: _settingsStorage,
        auth: native,
        invalidate: () {
          _invalidateOwnAiDirect();
          _invalidateSharedTextContext();
          if (appLock.enabled) _historySyncEpoch++;
        },
      );
      await appLock.initialize();
      final guest = await _prepareSnapshot(
        FilePersistence(File('$directory/guest.json')),
        null,
        generation,
      );
      if (!_current(generation)) return;
      _publishSnapshot(guest);
      final saved = _earlyLogoutRequested
          ? null
          : await native.invoke<String>('readSession');
      if (_earlyLogoutRequested) {
        await native.invoke<void>('clearSession');
      }
      if (saved != null && !_earlyLogoutRequested) {
        try {
          final decoded = jsonDecode(saved);
          if (decoded is! Map<String, dynamic>) throw const FormatException();
          final credentials = ClientCredentials.fromJson(decoded);
          final snapshot = await AccountSnapshots(
            _dataRoot,
          ).open(credentials.host, credentials.accountId, credentials.deviceId);
          final prepared = await _prepareSnapshot(
            snapshot,
            credentials,
            generation,
          );
          if (!_current(generation)) {
            await prepared.transport?.close();
            return;
          }
          if (_earlyLogoutRequested) {
            await prepared.transport?.close();
            await native.invoke<void>('clearSession');
          } else {
            _credentials = credentials;
            _publishSnapshot(prepared);
            connection = _newConnection(credentials, generation);
            _onboarded = decoded['onboarded'] == true;
            _chatEntered = _chatEntered || _onboarded;
          }
        } on FormatException {
          // Old unscoped credentials are not paired with private legacy data.
          _error = '旧登录记录缺少账号或设备身份，请重新登录；本地旧数据保持不变';
        }
      }
      if (!_current(generation)) return;
      _initialSessionRestore = false;
      _earlyLogoutRequested = false;
      if (!authenticated) _invalidateSharedTextContext(discard: true);
      if (_earlyLockRequested) appLock.lock();
      _ready = true;
      if (connection != null && !locked) unawaited(_refresh());
      reconnect = Timer.periodic(const Duration(seconds: 15), (_) {
        if (!locked && connection != null && !_busy) unawaited(_refresh());
      });
    } catch (_) {
      _error = '启动失败：无法读取本地设置或登录记录，请检查存储后重试';
      _ready = true;
    }
    notifyListeners();
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  Future<void> _migrateSettings() async {
    if (await _settingsStorage.file.exists() ||
        await File('${_settingsStorage.file.path}.bak').exists()) {
      return;
    }
    final legacy = await FilePersistence(File('${_dataRoot.path}/client.json'))
        .read();
    final oldLock = legacy['appLock'];
    final oldPreferences = legacy['preferences'];
    final hasPin = await native.invoke<bool>('hasPin') ?? false;
    final settings = <String, Object?>{};
    if (oldLock is Map || hasPin) {
      settings['appLock'] = {
        'enabled': hasPin || (oldLock is Map && oldLock['enabled'] == true),
        'hideNotificationBody':
            hasPin ||
            (oldLock is Map && oldLock['hideNotificationBody'] == true),
      };
    }
    if (oldPreferences is Map) {
      settings['preferences'] = {
        if (oldPreferences['autoStart'] is bool)
          'autoStart': oldPreferences['autoStart'],
        if (ThemeMode.values.any(
          (mode) => mode.name == oldPreferences['theme'],
        ))
          'theme': oldPreferences['theme'],
        if (oldPreferences['fontScale'] is num &&
            (oldPreferences['fontScale'] as num).isFinite &&
            (oldPreferences['fontScale'] as num) >= 0.8 &&
            (oldPreferences['fontScale'] as num) <= 2)
          'fontScale': oldPreferences['fontScale'],
      };
    }
    await _settingsStorage.write(settings);
  }

  Future<T> _secureOperation<T>(Future<T> Function() action) {
    final operation = _secureTail.then((_) => action());
    _secureTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<bool> _storeCredentials(
    ClientCredentials credentials,
    int generation, {
    required bool onboarded,
  }) => _secureOperation(() async {
    if (!_current(generation)) return false;
    await native.invoke<void>('storeSession', {
      'json': jsonEncode({...credentials.toJson(), 'onboarded': onboarded}),
    });
    return _current(generation);
  });

  HostConnection _newConnection(
    ClientCredentials credentials,
    int generation,
  ) => HostConnection(
    credentials.host,
    credentials.accessToken,
    onUnauthorized: () => _renewSession(generation),
  );

  Future<bool> _renewSession(int generation) {
    if (!_current(generation) || _credentials == null) {
      return Future.value(false);
    }
    final pending = _renewWork;
    if (pending != null) return pending;
    final work = _performRenewal(_credentials!, generation);
    _renewWork = work;
    return work.whenComplete(() {
      if (identical(_renewWork, work)) _renewWork = null;
    });
  }

  Future<bool> _performRenewal(
    ClientCredentials current,
    int generation,
  ) async {
    try {
      final pending = _pendingRenewal;
      final rotated =
          pending != null &&
              pending.generation == generation &&
              identical(pending.source, current)
          ? pending.rotated
          : await authenticator.refresh(current);
      if (!_current(generation) || !identical(_credentials, current)) {
        return false;
      }
      // The host already rotated its pair. Retain it in memory if protected
      // storage temporarily fails; refreshing the previous token cannot recover.
      _pendingRenewal = (
        generation: generation,
        source: current,
        rotated: rotated,
      );
      if (!await _storeCredentials(
        rotated,
        generation,
        onboarded: _onboarded,
      )) {
        return false;
      }
      if (!_current(generation) || !identical(_credentials, current)) {
        return false;
      }
      _credentials = rotated;
      _invalidateSharedTextContext();
      _pendingRenewal = null;
      connection?.updateAccessToken(rotated.accessToken);
      _submissionTransport?.updateAccessToken(rotated.accessToken);
      return true;
    } catch (error) {
      if (_current(generation)) {
        if (error is HostRequestException &&
            error.failure.code == FailureCode.unauthenticated) {
          _sessionRejected = true;
          _invalidateSharedTextContext(discard: true);
          _invalidateOwnAiDirect();
          _ownAiAccounts = [];
          _ownAiNotice = null;
          _chatEntered = false;
        }
        _online = false;
        _error = '登录验证失败，请重新登录；待发送消息已保留';
        notifyListeners();
      }
      return false;
    }
  }

  Future<_PreparedSnapshot> _prepareSnapshot(
    FilePersistence snapshot,
    ClientCredentials? credentials,
    int generation,
  ) async {
    final transport = credentials == null
        ? null
        : _newConnection(credentials, generation);
    late final ClientShellController next;
    next = ClientShellController(
      persistence: snapshot,
      submit: (item) async {
        if (transport == null || !_current(generation) || locked) {
          return const Err(Failure(FailureCode.unavailable, '离线'));
        }
        return transport.submit(
          OutboxSubmission(item.conversationId, {
            'clientMsgId': item.clientMsgId,
            'kind': item.kind.wire,
            'body': item.body,
          }),
        );
      },
      requestSync: (frame) async {
        if (transport != null) {
          await _syncConversation(
            transport,
            next,
            frame,
            generation,
            _historySyncEpoch,
          );
        }
      },
    );
    final nextConsent = ConversationConsentController(snapshot);
    try {
      await next.initialize();
      await nextConsent.initialize();
      final saved = await snapshot.read();
      return _PreparedSnapshot(
        snapshot,
        next,
        nextConsent,
        transport,
        credentials != null && saved['chatEntered'] == true,
      );
    } catch (_) {
      await transport?.close();
      rethrow;
    }
  }

  void _publishSnapshot(_PreparedSnapshot prepared) {
    _submissionTransport = prepared.transport;
    storage = prepared.storage;
    shell = prepared.shell;
    consent = prepared.consent;
    _chatEntered = prepared.chatEntered;
    _controllersReady = true;
  }

  HostConnection? _submissionTransport;

  Future<void> _logout() async {
    _invalidateSharedTextContext(discard: true);
    final generation = ++_generation;
    _invalidateOwnAiDirect();
    _pendingMention = null;
    _credentials = null;
    _pendingRenewal = null;
    _renewWork = null;
    _refreshWork = null;
    final previous = connection;
    final submission = _submissionTransport;
    final oldPlugins = plugins;
    plugins = null;
    connection = null;
    _submissionTransport = null;
    _onboarded = false;
    _chatEntered = false;
    _online = false;
    _conversations = [];
    _ownAiAccounts = [];
    _ownAiNotice = null;
    _ownAiLoaded = false;
    final clearingAttachment = _clearAttachmentSelection();
    _selected = null;
    _draft = '';
    appLock.lock();
    notifyListeners();
    final clear = _secureOperation(() => native.invoke<void>('clearSession'));
    await Future.wait<void>([
      clearingAttachment,
      if (previous != null) previous.close(),
      if (submission != null) submission.close(),
      if (oldPlugins != null) oldPlugins.unloadAll(),
    ]);
    await clear;
    final guest = await _prepareSnapshot(
      FilePersistence(File('${_dataRoot.path}/guest.json')),
      null,
      generation,
    );
    if (_current(generation)) _publishSnapshot(guest);
    notifyListeners();
  }

  /// Lifecycle states that must lock an enabled app lock. `inactive` is included
  /// because a mobile backend can stay half-covered (app switcher, split screen)
  /// in `inactive` without emitting `hidden`/`paused`, which would leave
  /// sensitive content visible. Locking is idempotent and only applies when the
  /// lock is enabled. `resumed`/`detached` do not lock.
  static bool shouldLockForLifecycle(AppLifecycleState state) =>
      state == AppLifecycleState.inactive ||
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_controllersReady) return;
    if (shouldLockForLifecycle(state)) {
      appLock.lock();
      unawaited(native.invoke<void>('lock'));
      notifyListeners();
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || _disposed) return;
    final generation = _generation;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      await action();
    } catch (error) {
      if (_current(generation)) _error = error.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _savePreferences() =>
      writeClientSection(_settingsStorage, 'preferences', {...preferences});

  Future<void> _refresh() {
    if (_disposed || connection == null || _switching || locked) {
      return Future<void>.value();
    }
    final active = _refreshWork;
    if (active != null) return active;
    _refreshGeneration++;
    final work = _performRefresh(
      connection!,
      shell,
      _generation,
      _historySyncEpoch,
    );
    _refreshWork = work;
    return work.whenComplete(() {
      if (identical(_refreshWork, work)) _refreshWork = null;
    });
  }

  bool _canSync(int generation, int epoch) =>
      _current(generation) &&
      _historySyncEpoch == epoch &&
      !locked &&
      !_switching &&
      !_sessionRejected;

  Future<bool> _syncConversation(
    HostConnection transport,
    ClientShellController sessionShell,
    SyncRequestFrame frame,
    int generation,
    int epoch,
  ) async {
    void checkActive() {
      if (!_canSync(generation, epoch)) throw const _SyncInterrupted();
    }

    try {
      await transport.sync(
        frame,
        (message) async {
          await sessionShell.acceptMessage(message, checkActive: checkActive);
        },
        applyHistoryFloor: (firstVisibleSeq) =>
            sessionShell.applySyncHistoryFloor(
              frame.conversationId,
              firstVisibleSeq,
              checkActive: checkActive,
            ),
        checkActive: checkActive,
      );
      checkActive();
      return true;
    } on _SyncInterrupted {
      return false;
    }
  }

  Future<void> _performRefresh(
    HostConnection sessionConnection,
    ClientShellController sessionShell,
    int generation,
    int epoch,
  ) async {
    try {
      // `/host` is administrator-only on the current host. A friend client
      // legitimately receives 403; that must mean isHostMachine=false rather
      // than taking the whole shell offline.
      var isHostMachine = false;
      try {
        final info = await sessionConnection.request('GET', Routes.hostInfo);
        isHostMachine = info['isHostMachine'] == true;
      } on HostRequestException catch (error) {
        if (error.failure.code != FailureCode.forbidden &&
            error.failure.code != FailureCode.unauthenticated) {
          rethrow;
        }
      }
      if (!_canSync(generation, epoch)) return;
      plugins ??= PluginHost(
        environment: PluginEnvironment(
          platform: Platform.isWindows ? 'windows' : 'android',
          isHostMachine: isHostMachine,
        ),
        sendText: (id, text) async {
          if (!_current(generation) || locked) return;
          await sessionShell.enqueue(id, MessageKind.text, {'text': text});
          if (_current(generation) && !locked) await sessionShell.flush();
        },
      );
      final list = await sessionConnection.request('GET', Routes.conversations);
      if (!_canSync(generation, epoch)) return;
      final direct = await sessionConnection.request(
        'GET',
        Routes.directConversations,
      );
      if (!_canSync(generation, epoch)) return;
      final conversations = mapConversations(
        groups: list['conversations'],
        directs: direct['conversations'],
      );
      _conversations = conversations;
      _online = true;
      await sessionShell.flush();
      for (final conversation in conversations) {
        if (!_canSync(generation, epoch)) return;
        final completed = await _syncConversation(
          sessionConnection,
          sessionShell,
          SyncRequestFrame(
            id: 'refresh-${conversation.id}',
            at: DateTime.now().toUtc(),
            conversationId: conversation.id,
            afterSeq: sessionShell.lastSeqFor(conversation.id),
          ),
          generation,
          epoch,
        );
        if (!completed) return;
      }
      if (_canSync(generation, epoch) && Platform.isAndroid) {
        await native.invoke<bool>('setForegroundService', {'enabled': true});
      }
    } catch (_) {
      if (_current(generation) && _historySyncEpoch == epoch) _online = false;
    }
    if (_current(generation)) notifyListeners();
  }

  @override
  Future<void> connectHost(
    String address,
    String invite, {
    String displayName = '',
    String password = '',
    String deviceName = '',
    String accountId = '',
  }) => _run(() async {
    if (!_controllersReady || locked) throw const FormatException('请先解锁应用');
    final generation = _generation;
    late ClientCredentials credentials;
    try {
      credentials = await authenticator.connect(
        hostAddress: address,
        invite: invite,
        displayName: displayName,
        password: password,
        deviceName: deviceName,
        accountId: accountId,
      );
    } catch (_) {
      final recovered = authenticator.redeemedAccountId;
      if (accountId.isEmpty && recovered != null) {
        throw FormatException('账户已创建，账户 ID：$recovered；请保留此 ID 并使用已有账户登录重试');
      }
      rethrow;
    }
    if (!_current(generation)) return;
    _switching = true;
    _invalidateSharedTextContext(discard: true);
    _PreparedSnapshot? prepared;
    var published = false;
    try {
      await _refreshWork;
      if (!_current(generation)) return;
      if (_selected != null) await shell.saveDraft(_selected!, _draft);
      final snapshot = await AccountSnapshots(_dataRoot)
          .open(credentials.host, credentials.accountId, credentials.deviceId);
      prepared = await _prepareSnapshot(snapshot, credentials, generation + 1);
      if (!_current(generation)) return;
      // Snapshot decoding must succeed before replacing protected credentials.
      if (!await _storeCredentials(credentials, generation, onboarded: false)) {
        return;
      }
      if (!_current(generation)) return;
      final previous = connection;
      final submission = _submissionTransport;
      final oldPlugins = plugins;
      ++_generation;
      _invalidateOwnAiDirect();
      _pendingMention = null;
      _credentials = credentials;
      _sessionRejected = false;
      _pendingRenewal = null;
      _renewWork = null;
      _refreshWork = null;
      _publishSnapshot(prepared);
      connection = _newConnection(credentials, _generation);
      published = true;
      plugins = null;
      _online = false;
      _onboarded = false;
      final clearingAttachment = _clearAttachmentSelection();
      _selected = null;
      _draft = '';
      _conversations = [];
      _ownAiAccounts = [];
      _ownAiNotice = null;
      _ownAiLoaded = false;
      await Future.wait<void>([
        clearingAttachment,
        if (previous != null) previous.close(),
        if (submission != null) submission.close(),
        if (oldPlugins != null) oldPlugins.unloadAll(),
      ]);
    } finally {
      if (!published) await prepared?.transport?.close();
      _switching = false;
    }
    await _refresh();
  });

  /// Enter the existing chat shell before optional world setup. Requires a
  /// published authenticated session; it never marks world setup complete.
  @override
  Future<void> enterChat() => _run(() async {
    final credentials = _credentials;
    if (credentials == null || _sessionRejected || locked) {
      throw const FormatException('请先解锁应用并连接宿主登录');
    }
    final generation = _generation;
    final sessionStorage = storage;
    await writeClientSection(sessionStorage, 'chatEntered', true);
    if (!_current(generation) ||
        locked ||
        !identical(storage, sessionStorage)) {
      return;
    }
    _chatEntered = true;
    notifyListeners();
  });
  @override
  Future<void> chooseCharacter(String characterId) => _run(() async {
    throw const HttpException('宿主人物创建接口尚未提供，无法保存形象');
  });
  @override
  Future<void> generateRoom(String preset) => _run(() async {
    if (plugins == null || plugins!.roomGenerators.isEmpty) {
      throw const HttpException('房间生成插件尚未安装');
    }
  });
  @override
  Future<void> confirmRoom() => _run(() async {
    throw const HttpException('宿主房间保存接口尚未提供');
  });
  @override
  bool get canAddMembersToSelectedGroup =>
      authenticated &&
      _conversations.any(
        (conversation) =>
            conversation.id == _selected &&
            conversation.kind == 'group' &&
            conversation.ownerAccountId == connectedAccountId,
      );

  void _requireOnlineGroupSession() {
    if (!authenticated ||
        _sessionRejected ||
        connection == null ||
        locked ||
        !_online ||
        _switching) {
      throw const FormatException('请先解锁并连接宿主，群操作需要在线完成');
    }
  }

  @override
  Future<void> refreshConversations() async {
    if (_busy || !authenticated || _sessionRejected || locked || _switching) {
      return;
    }
    final generation = _generation;
    final previousError = _error;
    await _refresh();
    if (_current(generation) &&
        authenticated &&
        !locked &&
        !_busy &&
        _online &&
        _error == previousError) {
      _error = null;
      notifyListeners();
    }
  }

  @override
  Future<OwnAiChatEntry> checkOwnAiChatEntry(String aiAccountId) async {
    final refreshGeneration = _refreshGeneration;
    final session = connection;
    final owner = connectedAccountId;
    final epoch = ownAiDirectContext;
    final generation = _generation;
    final initial = ownAiDirectState(aiAccountId);
    final profile = initial.profileId;
    final revision = initial.revision;
    final id = initial.conversationId;
    if (session == null ||
        owner == null ||
        epoch == null ||
        _sessionRejected ||
        !_activeOwnAi(aiAccountId) ||
        initial.phase != ShellOwnAiDirectPhase.ready ||
        initial.enabled != true ||
        profile == null ||
        profile.isEmpty ||
        revision == null ||
        id == null ||
        id.isEmpty) {
      return OwnAiChatEntry.cancelled;
    }

    OwnAiChatEntry? blocked() {
      if (!_directContext(generation, session, epoch, aiAccountId) ||
          connectedAccountId != owner ||
          _sessionRejected) {
        return OwnAiChatEntry.cancelled;
      }
      final state = ownAiDirectState(aiAccountId);
      if (state.phase != ShellOwnAiDirectPhase.ready ||
          state.enabled != true ||
          state.profileId != profile ||
          state.revision != revision ||
          state.conversationId != id) {
        return OwnAiChatEntry.cancelled;
      }
      if (_busy ||
          _refreshWork != null ||
          _refreshGeneration != refreshGeneration) {
        return OwnAiChatEntry.busy;
      }
      if (!online) return OwnAiChatEntry.unavailable;
      return null;
    }

    final before = blocked();
    if (before != null) return before;
    try {
      final direct = await session.request(
        'GET',
        Routes.directConversations,
        retryAuthentication: false,
      );
      final afterList = blocked();
      if (afterList != null) return afterList;
      final rows = direct['conversations'];
      if (rows is! List) return OwnAiChatEntry.unavailable;
      final matches = rows.whereType<Map>().where((row) => row['id'] == id);
      if (matches.length != 1) return OwnAiChatEntry.notVisible;
      final row = matches.single;
      final a = row['accountLow'];
      final b = row['accountHigh'];
      if (row['kind'] != 'direct' ||
          !((a == owner && b == aiAccountId) ||
              (b == owner && a == aiAccountId))) {
        return OwnAiChatEntry.notVisible;
      }
      final mapped = mapConversations(groups: null, directs: [row]).single;

      // Read consent last: an owner can still read retained history after revoke.
      final live = await OwnerAiDirectApi(session)
          .read(profile, retryAuthentication: false);
      final afterConsent = blocked();
      if (afterConsent != null) return afterConsent;
      if (!live.enabled ||
          live.aiProfileId != profile ||
          live.aiAccountId != aiAccountId ||
          live.revision != revision ||
          live.conversationId != id) {
        return OwnAiChatEntry.consentChanged;
      }

      // Append only a missing canonical row to the current list. Neither this
      // shortcut nor its failed checks publish an older conversation snapshot.
      final existing = _conversations.where((c) => c.id == id);
      if (existing.isNotEmpty) {
        return existing.length == 1 && existing.single.kind == 'direct'
            ? OwnAiChatEntry.ready
            : OwnAiChatEntry.notVisible;
      }
      _conversations = [..._conversations, mapped];
      notifyListeners();
      return OwnAiChatEntry.ready;
    } catch (_) {
      return blocked() ?? OwnAiChatEntry.unavailable;
    }
  }

  bool _ownAiCurrentSession(int generation, HostConnection session) =>
      _current(generation) &&
      authenticated &&
      !_switching &&
      identical(connection, session);

  bool _ownAiContext(int generation, HostConnection session) =>
      _ownAiCurrentSession(generation, session) && !locked;

  void _publishOwnAi(List<OwnedAiAccount> rows) {
    // A fresh list is a new ownership snapshot; never leave stale confirmations.
    _invalidateOwnAiDirect();
    _ownAiLoaded = true;
    _ownAiAccounts = [
      for (final row in rows)
        ShellOwnedAi(
          accountId: row.accountId,
          displayName: row.displayName,
          disabled: row.disabled,
        ),
    ];
  }

  void _ownAiFailure(
    Object error,
    int generation,
    HostConnection session, {
    bool creating = false,
  }) {
    if (!_ownAiCurrentSession(generation, session)) return;
    if (error is HostRequestException &&
        error.failure.code == FailureCode.unauthenticated &&
        error.failure.details['authenticationRenewalFailed'] != true) {
      _sessionRejected = true;
      _invalidateSharedTextContext(discard: true);
      _invalidateOwnAiDirect();
      _online = false;
      _ownAiAccounts = [];
      _ownAiNotice = null;
      _ownAiLoaded = false;
      _error = '登录验证已失效，请重新登录';
      return;
    }
    if (locked) return;
    if (error is HostRequestException) {
      if (error.failure.code == FailureCode.unauthenticated) {
        if (error.failure.details['authenticationRenewalFailed'] == true) {
          _error = '登录续期暂不可用，请稍后重试';
          return;
        }
      }
      if (const {
        FailureCode.invalidArgument,
        FailureCode.forbidden,
        FailureCode.rateLimited,
        FailureCode.notFound,
        FailureCode.conflict,
      }.contains(error.failure.code)) {
        _error = error.failure.message;
        return;
      }
    }
    _error = creating ? 'AI账户创建未确认，可能已创建；请先刷新我的AI，勿重复创建' : '我的AI列表读取失败，请重试刷新';
  }

  bool _activeOwnAi(String accountId) =>
      _ownAiLoaded &&
      _ownAiAccounts.any((row) => row.accountId == accountId && !row.disabled);

  bool _directContext(
    int generation,
    HostConnection session,
    Object epoch,
    String account,
  ) =>
      _ownAiContext(generation, session) &&
      identical(_ownAiDirectEpoch, epoch) &&
      _activeOwnAi(account);

  void _publishDirect(
    String account,
    OwnerAiDirectConsentState state, {
    String? notice,
  }) {
    if (state.aiAccountId != account) throw const FormatException('AI私聊身份不匹配');
    _ownAiDirect[account] = ShellOwnAiDirectState(
      phase: ShellOwnAiDirectPhase.ready,
      profileId: state.aiProfileId,
      revision: state.revision,
      enabled: state.enabled,
      conversationId: state.conversationId,
      notice: notice,
    );
  }

  void _directFailure(
    Object error,
    int generation,
    HostConnection session,
    Object epoch,
    String account,
  ) {
    // Terminal auth must clear private caches even after a lock invalidated epoch.
    if (error is HostRequestException &&
        error.failure.code == FailureCode.unauthenticated) {
      _ownAiFailure(error, generation, session);
      if (!_directContext(generation, session, epoch, account)) return;
    }
    if (!_directContext(generation, session, epoch, account)) return;
    if (error is HostRequestException &&
        const {
          FailureCode.invalidArgument,
          FailureCode.forbidden,
          FailureCode.notFound,
          FailureCode.rateLimited,
        }.contains(error.failure.code)) {
      _ownAiDirect[account] = const ShellOwnAiDirectState(
        notice: '授权请求被拒绝，请刷新读取后重新确认',
      );
      _error = error.failure.message;
      return;
    }
    _ownAiDirect[account] = const ShellOwnAiDirectState(
      phase: ShellOwnAiDirectPhase.uncertain,
      notice: '授权状态未确认，请刷新读取后重新确认；勿重复提交',
    );
    _error = 'AI私聊授权状态未确认，请刷新后重新确认';
  }

  @override
  Future<void> loadOwnAiDirectConsent(String aiAccountId) => _run(() async {
    _requireOnlineGroupSession();
    if (!_activeOwnAi(aiAccountId)) {
      _ownAiDirect.remove(aiAccountId);
      _error = '请选择当前本人名下的有效AI账户';
      return;
    }
    final generation = _generation;
    final session = connection!;
    final owner = connectedAccountId!;
    _ownAiDirectEpoch = Object();
    final epoch = _ownAiDirectEpoch;
    _ownAiDirect[aiAccountId] = const ShellOwnAiDirectState(
      phase: ShellOwnAiDirectPhase.loading,
    );
    notifyListeners();
    if (!_directContext(generation, session, epoch, aiAccountId)) return;
    try {
      final api = OwnerAiDirectApi(session);
      final identity = await api.registerOrResolve(
        aiAccountId,
        expectedOwnerAccountId: owner,
      );
      if (!_directContext(generation, session, epoch, aiAccountId)) return;
      final state = await api.read(identity.profileId);
      if (!_directContext(generation, session, epoch, aiAccountId)) return;
      _publishDirect(aiAccountId, state);
    } catch (error) {
      _directFailure(error, generation, session, epoch, aiAccountId);
    }
  });

  @override
  Future<void> setOwnAiDirectConsent(
    String aiAccountId, {
    required String profileId,
    required int expectedRevision,
    required bool enabled,
    required Object interactionContext,
  }) => _run(() async {
    _requireOnlineGroupSession();
    final current = ownAiDirectState(aiAccountId);
    if (!_activeOwnAi(aiAccountId) ||
        !identical(interactionContext, _ownAiDirectEpoch) ||
        current.phase != ShellOwnAiDirectPhase.ready ||
        current.profileId != profileId ||
        current.revision != expectedRevision ||
        expectedRevision < 0) {
      _error = '授权状态已变化，请刷新后重新确认';
      return;
    }
    final generation = _generation;
    final session = connection!;
    // Consume the confirmation immediately. No retry, including after a 401.
    // A request already sent may still commit across lock/logout; invalidation
    // only prevents stale publication/replay, never pretends it was unsent.
    _ownAiDirectEpoch = Object();
    final epoch = _ownAiDirectEpoch;
    _ownAiDirect[aiAccountId] = const ShellOwnAiDirectState(
      phase: ShellOwnAiDirectPhase.loading,
    );
    notifyListeners();
    if (!_directContext(generation, session, epoch, aiAccountId)) return;
    final api = OwnerAiDirectApi(session);
    try {
      final state = enabled
          ? await api.open(
              profileId,
              expectedRevision: expectedRevision,
              retryAuthentication: false,
            )
          : await api.revoke(
              profileId,
              expectedRevision: expectedRevision,
              retryAuthentication: false,
            );
      if (!_directContext(generation, session, epoch, aiAccountId)) return;
      _publishDirect(aiAccountId, state);
    } catch (error) {
      if (error is HostRequestException &&
          error.failure.code == FailureCode.conflict &&
          _directContext(generation, session, epoch, aiAccountId)) {
        try {
          // Reconcile only. Never replay the mutation or profile registration.
          final state = await api.read(profileId);
          if (!_directContext(generation, session, epoch, aiAccountId)) return;
          _publishDirect(aiAccountId, state, notice: '授权版本已变化，请重新确认');
          _error = '授权版本已变化，请重新确认';
        } catch (readError) {
          _directFailure(readError, generation, session, epoch, aiAccountId);
        }
      } else {
        _directFailure(error, generation, session, epoch, aiAccountId);
      }
    }
  });

  @override
  Future<void> loadOwnAi() => _run(() async {
    _requireOnlineGroupSession();
    final generation = _generation;
    final session = connection!;
    try {
      final rows = await OwnAiApi(session).list();
      if (!_ownAiContext(generation, session)) return;
      _publishOwnAi(rows);
      _ownAiNotice = null;
    } catch (error) {
      _ownAiFailure(error, generation, session);
    }
  });

  @override
  Future<void> createOwnAi(String displayName) => _run(() async {
    _requireOnlineGroupSession();
    if (displayName.trim().isEmpty || displayName.length > 100) {
      throw const FormatException('名称须为1–100个字符');
    }
    final generation = _generation;
    final session = connection!;
    _ownAiNotice = null;
    final String id;
    try {
      id = await OwnAiApi(session).create(displayName);
    } catch (error) {
      _ownAiFailure(error, generation, session, creating: true);
      return;
    }
    if (!_ownAiContext(generation, session)) return;
    _ownAiNotice = 'AI账户已创建：$id。仅创建账户，回复仍需宿主配置。';
    notifyListeners();
    try {
      final rows = await OwnAiApi(session).list();
      if (_ownAiContext(generation, session)) _publishOwnAi(rows);
    } catch (error) {
      if (error is HostRequestException &&
          error.failure.code == FailureCode.unauthenticated) {
        if (error.failure.details['authenticationRenewalFailed'] == true) {
          if (_ownAiContext(generation, session)) {
            _error = null;
            _ownAiNotice = 'AI账户已创建：$id；列表刷新失败，请刷新我的AI。';
          }
        } else {
          _ownAiFailure(error, generation, session);
        }
      } else if (_ownAiContext(generation, session)) {
        _error = null;
        _ownAiNotice = 'AI账户已创建：$id；列表刷新失败，请刷新我的AI。';
      }
    }
  });

  @override
  Future<void> createGroup(String name) => _run(() async {
    _requireOnlineGroupSession();
    final generation = _generation;
    final sessionConnection = connection!;
    final sessionShell = shell;
    // Finish any already-running list refresh before publishing the new group;
    // periodic refresh does not start while _run holds busy.
    await _refreshWork;
    if (!_current(generation) ||
        locked ||
        !authenticated ||
        !identical(connection, sessionConnection)) {
      return;
    }
    _requireOnlineGroupSession();
    if (_selected != null) await sessionShell.saveDraft(_selected!, _draft);
    if (!_current(generation) || locked || !authenticated) return;
    if (name.trim().isEmpty || name.length > 100) {
      throw const FormatException('群名须为1–100个字符');
    }
    final HostGroup group;
    try {
      group = await GroupApi(sessionConnection).createGroup(name);
    } catch (_) {
      throw const FormatException('群聊创建未确认，可能已创建；请刷新会话后再重试');
    }
    if (!_current(generation) ||
        locked ||
        !authenticated ||
        !identical(connection, sessionConnection)) {
      return;
    }
    _conversations = [
      ..._conversations.where((conversation) => conversation.id != group.id),
      ShellConversation(
        id: group.id,
        title: group.name,
        kind: 'group',
        ownerAccountId: group.ownerAccountId,
      ),
    ]..sort((left, right) => left.title.compareTo(right.title));
    unawaited(_clearAttachmentSelection());
    _selected = group.id;
    _draft = sessionShell.draftFor(group.id);
  });

  @override
  Future<void> addGroupMember(String groupId, String accountId) =>
      _run(() async {
        _requireOnlineGroupSession();
        if (_selected != groupId || !canAddMembersToSelectedGroup) {
          throw const FormatException('仅当前群主可添加成员');
        }
        final generation = _generation;
        final sessionConnection = connection!;
        await GroupApi(sessionConnection).addMember(groupId, accountId);
        if (!_current(generation) ||
            locked ||
            !authenticated ||
            !identical(connection, sessionConnection)) {
          return;
        }
      });

  @override
  Future<void> selectConversation(String id) async {
    if (_selected != id) {
      _invalidateSharedTextContext();
      unawaited(_clearAttachmentSelection());
    }
    _selected = id;
    _draft = shell.draftFor(id);
    notifyListeners();
    // Selection stays synchronous: the durable mark and its receipt run off the
    // shell serial queue (a flush can hold it across network IO) and are guarded
    // so a stale result never publishes. Re-selecting re-checks the head so a
    // message that arrived while the chat was open can still clear the badge.
    unawaited(_markConversationRead(id));
  }

  /// Persists the read position for [id] and reports it once. Nothing happens
  /// when the position is already at the head, so repeated opens never send a
  /// duplicate receipt.
  Future<void> _markConversationRead(String id) async {
    final generation = _generation;
    final sessionShell = shell;
    final sessionConnection = connection;
    final epoch = _historySyncEpoch;
    if (sessionConnection == null ||
        !_controllersReady ||
        !authenticated ||
        locked ||
        _switching ||
        _sessionRejected ||
        !_online ||
        !identical(shell, sessionShell)) {
      return;
    }
    final head = sessionShell.lastSeqFor(id);
    if (head < 1 || sessionShell.readSeqFor(id) >= head) return;
    bool current() =>
        _current(generation) &&
        epoch == _historySyncEpoch &&
        _selected == id &&
        identical(shell, sessionShell) &&
        identical(connection, sessionConnection) &&
        authenticated &&
        !locked &&
        !_switching &&
        !_sessionRejected;
    try {
      await sessionShell.markRead(
        id,
        head,
        checkActive: () {
          if (!current()) throw const _ReadInterrupted();
        },
      );
    } catch (_) {
      return;
    }
    if (!current()) return;
    await _sendReadReceipt(id, head, generation, epoch, sessionConnection);
  }

  /// Exactly one best-effort receipt per successful advance. A failure is
  /// silent and is never retried; a later lock/logout/switch discards it.
  Future<void> _sendReadReceipt(
    String id,
    int head,
    int generation,
    int epoch,
    HostConnection sessionConnection,
  ) async {
    if (!_current(generation) ||
        epoch != _historySyncEpoch ||
        _selected != id ||
        !authenticated ||
        locked ||
        _switching ||
        _sessionRejected) {
      return;
    }
    try {
      await sessionConnection.request(
        'POST',
        Routes.messageAck.replaceAll(
          '{conversationId}',
          Uri.encodeComponent(id),
        ),
        body: {'seq': head},
      );
    } catch (_) {
      // Reading must never be blocked by a best-effort read receipt.
    }
  }

  @override
  void updateDraft(String value) {
    _draft = value;
    final selected = _selected;
    if (selected != null) {
      final generation = _generation;
      _draftRevisions.update(
        selected,
        (revision) => revision + 1,
        ifAbsent: () => 1,
      );
      // Schedule the save before listeners can request a send of this draft.
      unawaited(
        shell.saveDraft(selected, value).catchError((Object e) {
          if (!_current(generation)) return;
          _error = '草稿保存失败';
          notifyListeners();
        }),
      );
    }
    notifyListeners();
  }

  @override
  Future<void> sendMessage() => _run(() async {
    if (locked || _selected == null || _draft.trim().isEmpty) return;
    final queuedMention = shell.outbox.items.any(
      (item) =>
          item.conversationId == _selected &&
          item.body['text'] == _draft &&
          item.body['mentionAccountIds'] is List,
    );
    final pending = _pendingMention;
    if (queuedMention) {
      throw const FormatException('本条提及已排队，请重试原提及以确认保存，避免重复发送');
    }
    if (pending != null &&
        pending.generation == _generation &&
        identical(pending.shell, shell) &&
        pending.group == _selected &&
        pending.text == _draft) {
      throw const FormatException('本条提及已排队，请重试原提及以确认保存，避免重复发送');
    }
    final generation = _generation;
    final sessionShell = shell;
    final selected = _selected!;
    final text = _draft;
    final draftRevision = _draftRevisions[selected] ?? 0;
    await sessionShell.enqueueTextDraft(selected, text);
    if (!_current(generation)) return;
    if (_selected == selected &&
        _draft == text &&
        (_draftRevisions[selected] ?? 0) == draftRevision) {
      _draft = '';
    }
    if (_online && !locked) await sessionShell.flush();
  });
  @override
  bool get canMentionAi =>
      authenticated &&
      !locked &&
      !_busy &&
      _draft.trim().isNotEmpty &&
      _conversations.any(
        (item) => item.id == _selected && item.kind == 'group',
      );

  @override
  Future<void> sendMentionedMessage({
    required String conversationId,
    required String expectedDraft,
    required String aiAccountId,
  }) => _run(() async {
    if (!authenticated ||
        _sessionRejected ||
        locked ||
        _switching ||
        _selected != conversationId ||
        _draft != expectedDraft ||
        expectedDraft.trim().isEmpty ||
        !_conversations.any(
          (item) => item.id == conversationId && item.kind == 'group',
        )) {
      throw const FormatException('聊天状态已变化，请重新确认本条提及');
    }
    final target = AccountId.parse(aiAccountId).value;
    final draftRevision = _draftRevisions[conversationId] ?? 0;
    final generation = _generation;
    final sessionShell = shell;
    var pending = _pendingMention;
    if (pending == null ||
        pending.generation != generation ||
        !identical(pending.shell, sessionShell)) {
      for (final item in sessionShell.outbox.items) {
        final ids = item.body['mentionAccountIds'];
        if (item.conversationId == conversationId &&
            item.body['text'] == expectedDraft &&
            ids is List &&
            ids.length == 1 &&
            ids.single is String) {
          pending = (
            shell: sessionShell,
            generation: generation,
            group: conversationId,
            text: expectedDraft,
            target: ids.single as String,
            id: item.clientMsgId,
          );
          _pendingMention = pending;
          break;
        }
      }
    }
    final sameIntent =
        pending != null &&
        pending.generation == generation &&
        identical(pending.shell, sessionShell) &&
        pending.group == conversationId &&
        pending.text == expectedDraft;
    if (pending != null &&
        pending.generation == generation &&
        identical(pending.shell, sessionShell) &&
        (!sameIntent || pending.target != target)) {
      throw const FormatException('上一条提及保存尚未确认，请返回原会话重试原提及，避免重复发送');
    }
    if (!sameIntent) {
      final previousIds = sessionShell.outbox.items
          .map((item) => item.clientMsgId)
          .toSet();
      try {
        final id = await sessionShell.enqueue(
          conversationId,
          MessageKind.text,
          {
            'text': expectedDraft,
            'mentionAccountIds': <String>[target],
          },
        );
        pending = (
          shell: sessionShell,
          generation: generation,
          group: conversationId,
          text: expectedDraft,
          target: target,
          id: id,
        );
        if (_current(generation)) _pendingMention = pending;
      } catch (_) {
        // enqueue retains its item when the durable checkpoint fails. Capture
        // that original identity so confirm/recovery cannot enqueue a duplicate.
        for (final item in sessionShell.outbox.items) {
          final mentions = item.body['mentionAccountIds'];
          if (!previousIds.contains(item.clientMsgId) &&
              item.conversationId == conversationId &&
              item.body['text'] == expectedDraft &&
              mentions is List &&
              mentions.length == 1 &&
              mentions.single == target) {
            if (_current(generation)) {
              _pendingMention = (
                shell: sessionShell,
                generation: generation,
                group: conversationId,
                text: expectedDraft,
                target: target,
                id: item.clientMsgId,
              );
            }
            break;
          }
        }
        throw const FormatException('本条提及仍保留待发送；保存未确认，请重试原提及，勿重复普通发送');
      }
    }
    if (!_current(generation)) return;
    if ((_draftRevisions[conversationId] ?? 0) != draftRevision) return;
    await sessionShell.saveDraft(conversationId, '');
    if (!_current(generation)) return;
    if (_selected == conversationId &&
        _draft == expectedDraft &&
        (_draftRevisions[conversationId] ?? 0) == draftRevision) {
      _draft = '';
    }
    if (_pendingMention?.id == pending.id) _pendingMention = null;
    if (_online && !locked && authenticated) await sessionShell.flush();
  });

  @override
  Future<void> setAiConsent(bool allowed) => _run(() async {
    if (_selected == null) return;
    if (allowed) {
      await consent.grant(_selected!);
    } else {
      await consent.revoke(_selected!);
    }
  });

  @override
  String? get selectedAttachmentName {
    final draft = _attachmentDraft;
    return draft != null && !locked && _isAttachmentDraftCurrent(draft)
        ? draft.name
        : null;
  }

  @override
  Future<void> attachFile(String kind) => _run(() async {
    if (kind != 'image' && kind != 'file') {
      throw const FormatException('不支持的附件类型');
    }
    final generation = _generation;
    final sessionConnection = connection;
    final selected = _selected;
    if (sessionConnection == null ||
        selected == null ||
        locked ||
        !_attachmentContext(generation, sessionConnection, selected) ||
        !aiConsentGranted) {
      throw const FormatException('请先解锁并确认当前会话的附件设置');
    }
    final revision = _attachmentSelectionRevision;
    final PickedAttachment? picked;
    try {
      picked = await native.pickAttachment(kind);
    } catch (_) {
      throw const FormatException('无法选择附件，未发送内容');
    }
    if (picked == null) return;

    // Android's system picker can pause and lock the app. Its result is only
    // staged in memory for the same chat, hidden until unlock, never uploaded.
    if (revision != _attachmentSelectionRevision ||
        !_attachmentContext(generation, sessionConnection, selected)) {
      await _releasePickedAttachment(picked);
      return;
    }
    final name = FileAttachmentContent.safeDisplayName(picked.name);
    final previous = _attachmentDraft;
    _attachmentDraft = _AttachmentDraft(
      picked: picked,
      name: name,
      kind: kind,
      generation: generation,
      connection: sessionConnection,
      conversationId: selected,
    );
    if (previous != null) await _releasePickedAttachment(previous.picked);
  });

  @override
  Future<void> discardSelectedAttachment() => _run(_clearAttachmentSelection);

  @override
  Future<void> sendSelectedAttachment() {
    final draft = _attachmentDraft;
    final lockEpoch = _historySyncEpoch;
    return _run(() async {
      if (draft == null || !_isAttachmentDraftCurrent(draft) || locked) return;
      if (!_online || !aiConsentGranted) {
        throw const FormatException('请联网并确认当前会话的附件设置后再发送');
      }
      final sessionShell = shell;
      void checkActive() {
        if (!_isAttachmentDraftCurrent(draft) ||
            !identical(shell, sessionShell) ||
            _historySyncEpoch != lockEpoch ||
            locked ||
            !_online ||
            !aiConsentGranted) {
          throw const AttachmentSendCancelled();
        }
      }

      final FileAttachmentContent content;
      try {
        content = await FileAttachmentContent.load(
          draft.picked.path,
          kind: draft.kind,
          displayName: draft.name,
          declaredMime: draft.picked.mime,
        );
      } on FormatException {
        rethrow;
      } catch (_) {
        throw const FormatException('所选文件不可用，未发送内容');
      }

      final AttachmentSendResult uploaded;
      try {
        uploaded =
            await AttachmentSendFlow(
              AttachmentUploadApi(draft.connection),
              abortOnFailure: true,
            ).upload(
              source: content,
              conversationId: draft.conversationId,
              checkActive: checkActive,
            );
      } on AttachmentSendCancelled {
        return;
      } catch (_) {
        throw const FormatException('附件上传失败，未发送内容');
      }

      try {
        checkActive();
        await sessionShell.enqueueDurable(draft.conversationId, uploaded.kind, {
          'attachmentId': uploaded.attachmentId,
          'name': content.displayName,
        }, checkActive: checkActive);
      } catch (error) {
        await _deleteUnsentAttachment(draft.connection, uploaded.attachmentId);
        if (error is AttachmentSendCancelled) return;
        throw const FormatException('附件消息保存失败，请重试发送');
      }
      if (identical(_attachmentDraft, draft)) await _clearAttachmentSelection();
      if (_current(draft.generation) && _online && !locked) {
        await sessionShell.flush();
      }
    });
  }

  bool _isAttachmentDraftCurrent(_AttachmentDraft draft) =>
      identical(_attachmentDraft, draft) &&
      _attachmentContext(
        draft.generation,
        draft.connection,
        draft.conversationId,
      );

  bool _attachmentContext(
    int generation,
    HostConnection sessionConnection,
    String conversationId,
  ) =>
      _current(generation) &&
      authenticated &&
      !_sessionRejected &&
      !_switching &&
      identical(connection, sessionConnection) &&
      _selected == conversationId &&
      _conversations.any((entry) => entry.id == conversationId);

  Future<void> _clearAttachmentSelection() async {
    _attachmentSelectionRevision++;
    final previous = _attachmentDraft;
    _attachmentDraft = null;
    if (previous != null) await _releasePickedAttachment(previous.picked);
  }

  Future<void> _releasePickedAttachment(PickedAttachment picked) async {
    if (!picked.temporary) return;
    try {
      await File(picked.path).delete();
    } catch (_) {}
  }

  Future<void> _deleteUnsentAttachment(
    HostConnection sessionConnection,
    String attachmentId,
  ) async {
    try {
      await AttachmentApi(sessionConnection)
          .deleteAttachment(attachmentId, retryAuthentication: false);
    } catch (_) {}
  }

  @override
  Future<void> setAppLock(bool enabled, String pin) => _run(() async {
    if (enabled) {
      await appLock.enable(pin);
    } else {
      if (!await appLock.disable(pin)) throw const FormatException('PIN 不正确');
    }
  });
  @override
  Future<void> unlock(String pin) => _run(() async {
    _invalidateSharedTextContext();
    if (!await appLock.unlockWithPin(pin)) {
      throw const FormatException('PIN 不正确');
    }
    if (connection == null) return;
    final generation = _generation;
    final previous = _refreshWork;
    if (previous == null) {
      unawaited(_refresh());
    } else {
      // The superseded flight must stop before refresh takes a new cursor.
      unawaited(
        previous.then((_) async {
          if (_current(generation)) await _refresh();
        }),
      );
    }
  });
  @override
  Future<void> setHideNotificationBody(bool value) => _run(() async {
    _invalidateOwnAiDirect();
    await appLock.setHideNotificationBody(value);
  });

  @override
  Future<void> setAutoStart(bool value) => _run(() async {
    await native.invoke<void>('setAutostart', {'enabled': value});
    preferences['autoStart'] = value;
    await _savePreferences();
  });

  @override
  Future<void> setThemeMode(ThemeMode value) => _run(() async {
    preferences['theme'] = value.name;
    await _savePreferences();
  });

  @override
  Future<void> setFontScale(double value) => _run(() async {
    preferences['fontScale'] = value;
    await _savePreferences();
  });

  @override
  void clearError() {
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _invalidateSharedTextContext(discard: true);
    ++_generation;
    _invalidateOwnAiDirect();
    _pendingMention = null;
    unawaited(_clearAttachmentSelection());
    _credentials = null;
    _pendingRenewal = null;
    reconnect?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    NativePlatform.channel.setMethodCallHandler(null);
    unawaited(connection?.close());
    unawaited(_submissionTransport?.close());
    connection = null;
    _submissionTransport = null;
    super.dispose();
  }
}

class _SharedTextInterrupted implements Exception {
  const _SharedTextInterrupted();
}

class _ShareInteractionContext {
  const _ShareInteractionContext(this.epoch, this.credentials, this.share);
  final Object epoch;
  final ClientCredentials? credentials;
  final ShellIncomingShare share;
}

/// Capture even direct appLock.lock() calls without changing lock behavior or
/// notifying listeners reentrantly from the lock callback.
class _OwnAiEpochAppLock extends AppLockController {
  _OwnAiEpochAppLock({
    required super.persistence,
    required super.auth,
    required this.invalidate,
  });
  final void Function() invalidate;
  @override
  void lock() {
    super.lock();
    invalidate();
  }
}

class _AttachmentDraft {
  const _AttachmentDraft({
    required this.picked,
    required this.name,
    required this.kind,
    required this.generation,
    required this.connection,
    required this.conversationId,
  });
  final PickedAttachment picked;
  final String name;
  final String kind;
  final int generation;
  final HostConnection connection;
  final String conversationId;
}

class _SyncInterrupted implements Exception {
  const _SyncInterrupted();
}

class _ReadInterrupted implements Exception {
  const _ReadInterrupted();
}

class _PreparedSnapshot {
  _PreparedSnapshot(
    this.storage,
    this.shell,
    this.consent,
    this.transport,
    this.chatEntered,
  );
  final FilePersistence storage;
  final ClientShellController shell;
  final ConversationConsentController consent;
  final HostConnection? transport;
  final bool chatEntered;
}
