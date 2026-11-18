import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../data/file_persistence.dart';
import '../data/account_snapshots.dart';
import '../net/account_auth.dart';
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
  bool _refreshFlushesOutbox = true;
  Future<bool>? _renewWork;
  Future<void> _secureTail = Future<void>.value();
  ClientCredentials? _credentials;
  ({int generation, ClientCredentials source, ClientCredentials rotated})?
  _pendingRenewal;
  int _generation = 0;
  bool _disposed = false;
  bool _switching = false;
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
  @override
  String? get selectedConversationId => _selected;
  @override
  List<ShellConversation> get conversations => _conversations;
  @override
  List<ShellMessage> get messages => _selected == null
      ? []
      : [
          for (final message in shell.messagesFor(_selected!))
            ShellMessage(
              id: message.messageId,
              text:
                  message.body['text']?.toString() ?? '[${message.kind.wire}]',
            ),
          for (final item in shell.outbox.items.where(
            (e) => e.conversationId == _selected,
          ))
            ShellMessage(
              id: item.clientMsgId,
              text: item.body['text']?.toString() ?? '[${item.kind.wire}]',
              outgoing: true,
              status: '等待补传',
            ),
          for (final drop in shell.dropped.where(
            (e) => e.item.conversationId == _selected,
          ))
            ShellMessage(
              id: drop.item.clientMsgId,
              text: drop.item.body['text']?.toString() ?? '',
              outgoing: true,
              status: '发送失败',
            ),
        ];
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
    try {
      await native.invoke<Object?>('initialize');
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
        invalidate: _invalidateOwnAiDirect,
      );
      await appLock.initialize();
      final guest = await _prepareSnapshot(
        FilePersistence(File('$directory/guest.json')),
        null,
        generation,
      );
      if (!_current(generation)) return;
      _publishSnapshot(guest);
      final saved = await native.invoke<String>('readSession');
      if (saved != null) {
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
          _credentials = credentials;
          _publishSnapshot(prepared);
          connection = _newConnection(credentials, generation);
          _onboarded = decoded['onboarded'] == true;
          _chatEntered = _chatEntered || _onboarded;
        } on FormatException {
          // Old unscoped credentials are not paired with private legacy data.
          _error = '旧登录记录缺少账号或设备身份，请重新登录；本地旧数据保持不变';
        }
      }
      if (!_current(generation)) return;
      NativePlatform.channel.setMethodCallHandler((call) async {
        if (_disposed) return;
        if (call.method == 'event' &&
            (call.arguments as Map?)?['type'] == 'lock') {
          appLock.lock();
          notifyListeners();
        }
        if (call.method == 'event' &&
            (call.arguments as Map?)?['type'] == 'logout') {
          await _logout();
        }
        if (call.method == 'shareReceived') {
          final data = call.arguments as Map;
          if (_selected != null) {
            _draftRevisions.update(
              _selected!,
              (revision) => revision + 1,
              ifAbsent: () => 1,
            );
          }
          _draft = data['text']?.toString() ?? '';
          if (_selected != null) await shell.saveDraft(_selected!, _draft);
          notifyListeners();
        }
      });
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
      _pendingRenewal = null;
      connection?.updateAccessToken(rotated.accessToken);
      _submissionTransport?.updateAccessToken(rotated.accessToken);
      return true;
    } catch (error) {
      if (_current(generation)) {
        if (error is HostRequestException &&
            error.failure.code == FailureCode.unauthenticated) {
          _sessionRejected = true;
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
        if (!_current(generation)) return;
        await transport?.sync(frame, (message) async {
          if (_current(generation)) await next.acceptMessage(message);
        });
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
    _selected = null;
    _draft = '';
    appLock.lock();
    notifyListeners();
    final clear = _secureOperation(() => native.invoke<void>('clearSession'));
    await Future.wait<void>([
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

  Future<void> _refresh({bool flushOutbox = true}) {
    if (_disposed || connection == null || _switching || locked) {
      return Future<void>.value();
    }
    final active = _refreshWork;
    final generation = _generation;
    if (active != null) {
      if (!flushOutbox || _refreshFlushesOutbox) return active;
      // A normal refresh requested during a read-only refresh must still
      // flush, but must not inherit work from an account that has since left.
      return active.then<void>((_) async {
        if (_current(generation)) await _refresh();
      });
    }
    _refreshFlushesOutbox = flushOutbox;
    late final Future<void> work;
    work =
        _performRefresh(
          connection!,
          shell,
          generation,
          flushOutbox: flushOutbox,
        ).whenComplete(() {
          if (identical(_refreshWork, work)) _refreshWork = null;
        });
    _refreshWork = work;
    return work;
  }

  Future<void> _performRefresh(
    HostConnection sessionConnection,
    ClientShellController sessionShell,
    int generation, {
    required bool flushOutbox,
  }) async {
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
      if (!_current(generation)) return;
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
      final direct = await sessionConnection.request(
        'GET',
        Routes.directConversations,
      );
      if (!_current(generation) || locked) return;
      final conversations = mapConversations(
        groups: list['conversations'],
        directs: direct['conversations'],
      );
      _conversations = conversations;
      _online = true;
      if (flushOutbox) await sessionShell.flush();
      for (final conversation in conversations) {
        if (!_current(generation) || locked) return;
        await sessionConnection.sync(
          SyncRequestFrame(
            id: 'refresh-${conversation.id}',
            at: DateTime.now().toUtc(),
            conversationId: conversation.id,
            afterSeq: sessionShell.lastSeqFor(conversation.id),
          ),
          (message) async {
            if (_current(generation)) await sessionShell.acceptMessage(message);
          },
        );
      }
      if (_current(generation) && Platform.isAndroid) {
        await native.invoke<bool>('setForegroundService', {'enabled': true});
      }
    } catch (_) {
      if (_current(generation)) _online = false;
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
      _selected = null;
      _draft = '';
      _conversations = [];
      _ownAiAccounts = [];
      _ownAiNotice = null;
      _ownAiLoaded = false;
      await Future.wait<void>([
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
  Future<bool> refreshForOwnAiChat() async {
    if (_busy ||
        !authenticated ||
        !online ||
        _sessionRejected ||
        locked ||
        _switching ||
        _disposed ||
        connection == null ||
        _refreshWork != null) {
      return false;
    }
    final generation = _generation;
    await _refresh(flushOutbox: false);
    return _current(generation) && authenticated && online && !locked;
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
    _selected = id;
    _draft = shell.draftFor(id);
    notifyListeners();
  }

  @override
  void updateDraft(String value) {
    if (_selected != null) {
      _draftRevisions.update(
        _selected!,
        (revision) => revision + 1,
        ifAbsent: () => 1,
      );
    }
    _draft = value;
    notifyListeners();
    if (_selected != null) {
      unawaited(
        shell.saveDraft(_selected!, value).catchError((Object e) {
          _error = '草稿保存失败';
          notifyListeners();
        }),
      );
    }
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
    await sessionShell.enqueue(selected, MessageKind.text, {'text': text});
    await sessionShell.saveDraft(selected, '');
    if (!_current(generation)) return;
    if (_selected == selected && _draft == text) _draft = '';
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
  Future<void> attachFile(String kind) => _run(() async {
    throw const FileSystemException('附件上传接口尚未提供，内容未发送');
  });
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
    if (!await appLock.unlockWithPin(pin)) {
      throw const FormatException('PIN 不正确');
    }
    if (connection != null) unawaited(_refresh());
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
    ++_generation;
    _invalidateOwnAiDirect();
    _pendingMention = null;
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
