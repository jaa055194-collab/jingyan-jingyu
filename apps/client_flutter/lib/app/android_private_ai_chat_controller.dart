// The constructor keeps its public named parameters separate from private
// state fields so callers cannot attach a different mutable store later.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:jingyu_core/jingyu_core.dart';

import 'android_private_ai_chat_port.dart';

typedef PrivateAiProfile = ({
  String profileId,
  String personaName,
  String personaText,
  int personaVersion,
  String? model,
  String? endpoint,
});
typedef PrivateAiSyncExchange = ({
  int seq,
  String exchangeId,
  String user,
  String assistant,
});
typedef _Exchange = ({String id, String user, String assistant, int? seq});

/// One Android route, one previously verified owner/device/AI vault scope.
/// This controller never uses the ordinary chat outbox or the host model.
final class AndroidPrivateAiChatController extends AndroidPrivateAiChatPort {
  AndroidPrivateAiChatController({
    required this.aiName,
    required Listenable session,
    required bool Function() isSessionCurrent,
    required bool Function() isHostOnline,
    required Future<Map<String, Object?>?> Function() read,
    required Future<void> Function(Map<String, Object?>) write,
    required Future<PrivateAiProfile> Function() loadProfile,
    Future<String?> Function(String)? loadBehavior,
    required Uri Function(String) parseEndpoint,
    required Future<String> Function(
      String endpoint,
      String model,
      String key,
      String persona,
      String text,
      List<({String user, String assistant})> history,
    )
    generate,
    required VoidCallback closeModel,
    required Future<({List<PrivateAiSyncExchange> items, bool hasMore})>
    Function(String profile, int after)
    list,
    required Future<int> Function(
      String profile,
      String id,
      String user,
      String assistant,
    )
    push,
  }) : _session = session,
       _current = isSessionCurrent,
       _hostOnline = isHostOnline,
       _read = read,
       _write = write,
       _loadProfile = loadProfile,
       _loadBehavior = loadBehavior,
       _parseEndpoint = parseEndpoint,
       _generate = generate,
       _closeModel = closeModel,
       _list = list,
       _push = push {
    _wasOnline = _hostOnline();
    session.addListener(_sessionChanged);
  }

  final Listenable _session;
  final bool Function() _current, _hostOnline;
  final Future<Map<String, Object?>?> Function() _read;
  final Future<void> Function(Map<String, Object?>) _write;
  final Future<PrivateAiProfile> Function() _loadProfile;
  final Future<String?> Function(String)? _loadBehavior;
  final Uri Function(String) _parseEndpoint;
  final Future<String> Function(
    String,
    String,
    String,
    String,
    String,
    List<({String user, String assistant})>,
  )
  _generate;
  final VoidCallback _closeModel;
  final Future<({List<PrivateAiSyncExchange> items, bool hasMore})> Function(
    String,
    int,
  )
  _list;
  final Future<int> Function(String, String, String, String) _push;

  static const _limit = 48;
  static const _userBytes = 4096;
  static const _assistantBytes = 8192;
  static final _random = Random.secure();
  bool _busy = false, _initialized = false, _invalid = false, _disposed = false;
  late bool _wasOnline;
  String? _notice;
  var _saved = const _PrivateAiRecord();

  @override
  final String aiName;
  @override
  bool get isCurrent => !_disposed && !_invalid && _current();
  @override
  bool get busy => _busy;
  @override
  bool get initialized => _initialized && isCurrent;
  @override
  bool get online => isCurrent && _hostOnline();
  @override
  String? get model => isCurrent ? _saved.model : null;
  @override
  String? get endpoint => isCurrent ? _saved.endpoint : null;
  @override
  String? get personaName => isCurrent ? _saved.personaName : null;
  @override
  String? get personaText => isCurrent ? _saved.personaText : null;
  @override
  int? get personaVersion => isCurrent ? _saved.personaVersion : null;
  @override
  String? get behaviorSnapshot => isCurrent ? _saved.behaviorSnapshot : null;
  @override
  String? get notice => isCurrent ? _notice : null;
  @override
  bool get keyConfigured => isCurrent && _saved.key != null;
  @override
  bool get syncEnabled => isCurrent && _saved.syncEnabled;
  @override
  List<PrivateAiExchange> get exchanges => isCurrent
      ? List.unmodifiable([
          for (final item in _saved.exchanges)
            (user: item.user, assistant: item.assistant, seq: item.seq),
        ])
      : const [];

  void _sessionChanged() {
    if (_disposed || _invalid) return;
    if (!_current()) {
      _invalid = true;
      _saved = const _PrivateAiRecord();
      _closeModel();
      notifyListeners();
      return;
    }
    final reconnect = !_wasOnline && online;
    _wasOnline = online;
    notifyListeners();
    if (reconnect) _autoSync();
  }

  void _autoSync() {
    if (initialized &&
        online &&
        syncEnabled &&
        _saved.profileId != null &&
        !_busy) {
      unawaited(sync());
    }
  }

  Future<bool> _action(
    Future<bool> Function() action, {
    required String failure,
    bool requireInitialized = true,
  }) async {
    if (!isCurrent || _busy || (requireInitialized && !_initialized)) {
      return false;
    }
    _busy = true;
    _notice = null;
    notifyListeners();
    try {
      if (!isCurrent) return false;
      return await action();
    } catch (_) {
      if (isCurrent) _notice = failure;
      return false;
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> initialize() async {
    await _action(
      () async {
        final json = await _read();
        if (!isCurrent) return false;
        if (json != null) {
          _saved = _PrivateAiRecord.decode(json, _parseEndpoint);
        }
        _initialized = true;
        return true;
      },
      failure: '无法读取这台手机保存的私聊数据。请返回后重试。',
      requireInitialized: false,
    );
    _autoSync();
  }

  Future<bool> _save(_PrivateAiRecord next) async {
    if (!isCurrent) return false;
    final record = next.toJson();
    if (utf8.encode(jsonEncode(record)).length > 1024 * 1024) {
      return _reject('本机私聊数据达到空间上限，这次未保存；已有记录不会丢失。');
    }
    await _write(record);
    if (!isCurrent) return false;
    _saved = next;
    return true;
  }

  bool _reject(String notice) {
    if (isCurrent) _notice = notice;
    return false;
  }

  @override
  Future<bool> loadHostProfile() => _action(() async {
    if (!online) return _reject('请先连接宿主，再读取 AI 档案。');
    final profile = await _loadProfile();
    if (!isCurrent || !online) return false;
    validateId(profile.profileId);
    if (!_text(profile.personaName, 512) ||
        !_text(profile.personaText, 48 * 1024) ||
        profile.personaVersion < 1) {
      return _reject('宿主没有返回可用的人格。请先在 AI 配置中填写人格。');
    }
    if (_saved.profileId != null && _saved.profileId != profile.profileId) {
      return _reject('AI 档案已变更，旧私聊不会自动转移到新档案。');
    }
    final behavior = await _loadBehavior?.call(profile.profileId);
    if (!isCurrent || !online) return false;
    return _save(
      _PrivateAiRecord(
        profileId: profile.profileId,
        personaName: profile.personaName,
        personaText: profile.personaText,
        personaVersion: profile.personaVersion,
        behaviorSnapshot: behavior != null && _text(behavior, 4096)
            ? behavior
            : _saved.behaviorSnapshot,
        model: _saved.model ?? profile.model,
        endpoint: _saved.endpoint ?? profile.endpoint,
        key: _saved.key,
        after: _saved.after,
        exchanges: _saved.exchanges,
        syncEnabled: _saved.syncEnabled,
      ),
    );
  }, failure: '无法读取本人 AI 的人格。请检查宿主、账号归属和人格是否已配置。');

  @override
  Future<bool> configure({
    required String endpoint,
    required String model,
    String? apiKey,
  }) => _action(() async {
    final String url;
    try {
      url = _parseEndpoint(endpoint.trim()).toString();
    } on FormatException {
      return _reject('请输入以 /chat/completions 结尾的 HTTPS API 地址。');
    }
    final selectedModel = model.trim();
    if (!_text(selectedModel, 256) || _control.hasMatch(selectedModel)) {
      return _reject('请输入有效的模型名称。');
    }
    final key = apiKey == null || apiKey.isEmpty
        ? (url == _saved.endpoint ? _saved.key : null)
        : apiKey;
    if (key == null ||
        key.isEmpty ||
        key.length > 4096 ||
        key.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
      return _reject('请为此 API 地址填写有效密钥。更换地址需要重新输入。');
    }
    if (url.contains(key) || selectedModel.contains(key)) {
      return _reject('请不要把密钥写入 API 地址或模型名称。');
    }
    return _save(_saved.withModel(selectedModel, url, key));
  }, failure: '无法在手机上保存模型设置。');

  @override
  Future<bool> send(String text) async {
    final sent = await _action(() async {
      final record = _saved;
      final url = record.endpoint;
      final model = record.model;
      final key = record.key;
      final persona = record.personaText;
      if (url == null || model == null || key == null || persona == null) {
        return _reject('请先读取人格并设置手机的模型和 API 密钥。');
      }
      if (!_text(text, _userBytes) || text.contains(key)) {
        return _reject('消息为空、过长或包含密钥，未发送。');
      }
      if (record.exchanges.where((item) => item.seq == null).length == _limit) {
        return _reject('本机待同步记录已满。连接宿主并同步后可继续私聊。');
      }
      final tail = record.exchanges.reversed.take(5).toList().reversed;
      final answer = await _generate(url, model, key, persona, text, [
        for (final turn in tail) (user: turn.user, assistant: turn.assistant),
      ]);
      if (!isCurrent) return false;
      if (!_text(answer, _assistantBytes) || answer.contains(key)) {
        return _reject('模型返回了无效内容，未保存；输入仍可重试。');
      }
      final id = List.generate(
        16,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      return _save(
        record.withHistory([
          ...record.exchanges,
          (id: id, user: text, assistant: answer, seq: null),
        ], record.after),
      );
    }, failure: '未能完成私聊。请检查模型、密钥及模型服务的网络连接。');
    if (sent) _autoSync();
    return sent;
  }

  @override
  Future<void> setSyncEnabled(bool enabled) async {
    await _action(() async {
      if (enabled && _saved.profileId == null) {
        return _reject('请先读取本人 AI 档案，再开启同步。');
      }
      return _save(_saved.withSync(enabled));
    }, failure: '无法保存同步设置。');
  }

  @override
  Future<void> sync() async {
    if (!isCurrent) return;
    await _action(() async {
      if (!online || !syncEnabled) {
        return _reject('同步已关闭或宿主未连接；本机记录会保留。');
      }
      final profile = _saved.profileId;
      if (profile == null) return _reject('请先读取本人 AI 档案，再同步记录。');
      bool canSync() => isCurrent && online && syncEnabled;
      for (final item in _saved.exchanges.where((item) => item.seq == null)) {
        if (!canSync()) return false;
        final key = _saved.key;
        if (key != null &&
            (item.user.contains(key) || item.assistant.contains(key))) {
          return _reject('有记录包含当前密钥，未同步。');
        }
        final seq = await _push(profile, item.id, item.user, item.assistant);
        if (!canSync()) return false;
        if (seq < 1 ||
            _saved.exchanges.any(
              (old) => old.seq == seq && old.id != item.id,
            )) {
          throw const FormatException();
        }
        if (!await _save(
          _saved.withHistory([
            for (final old in _saved.exchanges)
              if (old.id == item.id)
                (id: old.id, user: old.user, assistant: old.assistant, seq: seq)
              else
                old,
          ], _saved.after),
        )) {
          return false;
        }
      }
      // Do not advance the download cursor to a POST receipt: there may be
      // earlier turns from another Android device between that ACK and the head.
      for (var page = 0; page < 3; page++) {
        if (!canSync()) return false;
        var after = _saved.after;
        final result = await _list(profile, after);
        if (!canSync()) return false;
        final rows = {for (final item in _saved.exchanges) item.id: item};
        for (final item in result.items) {
          if (item.seq != after + 1 ||
              !_text(item.user, _userBytes) ||
              !_text(item.assistant, _assistantBytes)) {
            throw const FormatException();
          }
          after = item.seq;
          final old = rows[item.exchangeId];
          if (old != null &&
              (old.user != item.user ||
                  old.assistant != item.assistant ||
                  (old.seq != null && old.seq != item.seq))) {
            throw const FormatException();
          }
          rows[item.exchangeId] = (
            id: item.exchangeId,
            user: item.user,
            assistant: item.assistant,
            seq: item.seq,
          );
        }
        if (result.items.isNotEmpty &&
            !await _save(_saved.withHistory(rows.values.toList(), after))) {
          return false;
        }
        if (!result.hasMore) {
          _notice = '私聊记录已同步。';
          return true;
        }
      }
      _notice = '已同步部分记录，可继续同步。';
      return true;
    }, failure: '同步未确认。记录仍保存在手机；可重新同步，不会重新生成回复。');
  }

  static final _control = RegExp(r'[\x00-\x1f\x7f-\x9f]');
  static bool _text(String text, int limit) =>
      text.length <= limit &&
      text.trim().isNotEmpty &&
      !text.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff) &&
      utf8.encode(text).length <= limit;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _session.removeListener(_sessionChanged);
    _saved = const _PrivateAiRecord();
    _closeModel();
    super.dispose();
  }
}

class _PrivateAiRecord {
  const _PrivateAiRecord({
    this.profileId,
    this.personaName,
    this.personaText,
    this.personaVersion,
    this.behaviorSnapshot,
    this.model,
    this.endpoint,
    this.key,
    this.syncEnabled = false,
    this.after = 0,
    this.exchanges = const [],
  });

  final String? profileId,
      personaName,
      personaText,
      behaviorSnapshot,
      model,
      endpoint,
      key;
  final int? personaVersion;
  final bool syncEnabled;
  final int after;
  final List<_Exchange> exchanges;

  _PrivateAiRecord withModel(String model, String endpoint, String key) =>
      _PrivateAiRecord(
        profileId: profileId,
        personaName: personaName,
        personaText: personaText,
        personaVersion: personaVersion,
        behaviorSnapshot: behaviorSnapshot,
        model: model,
        endpoint: endpoint,
        key: key,
        after: after,
        exchanges: exchanges,
        syncEnabled: syncEnabled,
      );

  _PrivateAiRecord withSync(bool enabled) => _PrivateAiRecord(
    profileId: profileId,
    personaName: personaName,
    personaText: personaText,
    personaVersion: personaVersion,
    behaviorSnapshot: behaviorSnapshot,
    model: model,
    endpoint: endpoint,
    key: key,
    after: after,
    exchanges: exchanges,
    syncEnabled: enabled,
  );

  _PrivateAiRecord withHistory(List<_Exchange> rows, int after) {
    final synced = rows.where((item) => item.seq != null).toList()
      ..sort((a, b) => a.seq!.compareTo(b.seq!));
    final pending = rows.where((item) => item.seq == null).toList();
    return _PrivateAiRecord(
      profileId: profileId,
      personaName: personaName,
      personaText: personaText,
      personaVersion: personaVersion,
      behaviorSnapshot: behaviorSnapshot,
      model: model,
      endpoint: endpoint,
      key: key,
      after: after,
      exchanges: [
        ...synced.reversed
            .take(AndroidPrivateAiChatController._limit - pending.length)
            .toList()
            .reversed,
        ...pending,
      ],
      syncEnabled: syncEnabled,
    );
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'profileId': profileId,
    'personaName': personaName,
    'personaText': personaText,
    'personaVersion': personaVersion,
    'behaviorSnapshot': behaviorSnapshot,
    'model': model,
    'endpoint': endpoint,
    'key': key,
    'after': after,
    'syncEnabled': syncEnabled,
    'exchanges': [
      for (final item in exchanges)
        {
          'id': item.id,
          'user': item.user,
          'assistant': item.assistant,
          'seq': item.seq,
        },
    ],
  };

  static _PrivateAiRecord decode(
    Map<String, Object?> data,
    Uri Function(String) parseEndpoint,
  ) {
    final profile = data['profileId'] as String?;
    if (profile != null) validateId(profile);
    final endpoint = data['endpoint'] as String?;
    if (endpoint != null && parseEndpoint(endpoint).toString() != endpoint) {
      throw const FormatException();
    }
    final after = data['after'];
    final raw = data['exchanges'];
    if (data['version'] != 1 ||
        after is! int ||
        after < 0 ||
        data['syncEnabled'] is! bool ||
        raw is! List ||
        raw.length > AndroidPrivateAiChatController._limit) {
      throw const FormatException();
    }
    final ids = <String>{};
    final seqs = <int>{};
    final rows = <_Exchange>[];
    for (final value in raw) {
      if (value is! Map) throw const FormatException();
      final id = value['id'] as String;
      final user = value['user'] as String;
      final assistant = value['assistant'] as String;
      final seq = value['seq'] as int?;
      validateId(id);
      if (!ids.add(id) || (seq != null && (seq < 1 || !seqs.add(seq)))) {
        throw const FormatException();
      }
      rows.add((id: id, user: user, assistant: assistant, seq: seq));
    }
    return _PrivateAiRecord(
      profileId: profile,
      personaName: data['personaName'] as String?,
      personaText: data['personaText'] as String?,
      personaVersion: data['personaVersion'] as int?,
      behaviorSnapshot: data['behaviorSnapshot'] as String?,
      model: data['model'] as String?,
      endpoint: endpoint,
      key: data['key'] as String?,
      after: after,
      syncEnabled: data['syncEnabled'] as bool,
      exchanges: rows,
    );
  }
}
