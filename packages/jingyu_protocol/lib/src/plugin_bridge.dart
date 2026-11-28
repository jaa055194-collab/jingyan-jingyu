/// WebView 插件的 JSON-RPC 2.0 能力桥协议。
///
/// 与 `jingyu_protocol` 既有线协议帧相互独立：本文件只负责插件桥消息的
/// 严格编解码，以及方法 / scope / slot 目录。
///
/// 原则：所有解析失败一律返回 [Result] 的 [FailureCode.invalidArgument]，
/// 绝不返回"尽力而为"的半成品，也不抛出未受控异常。
library;

import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';

/// 插件桥协议版本。
const int pluginBridgeProtocolVersion = 1;

/// 插件桥消息限制。
class PluginBridgeLimits {
  const PluginBridgeLimits({
    this.maxBytes = 256 * 1024,
    this.maxDepth = 32,
    this.maxIdLength = 128,
    this.maxMethodLength = 128,
    this.maxStringLength = 64 * 1024,
  });

  /// 单条消息 UTF-8 字节上限。
  final int maxBytes;

  /// JSON 嵌套深度上限（顶层对象算第 1 层）。
  final int maxDepth;

  /// 请求 / 响应 id 的字符串长度上限。
  final int maxIdLength;

  /// 方法名长度上限。
  final int maxMethodLength;

  /// 请求参数内所有字符串的总长度上限（递归统计键与值）。
  final int maxStringLength;
}

/// 插件桥错误码：JSON-RPC 2.0 标准码 + 桥扩展码。
enum PluginBridgeErrorCode {
  /// JSON 解析失败。
  parseError(-32700),

  /// 请求对象不合法。
  invalidRequest(-32600),

  /// 方法不存在。
  methodNotFound(-32601),

  /// 参数不合法。
  invalidParams(-32602),

  /// 宿主内部错误。
  internalError(-32603),

  /// 权限 scope 不足。
  permissionDenied(-32001),

  /// 消息超过大小限制。
  messageTooLarge(-32002),

  /// 触发限流。
  rateLimited(-32003),

  /// 调用超时。
  timeout(-32004),

  /// 沙箱不可用。
  sandboxUnavailable(-32005);

  const PluginBridgeErrorCode(this.code);

  /// JSON-RPC 错误码数值。
  final int code;
}

/// 插件桥消息：请求 / 通知 / 成功响应 / 失败响应。
sealed class PluginBridgeMessage {
  const PluginBridgeMessage();

  /// 序列化为 JSON-RPC 2.0 对象。
  Map<String, Object?> toJson();
}

/// 插件发往宿主的请求（需要响应）。
final class PluginBridgeRequest extends PluginBridgeMessage {
  const PluginBridgeRequest({
    required this.id,
    required this.method,
    this.params = const <String, Object?>{},
  });

  /// 请求 id：int 或非空 String。
  final Object id;

  /// 方法名（点分格式）。
  final String method;

  /// 参数对象。
  final Map<String, Object?> params;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    'params': params,
  };
}

/// 插件或宿主发出的通知（不需要响应）。
final class PluginBridgeNotification extends PluginBridgeMessage {
  const PluginBridgeNotification({
    required this.method,
    this.params = const <String, Object?>{},
  });

  /// 方法名（点分格式）。
  final String method;

  /// 参数对象。
  final Map<String, Object?> params;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'jsonrpc': '2.0',
    'method': method,
    'params': params,
  };
}

/// 成功响应。
final class PluginBridgeSuccess extends PluginBridgeMessage {
  const PluginBridgeSuccess({required this.id, this.result});

  /// 对应请求的 id。
  final Object id;

  /// 成功结果（可为 null）。
  final Object? result;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  };
}

/// 失败响应。
final class PluginBridgeFailure extends PluginBridgeMessage {
  const PluginBridgeFailure({
    this.id,
    required this.code,
    required this.message,
    this.data,
  });

  /// 对应请求的 id；仅解析错误（parse error）允许为 null。
  final Object? id;

  /// 错误码。
  final PluginBridgeErrorCode code;

  /// 面向开发者的错误说明。
  final String message;

  /// 可选的机器可读附加数据。
  final Object? data;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'jsonrpc': '2.0',
    'id': id,
    'error': <String, Object?>{
      'code': code.code,
      'message': message,
      if (data != null) 'data': data,
    },
  };
}

/// 从 JSON 文本解码插件桥消息。
///
/// 顺序严格固定：先按 UTF-8 字节数检查 [PluginBridgeLimits.maxBytes]，
/// 再在未解析的 JSON 文本上检查嵌套深度（字符串字面量内的括号不计数），
/// 最后才 `jsonDecode` 并做结构校验。
Result<PluginBridgeMessage> decodePluginBridgeJson(
  String raw, {
  PluginBridgeLimits limits = const PluginBridgeLimits(),
}) {
  try {
    final byteLength = utf8.encode(raw).length;
    if (byteLength > limits.maxBytes) {
      return err<PluginBridgeMessage>(
        FailureCode.invalidArgument,
        '插件桥消息超过字节上限：$byteLength > ${limits.maxBytes}',
      );
    }
    if (!_jsonTextDepthWithin(raw, limits.maxDepth)) {
      return err<PluginBridgeMessage>(
        FailureCode.invalidArgument,
        '插件桥消息嵌套深度超过上限 ${limits.maxDepth}',
      );
    }
    final Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException catch (error) {
      return err<PluginBridgeMessage>(
        FailureCode.invalidArgument,
        'JSON 解析失败：${error.message}',
      );
    }
    return decodePluginBridgeMessage(parsed, limits: limits);
  } on Object catch (error) {
    return err<PluginBridgeMessage>(
      FailureCode.invalidArgument,
      '插件桥消息解析失败：$error',
    );
  }
}

/// 从已解析的 JSON 值解码插件桥消息。
///
/// 与 [decodePluginBridgeJson] 使用同一套严格结构规则，便于已持有对象
/// （例如测试或宿主内部）复用；同样不抛未受控异常。
Result<PluginBridgeMessage> decodePluginBridgeMessage(
  Object? json, {
  PluginBridgeLimits limits = const PluginBridgeLimits(),
}) {
  try {
    return Ok<PluginBridgeMessage>(_decodeMessage(json, limits));
  } on _PluginBridgeFormatException catch (error) {
    return err<PluginBridgeMessage>(FailureCode.invalidArgument, error.message);
  } on Object catch (error) {
    return err<PluginBridgeMessage>(
      FailureCode.invalidArgument,
      '插件桥消息解析失败：$error',
    );
  }
}

/// 编码插件桥消息为 JSON 文本。
String encodePluginBridgeMessage(PluginBridgeMessage message) =>
    jsonEncode(message.toJson());

/// 插件桥方法描述。
class PluginBridgeMethod {
  const PluginBridgeMethod(this.name, this.scope, this.description);

  /// 方法名。
  final String name;

  /// 所需权限 scope。
  final String scope;

  /// 方法说明。
  final String description;
}

/// 插件桥方法 / scope / slot 目录（v3 §3、§5）。
abstract final class PluginBridgeApi {
  /// v3 §5 全部能力桥方法。
  static const List<PluginBridgeMethod> methods = <PluginBridgeMethod>[
    PluginBridgeMethod('host.getInfo', 'host', '读取宿主版本、平台与能力信息'),
    PluginBridgeMethod('host.log', 'host', '写入宿主日志'),
    PluginBridgeMethod('host.openExternal', 'host', '在系统浏览器打开白名单外链'),
    PluginBridgeMethod('chat.sendText', 'chat.send', '以当前用户身份发送文本消息'),
    PluginBridgeMethod('chat.sendCard', 'chat.send', '以当前用户身份发送卡片消息'),
    PluginBridgeMethod('chat.listConversations', 'chat.read', '列出当前用户可见的会话'),
    PluginBridgeMethod('message.recent', 'message.read', '读取会话最近消息'),
    PluginBridgeMethod('message.get', 'message.read', '按 id 读取单条消息'),
    PluginBridgeMethod('message.onMessage', 'message.events', '订阅新消息事件'),
    PluginBridgeMethod('model.invoke', 'model.invoke', '调用宿主模型能力（计入 AI 预算）'),
    PluginBridgeMethod('storage.get', 'storage', '读取插件私有存储键'),
    PluginBridgeMethod('storage.set', 'storage', '写入插件私有存储键'),
    PluginBridgeMethod('storage.remove', 'storage', '删除插件私有存储键'),
    PluginBridgeMethod('storage.keys', 'storage', '列出插件私有存储键'),
    PluginBridgeMethod('ui.registerSlot', 'ui.slot', '向命名插槽注册 UI 内容'),
    PluginBridgeMethod('ui.setTitle', 'ui.chrome', '设置插件页标题'),
    PluginBridgeMethod('ui.close', 'ui.chrome', '关闭插件页'),
    PluginBridgeMethod('ui.toast', 'ui.chrome', '显示轻提示'),
    PluginBridgeMethod('world.getLayout', 'world.read', '读取 3D 世界 / 房间布局'),
    PluginBridgeMethod('world.setLayout', 'world.write', '保存 3D 世界 / 房间布局'),
    PluginBridgeMethod('world.onPresence', 'world.events', '订阅世界 presence 事件'),
    PluginBridgeMethod('events.on', 'events', '订阅宿主事件'),
    PluginBridgeMethod('events.off', 'events', '取消订阅宿主事件'),
    PluginBridgeMethod('commands.registerSlash', 'commands', '注册斜杠指令'),
    PluginBridgeMethod('settings.read', 'config', '读取插件配置'),
    PluginBridgeMethod('settings.write', 'config', '写入插件配置'),
    PluginBridgeMethod('notify.notify', 'notify', '发送本地通知'),
  ];

  /// scope 常量表：逻辑名 -> 线协议 scope 字符串。
  static const Map<String, String> scopes = <String, String>{
    'host': 'host',
    'chatSend': 'chat.send',
    'chatRead': 'chat.read',
    'messageRead': 'message.read',
    'messageEvents': 'message.events',
    'modelInvoke': 'model.invoke',
    'storage': 'storage',
    'uiSlot': 'ui.slot',
    'uiChrome': 'ui.chrome',
    'worldRead': 'world.read',
    'worldWrite': 'world.write',
    'worldEvents': 'world.events',
    'events': 'events',
    'commands': 'commands',
    'config': 'config',
    'notify': 'notify',
  };

  /// v3 §3 的全部静态 slot key；消息卡片另有动态前缀。
  static const List<String> slotKeys = <String>[
    'shell.sidebar.entry',
    'shell.overlay',
    'conversation.composer.actions',
    'conversation.composer.dock',
    'conversation.row.decoration',
    'conversation.header.utilities',
    'settings.section',
    'settings.plugin.config',
    'page.plugin',
    'world.overlay',
    'room.furniture',
    'commands.slash',
    'notification.action',
  ];

  /// 动态消息卡片 slot 前缀。
  static const String _messageCardSlotPrefix = 'conversation.message.card.';

  /// 按名查找方法；未知方法返回 null。
  static PluginBridgeMethod? method(String name) {
    for (final method in methods) {
      if (method.name == name) return method;
    }
    return null;
  }

  /// 是否为已知 slot。
  ///
  /// `conversation.message.card.` 前缀允许任意非空后缀（自定义卡片类型）。
  static bool isKnownSlot(String slot) {
    if (slotKeys.contains(slot)) return true;
    return slot.startsWith(_messageCardSlotPrefix) &&
        slot.length > _messageCardSlotPrefix.length;
  }
}

/// 内部格式错误：只在解码函数内部抛出，由公开 API 统一转成 [Result]。
final class _PluginBridgeFormatException implements Exception {
  const _PluginBridgeFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

Never _fail(String message) => throw _PluginBridgeFormatException(message);

final RegExp _methodPattern = RegExp(r'^[a-z][a-zA-Z0-9]*(\.[a-zA-Z0-9_]+)+$');

PluginBridgeMessage _decodeMessage(Object? json, PluginBridgeLimits limits) {
  final map = _requireObject(json, '消息');
  _validateJsonValue(map, limits);

  if (map['jsonrpc'] != '2.0') {
    _fail('jsonrpc 必须等于 "2.0"');
  }

  if (map.containsKey('method')) {
    if (map.containsKey('result') || map.containsKey('error')) {
      _fail('请求 / 通知不能同时包含 result 或 error');
    }
    final method = _requireMethod(map['method'], limits);
    final params = _decodeParams(map, limits);
    if (map.containsKey('id')) {
      _rejectUnknownFields(map, const <String>{
        'jsonrpc',
        'id',
        'method',
        'params',
      });
      final id = _requireId(map['id'], limits);
      _checkStringBudget(params, limits.maxStringLength);
      return PluginBridgeRequest(id: id, method: method, params: params);
    }
    _rejectUnknownFields(map, const <String>{'jsonrpc', 'method', 'params'});
    _checkStringBudget(params, limits.maxStringLength);
    return PluginBridgeNotification(method: method, params: params);
  }

  if (map.containsKey('error')) {
    _rejectUnknownFields(map, const <String>{'jsonrpc', 'id', 'error'});
    final error = _requireObject(map['error'], 'error');
    _rejectUnknownFields(error, const <String>{'code', 'message', 'data'});
    final rawCode = error['code'];
    if (rawCode is! int) {
      _fail('error.code 必须是整数');
    }
    final code = _errorCodeOf(rawCode);
    if (code == null) {
      _fail('未知的插件桥错误码 $rawCode');
    }
    final rawMessage = error['message'];
    if (rawMessage is! String) {
      _fail('error.message 必须是字符串');
    }
    if (!map.containsKey('id')) {
      _fail('失败响应缺少 id');
    }
    final Object? id;
    final rawId = map['id'];
    if (rawId == null) {
      if (code != PluginBridgeErrorCode.parseError) {
        _fail('只有 parse error 允许 id 为 null');
      }
      id = null;
    } else {
      id = _requireId(rawId, limits);
    }
    return PluginBridgeFailure(
      id: id,
      code: code,
      message: rawMessage,
      data: error['data'],
    );
  }

  if (map.containsKey('result')) {
    _rejectUnknownFields(map, const <String>{'jsonrpc', 'id', 'result'});
    if (!map.containsKey('id')) {
      _fail('成功响应缺少 id');
    }
    return PluginBridgeSuccess(
      id: _requireId(map['id'], limits),
      result: map['result'],
    );
  }

  _fail('无法识别的插件桥消息：既不是请求 / 通知，也不是成功 / 失败响应');
}

Map<String, Object?> _requireObject(Object? value, String field) {
  if (value is! Map<Object?, Object?>) {
    _fail('$field 必须是 JSON 对象');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      _fail('$field 的键必须是字符串');
    }
    result[key] = entry.value;
  }
  return result;
}

void _rejectUnknownFields(Map<String, Object?> map, Set<String> allowed) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      _fail('未知字段 $key');
    }
  }
}

String _requireMethod(Object? value, PluginBridgeLimits limits) {
  if (value is! String) {
    _fail('method 必须是字符串');
  }
  if (value.length > limits.maxMethodLength) {
    _fail('method 长度超过 ${limits.maxMethodLength}');
  }
  if (!_methodPattern.hasMatch(value)) {
    _fail('method 格式非法：$value');
  }
  return value;
}

Object _requireId(Object? value, PluginBridgeLimits limits) {
  if (value is int) return value;
  if (value is String) {
    if (value.isEmpty) {
      _fail('id 不能为空字符串');
    }
    if (value.length > limits.maxIdLength) {
      _fail('id 长度超过 ${limits.maxIdLength}');
    }
    return value;
  }
  _fail('id 必须是整数或非空字符串');
}

Map<String, Object?> _decodeParams(
  Map<String, Object?> map,
  PluginBridgeLimits limits,
) {
  if (!map.containsKey('params')) {
    return const <String, Object?>{};
  }
  return _requireObject(map['params'], 'params');
}

PluginBridgeErrorCode? _errorCodeOf(int code) {
  for (final value in PluginBridgeErrorCode.values) {
    if (value.code == code) return value;
  }
  return null;
}

/// 校验 JSON 值类型合法、嵌套深度不超限；字符串长度预算另行统计。
void _validateJsonValue(Object? value, PluginBridgeLimits limits) {
  final stack = <(Object?, int)>[(value, 1)];
  while (stack.isNotEmpty) {
    final (current, depth) = stack.removeLast();
    if (current == null || current is bool || current is int) {
      continue;
    }
    if (current is double) {
      if (!current.isFinite) {
        _fail('不接受非有限浮点数');
      }
      continue;
    }
    if (current is String) {
      continue;
    }
    if (current is Map<Object?, Object?>) {
      if (depth > limits.maxDepth) {
        _fail('JSON 嵌套深度超过 ${limits.maxDepth}');
      }
      for (final entry in current.entries) {
        if (entry.key is! String) {
          _fail('对象键必须是字符串');
        }
        stack.add((entry.value, depth + 1));
      }
      continue;
    }
    if (current is List<Object?>) {
      if (depth > limits.maxDepth) {
        _fail('JSON 嵌套深度超过 ${limits.maxDepth}');
      }
      for (final item in current) {
        stack.add((item, depth + 1));
      }
      continue;
    }
    _fail('不支持的 JSON 值类型 ${current.runtimeType}');
  }
}

/// 递归统计 [value] 内所有字符串（含对象键）的总长度。
void _checkStringBudget(Object? value, int maxStringLength) {
  var total = 0;
  final stack = <Object?>[value];
  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    if (current is String) {
      total += current.length;
      if (total > maxStringLength) {
        _fail('参数内字符串总长度超过 $maxStringLength');
      }
      continue;
    }
    if (current is Map<Object?, Object?>) {
      for (final entry in current.entries) {
        final key = entry.key;
        if (key is String) {
          total += key.length;
          if (total > maxStringLength) {
            _fail('参数内字符串总长度超过 $maxStringLength');
          }
        }
        stack.add(entry.value);
      }
      continue;
    }
    if (current is List<Object?>) {
      stack.addAll(current);
    }
  }
}

/// 不解析 JSON、只在文本上扫描 `{}` / `[]` 的嵌套深度。
///
/// 字符串字面量内的括号（含转义序列）不计数；是否合法 JSON 仍由
/// `jsonDecode` 严格判定。
bool _jsonTextDepthWithin(String raw, int maxDepth) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var index = 0; index < raw.length; index++) {
    final codeUnit = raw.codeUnitAt(index);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (codeUnit == 0x5C) {
        escaped = true;
      } else if (codeUnit == 0x22) {
        inString = false;
      }
      continue;
    }
    if (codeUnit == 0x22) {
      inString = true;
      continue;
    }
    if (codeUnit == 0x7B || codeUnit == 0x5B) {
      depth++;
      if (depth > maxDepth) return false;
    } else if (codeUnit == 0x7D || codeUnit == 0x5D) {
      depth--;
    }
  }
  return true;
}
