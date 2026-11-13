import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../data/file_persistence.dart';
import '../net/host_connection.dart';
import '../platform/native_platform.dart';
import 'conversation_mapping.dart';
import 'shell_view_model.dart';

class ClientRuntime extends ShellViewModel with WidgetsBindingObserver {
  final native = NativePlatform();
  late FilePersistence storage;
  late ClientShellController shell;
  late AppLockController appLock;
  late ConversationConsentController consent;
  PluginHost? plugins;
  HostConnection? connection;
  Timer? reconnect;
  Map<String, Object?> preferences = {};
  List<ShellConversation> _conversations = [];
  bool _ready = false,
      _busy = false,
      _online = false,
      _onboarded = false,
      _refreshing = false;
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
    WidgetsBinding.instance.addObserver(this);
    try {
      await native.invoke<Object?>('initialize');
      final directory = await native.invoke<String>('getDataDirectory');
      if (directory == null) throw const FileSystemException('本地目录不可用');
      storage = FilePersistence(File('$directory/client.json'));
      preferences =
          (await storage.read())['preferences'] as Map<String, Object?>? ?? {};
      appLock = AppLockController(persistence: storage, auth: native);
      consent = ConversationConsentController(storage);
      shell = ClientShellController(
        persistence: storage,
        submit: (item) async {
          if (connection == null) {
            return const Err(Failure(FailureCode.unavailable, '离线'));
          }
          return connection!.submit(
            OutboxSubmission(item.conversationId, {
              'clientMsgId': item.clientMsgId,
              'kind': item.kind.wire,
              'body': item.body,
            }),
          );
        },
        requestSync: (frame) async {
          await connection?.sync(frame, (message) async {
            await shell.acceptMessage(message);
          });
        },
      );
      await shell.initialize();
      await appLock.initialize();
      await consent.initialize();
      _controllersReady = true;
      final saved = await native.invoke<String>('readSession');
      if (saved != null) {
        final session = jsonDecode(saved) as Map<String, dynamic>;
        connection = HostConnection(
          Uri.parse(session['host'] as String),
          session['token'] as String,
        );
        _onboarded = session['onboarded'] == true;
      }
      NativePlatform.channel.setMethodCallHandler((call) async {
        if (call.method == 'event' &&
            (call.arguments as Map?)?['type'] == 'lock') {
          appLock.lock();
          notifyListeners();
        }
        if (call.method == 'event' &&
            (call.arguments as Map?)?['type'] == 'logout') {
          await connection?.close();
          connection = null;
          _onboarded = false;
          _online = false;
          _conversations = [];
          _selected = null;
          _draft = '';
          notifyListeners();
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
    } catch (error) {
      _error = '启动失败：$error';
      _ready = true;
    }
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
    if (_busy) return;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      await action();
    } catch (error) {
      _error = error.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _savePreferences() => writeClientSection(storage, 'preferences', {...preferences});

  Future<void> _refresh() async {
    if (connection == null || _refreshing) return;
    _refreshing = true;
    try {
      // `/host` is administrator-only on the current host. A friend client
      // legitimately receives 403; that must mean isHostMachine=false rather
      // than taking the whole shell offline.
      var isHostMachine = false;
      try {
        final info = await connection!.request('GET', Routes.hostInfo);
        isHostMachine = info['isHostMachine'] == true;
      } on HostRequestException catch (error) {
        if (error.failure.code != FailureCode.forbidden &&
            error.failure.code != FailureCode.unauthenticated) {
          rethrow;
        }
      }
      plugins ??= PluginHost(
        environment: PluginEnvironment(
          platform: Platform.isWindows ? 'windows' : 'android',
          isHostMachine: isHostMachine,
        ),
        sendText: (id, text) async {
          await shell.enqueue(id, MessageKind.text, {'text': text});
          await shell.flush();
        },
      );
      final list = await connection!.request('GET', Routes.conversations);
      final direct = await connection!.request(
        'GET',
        Routes.directConversations,
      );
      _conversations = mapConversations(
        groups: list['conversations'],
        directs: direct['conversations'],
      );
      _online = true;
      await shell.flush();
      for (final conversation in _conversations) {
        await connection!.sync(
          SyncRequestFrame(
            id: 'refresh-${conversation.id}',
            at: DateTime.now().toUtc(),
            conversationId: conversation.id,
            afterSeq: 0,
          ),
          (message) async {
            await shell.acceptMessage(message);
          },
        );
      }
      if (Platform.isAndroid) {
        await native.invoke<bool>('setForegroundService', {'enabled': true});
      }
    } catch (_) {
      _online = false;
    } finally {
      _refreshing = false;
    }
    notifyListeners();
  }

  @override
  Future<void> connectHost(String address, String invite) => _run(() async {
    // The host now exposes `auth/invites/redeem` and `auth/login`, but the
    // onboarding form only collects host + invite. Wiring real login needs the
    // display name / password / device-name fields plus account-scoped local
    // cache isolation, so connection stays fail-closed instead of attaching the
    // guest's local data to a half-formed session.
    throw const HttpException('客户端登录集成未完成：需要补充显示名/密码/设备名与账号分区缓存，暂不连接；已有本地数据保持不变');
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
    await shell.enqueue(_selected!, MessageKind.text, {'text': _draft});
    await shell.saveDraft(_selected!, '');
    _draft = '';
    if (_online) await shell.flush();
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
    reconnect?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(connection?.close());
    super.dispose();
  }
}
