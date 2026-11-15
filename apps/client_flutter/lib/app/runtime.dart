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
import '../platform/native_platform.dart';
import 'conversation_mapping.dart';
import 'shell_view_model.dart';

class ClientRuntime extends ShellViewModel with WidgetsBindingObserver {
  final native = NativePlatform();
  final authenticator = AccountAuthenticator();
  late Directory _dataRoot;
  late FilePersistence _settingsStorage;
  Future<void>? _refreshWork;
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
  bool _ready = false, _busy = false, _online = false, _onboarded = false;
  bool _controllersReady = false;
  String? _error, _selected, _preview;
  String _draft = '';
  @override
  bool get ready => _ready;
  @override
  bool get busy => _busy;
  @override
  bool get onboarded => _onboarded;
  @override
  String? get connectedAccountId => _credentials?.accountId;
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
      appLock = AppLockController(persistence: _settingsStorage, auth: native);
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
      final rotated = pending != null &&
              pending.generation == generation &&
              identical(pending.source, current)
          ? pending.rotated
          : await authenticator.refresh(current);
      if (!_current(generation) || !identical(_credentials, current)) {
        return false;
      }
      // The host already rotated its pair. Retain it in memory if protected
      // storage temporarily fails; refreshing the previous token cannot recover.
      _pendingRenewal = (generation: generation, source: current, rotated: rotated);
      if (!await _storeCredentials(rotated, generation, onboarded: _onboarded)) {
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
    } catch (_) {
      if (_current(generation)) {
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
      return _PreparedSnapshot(snapshot, next, nextConsent, transport);
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
    _controllersReady = true;
  }

  HostConnection? _submissionTransport;

  Future<void> _logout() async {
    final generation = ++_generation;
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
    _online = false;
    _conversations = [];
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_controllersReady) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
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
    final work = _performRefresh(connection!, shell, _generation);
    _refreshWork = work;
    return work.whenComplete(() {
      if (identical(_refreshWork, work)) _refreshWork = null;
    });
  }

  Future<void> _performRefresh(
    HostConnection sessionConnection,
    ClientShellController sessionShell,
    int generation,
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
      await sessionShell.flush();
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
      _credentials = credentials;
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
  Future<void> selectConversation(String id) async {
    _selected = id;
    _draft = shell.draftFor(id);
    notifyListeners();
  }

  @override
  void updateDraft(String value) {
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

class _PreparedSnapshot {
  _PreparedSnapshot(this.storage, this.shell, this.consent, this.transport);
  final FilePersistence storage;
  final ClientShellController shell;
  final ConversationConsentController consent;
  final HostConnection? transport;
}
