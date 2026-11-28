import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

/// 断言解码成功并取出消息；失败时输出原因。
PluginBridgeMessage _ok(Result<PluginBridgeMessage> result) {
  expect(result.isOk, isTrue, reason: '${result.failureOrNull}');
  return result.value;
}

/// 编码后还原为 JSON 对象，便于检查线格式。
Map<String, Object?> _jsonOf(PluginBridgeMessage message) =>
    jsonDecode(encodePluginBridgeMessage(message)) as Map<String, Object?>;

void main() {
  group('常量与限制', () {
    test('协议版本为 1', () {
      expect(pluginBridgeProtocolVersion, 1);
    });

    test('默认限制与契约一致', () {
      const limits = PluginBridgeLimits();
      expect(limits.maxBytes, 256 * 1024);
      expect(limits.maxDepth, 32);
      expect(limits.maxIdLength, 128);
      expect(limits.maxMethodLength, 128);
      expect(limits.maxStringLength, 64 * 1024);
    });

    test('错误码与 JSON-RPC 2.0 / 桥扩展定义一致', () {
      expect(PluginBridgeErrorCode.parseError.code, -32700);
      expect(PluginBridgeErrorCode.invalidRequest.code, -32600);
      expect(PluginBridgeErrorCode.methodNotFound.code, -32601);
      expect(PluginBridgeErrorCode.invalidParams.code, -32602);
      expect(PluginBridgeErrorCode.internalError.code, -32603);
      expect(PluginBridgeErrorCode.permissionDenied.code, -32001);
      expect(PluginBridgeErrorCode.messageTooLarge.code, -32002);
      expect(PluginBridgeErrorCode.rateLimited.code, -32003);
      expect(PluginBridgeErrorCode.timeout.code, -32004);
      expect(PluginBridgeErrorCode.sandboxUnavailable.code, -32005);
    });
  });

  group('方法 / scope / slot 目录', () {
    const expectedMethods = <String, String>{
      'host.getInfo': 'host',
      'host.log': 'host',
      'host.openExternal': 'host',
      'chat.sendText': 'chat.send',
      'chat.sendCard': 'chat.send',
      'chat.listConversations': 'chat.read',
      'message.recent': 'message.read',
      'message.get': 'message.read',
      'message.onMessage': 'message.events',
      'model.invoke': 'model.invoke',
      'storage.get': 'storage',
      'storage.set': 'storage',
      'storage.remove': 'storage',
      'storage.keys': 'storage',
      'ui.registerSlot': 'ui.slot',
      'ui.setTitle': 'ui.chrome',
      'ui.close': 'ui.chrome',
      'ui.toast': 'ui.chrome',
      'world.getLayout': 'world.read',
      'world.setLayout': 'world.write',
      'world.onPresence': 'world.events',
      'events.on': 'events',
      'events.off': 'events',
      'commands.registerSlash': 'commands',
      'settings.read': 'config',
      'settings.write': 'config',
      'notify.notify': 'notify',
    };

    const expectedScopes = <String>{
      'host',
      'chat.send',
      'chat.read',
      'message.read',
      'message.events',
      'model.invoke',
      'storage',
      'ui.slot',
      'ui.chrome',
      'world.read',
      'world.write',
      'world.events',
      'events',
      'commands',
      'config',
      'notify',
    };

    const expectedSlots = <String>[
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

    test('方法目录覆盖 v3 §5 全部 27 个方法且 scope 正确', () {
      expect(
        PluginBridgeApi.methods.map((method) => method.name).toSet(),
        expectedMethods.keys.toSet(),
      );
      expect(PluginBridgeApi.methods.length, expectedMethods.length);
      for (final method in PluginBridgeApi.methods) {
        expect(method.scope, expectedMethods[method.name], reason: method.name);
        expect(method.description, isNotEmpty, reason: method.name);
      }
    });

    test('方法名不重复', () {
      final names = PluginBridgeApi.methods
          .map((method) => method.name)
          .toList();
      expect(names.toSet().length, names.length);
    });

    test('method() 按名查找，未知方法返回 null', () {
      final found = PluginBridgeApi.method('host.getInfo');
      expect(found, isNotNull);
      expect(found?.scope, 'host');
      expect(PluginBridgeApi.method('host.unknown'), isNull);
    });

    test('scope 常量表覆盖约定全部 scope', () {
      expect(PluginBridgeApi.scopes.values.toSet(), expectedScopes);
      expect(PluginBridgeApi.scopes['chatSend'], 'chat.send');
      for (final method in PluginBridgeApi.methods) {
        expect(
          PluginBridgeApi.scopes.values.contains(method.scope),
          isTrue,
          reason: method.name,
        );
      }
    });

    test('slotKeys 覆盖 v3 §3 全部静态 key', () {
      expect(PluginBridgeApi.slotKeys.toSet(), expectedSlots.toSet());
      expect(PluginBridgeApi.slotKeys.length, expectedSlots.length);
    });

    test('isKnownSlot 支持静态 key 与 conversation.message.card. 动态前缀', () {
      for (final slot in expectedSlots) {
        expect(PluginBridgeApi.isKnownSlot(slot), isTrue, reason: slot);
      }
      expect(
        PluginBridgeApi.isKnownSlot('conversation.message.card.text'),
        isTrue,
      );
      expect(
        PluginBridgeApi.isKnownSlot(
          'conversation.message.card.com.friend.music',
        ),
        isTrue,
      );
      expect(
        PluginBridgeApi.isKnownSlot('conversation.message.card.'),
        isFalse,
      );
      expect(PluginBridgeApi.isKnownSlot('conversation.message.card'), isFalse);
      expect(PluginBridgeApi.isKnownSlot('shell.unknown'), isFalse);
      expect(PluginBridgeApi.isKnownSlot(''), isFalse);
    });
  });

  group('消息编解码', () {
    test('请求（int id）往返一致', () {
      const message = PluginBridgeRequest(
        id: 7,
        method: 'chat.sendText',
        params: {'conversationId': 'c1', 'text': '你好'},
      );
      final json = _jsonOf(message);
      expect(json['jsonrpc'], '2.0');
      expect(json['id'], 7);
      expect(json['method'], 'chat.sendText');
      expect((json['params'] as Map<String, Object?>)['text'], '你好');

      final decoded =
          _ok(decodePluginBridgeJson(encodePluginBridgeMessage(message)))
              as PluginBridgeRequest;
      expect(decoded.id, 7);
      expect(decoded.method, 'chat.sendText');
      expect(decoded.params['conversationId'], 'c1');
      expect(decoded.params['text'], '你好');
    });

    test('请求（字符串 id）往返一致', () {
      const message = PluginBridgeRequest(id: 'req-1', method: 'host.getInfo');
      final decoded =
          _ok(decodePluginBridgeJson(encodePluginBridgeMessage(message)))
              as PluginBridgeRequest;
      expect(decoded.id, 'req-1');
      expect(decoded.method, 'host.getInfo');
      expect(decoded.params, isEmpty);
    });

    test('通知往返一致且没有 id 字段', () {
      const message = PluginBridgeNotification(
        method: 'host.ready',
        params: {'pluginId': 'com.example.demo', 'apiVersion': 1},
      );
      final json = _jsonOf(message);
      expect(json['jsonrpc'], '2.0');
      expect(json.containsKey('id'), isFalse);
      expect(json['method'], 'host.ready');

      final decoded =
          _ok(decodePluginBridgeJson(encodePluginBridgeMessage(message)))
              as PluginBridgeNotification;
      expect(decoded.method, 'host.ready');
      expect(decoded.params['apiVersion'], 1);
    });

    test('成功响应（result 为 null）往返一致', () {
      const message = PluginBridgeSuccess(id: 'r1');
      final json = _jsonOf(message);
      expect(json['jsonrpc'], '2.0');
      expect(json['id'], 'r1');
      expect(json.containsKey('result'), isTrue);
      expect(json['result'], isNull);

      final decoded =
          _ok(decodePluginBridgeJson(encodePluginBridgeMessage(message)))
              as PluginBridgeSuccess;
      expect(decoded.id, 'r1');
      expect(decoded.result, isNull);
    });

    test('成功响应（result 为对象）往返一致', () {
      const message = PluginBridgeSuccess(
        id: 9,
        result: {
          'ok': true,
          'items': [1, 2, 3],
        },
      );
      final decoded =
          _ok(decodePluginBridgeJson(encodePluginBridgeMessage(message)))
              as PluginBridgeSuccess;
      expect(decoded.id, 9);
      expect(decoded.result, {
        'ok': true,
        'items': [1, 2, 3],
      });
    });

    test('失败响应（带 data）往返一致', () {
      const message = PluginBridgeFailure(
        id: 3,
        code: PluginBridgeErrorCode.permissionDenied,
        message: '无权限',
        data: {'scope': 'storage'},
      );
      final json = _jsonOf(message);
      expect(json['id'], 3);
      final error = json['error'] as Map<String, Object?>;
      expect(error['code'], -32001);
      expect(error['message'], '无权限');
      expect(error['data'], {'scope': 'storage'});

      final decoded =
          _ok(decodePluginBridgeJson(encodePluginBridgeMessage(message)))
              as PluginBridgeFailure;
      expect(decoded.id, 3);
      expect(decoded.code, PluginBridgeErrorCode.permissionDenied);
      expect(decoded.message, '无权限');
      expect(decoded.data, {'scope': 'storage'});
    });

    test('解析错误失败响应允许 id 为 null', () {
      const message = PluginBridgeFailure(
        id: null,
        code: PluginBridgeErrorCode.parseError,
        message: 'JSON 解析失败',
      );
      final json = _jsonOf(message);
      expect(json.containsKey('id'), isTrue);
      expect(json['id'], isNull);

      final decoded =
          _ok(decodePluginBridgeJson(encodePluginBridgeMessage(message)))
              as PluginBridgeFailure;
      expect(decoded.id, isNull);
      expect(decoded.code, PluginBridgeErrorCode.parseError);
    });

    test('toJson 均为 JSON-RPC 2.0 信封', () {
      expect(
        const PluginBridgeRequest(
          id: 1,
          method: 'host.log',
        ).toJson()['jsonrpc'],
        '2.0',
      );
      expect(
        const PluginBridgeNotification(method: 'host.log').toJson()['jsonrpc'],
        '2.0',
      );
      expect(const PluginBridgeSuccess(id: 1).toJson()['jsonrpc'], '2.0');
      expect(
        const PluginBridgeFailure(
          id: null,
          code: PluginBridgeErrorCode.parseError,
          message: 'x',
        ).toJson()['jsonrpc'],
        '2.0',
      );
    });
  });

  group('严格解码：信封与请求', () {
    test('顶层必须是对象', () {
      for (final value in <Object?>[null, <Object?>[], 'x', 1, true]) {
        final result = decodePluginBridgeMessage(value);
        expect(result.isErr, isTrue, reason: '$value');
        expect(result.failureOrNull?.code, FailureCode.invalidArgument);
      }
    });

    test('jsonrpc 必须等于 "2.0"', () {
      final cases = <Map<String, Object?>>[
        {'method': 'host.log'},
        {'jsonrpc': '1.0', 'method': 'host.log'},
        {'jsonrpc': 2, 'method': 'host.log'},
        {'jsonrpc': null, 'method': 'host.log'},
      ];
      for (final map in cases) {
        final result = decodePluginBridgeMessage(map);
        expect(result.isErr, isTrue, reason: '$map');
        expect(result.failureOrNull?.code, FailureCode.invalidArgument);
      }
    });

    test('拒绝未知顶层字段', () {
      final cases = <Map<String, Object?>>[
        {'jsonrpc': '2.0', 'id': 1, 'method': 'host.log', 'extra': 1},
        {'jsonrpc': '2.0', 'method': 'host.log', 'extra': 1},
        {'jsonrpc': '2.0', 'id': 1, 'result': 1, 'extra': 1},
        {
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'code': -32700, 'message': 'x'},
          'params': <String, Object?>{},
        },
        {
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'code': -32700, 'message': 'x', 'extra': 1},
        },
      ];
      for (final map in cases) {
        final result = decodePluginBridgeMessage(map);
        expect(result.isErr, isTrue, reason: '$map');
        expect(result.failureOrNull?.code, FailureCode.invalidArgument);
      }
    });

    test('请求 id 必须是 int 或非空 String', () {
      for (final id in <Object?>[
        null,
        true,
        1.5,
        '',
        <Object?>[],
        <String, Object?>{},
      ]) {
        final map = <String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'method': 'host.log',
        };
        final result = decodePluginBridgeMessage(map);
        expect(result.isErr, isTrue, reason: '$id');
        expect(result.failureOrNull?.code, FailureCode.invalidArgument);
      }
    });

    test('id 长度受 maxIdLength 限制', () {
      const limits = PluginBridgeLimits(maxIdLength: 3);
      final ok = decodePluginBridgeMessage({
        'jsonrpc': '2.0',
        'method': 'host.log',
        'id': 'abc',
      }, limits: limits);
      expect(ok.isOk, isTrue, reason: '${ok.failureOrNull}');
      final tooLong = decodePluginBridgeMessage({
        'jsonrpc': '2.0',
        'method': 'host.log',
        'id': 'abcd',
      }, limits: limits);
      expect(tooLong.failureOrNull?.code, FailureCode.invalidArgument);
    });

    test('method 必须符合点分格式', () {
      for (final method in <Object?>[
        '',
        'host',
        'Host.log',
        'host..log',
        'host.log-x',
        '1host.log',
        'host.中文',
        null,
        3,
      ]) {
        final result = decodePluginBridgeMessage({
          'jsonrpc': '2.0',
          'method': method,
        });
        expect(result.isErr, isTrue, reason: '$method');
        expect(result.failureOrNull?.code, FailureCode.invalidArgument);
      }

      for (final method in [
        'a.b',
        'host.getInfo',
        'ui.registerSlot2',
        'a.b_c',
        'a.b.0',
      ]) {
        final result = decodePluginBridgeMessage({
          'jsonrpc': '2.0',
          'method': method,
        });
        expect(result.isOk, isTrue, reason: '$method: ${result.failureOrNull}');
      }
    });

    test('method 长度受 maxMethodLength 限制', () {
      const limits = PluginBridgeLimits(maxMethodLength: 5);
      expect(
        decodePluginBridgeMessage({
          'jsonrpc': '2.0',
          'method': 'ab.cd',
        }, limits: limits).isOk,
        isTrue,
      );
      expect(
        decodePluginBridgeMessage({
          'jsonrpc': '2.0',
          'method': 'ab.cde',
        }, limits: limits).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
    });

    test('params 缺省为 const 空对象', () {
      final decoded =
          _ok(
                decodePluginBridgeMessage({
                  'jsonrpc': '2.0',
                  'method': 'host.log',
                }),
              )
              as PluginBridgeNotification;
      expect(decoded.params, isEmpty);
    });

    test('params 出现时必须是对象', () {
      for (final params in <Object?>[null, <Object?>[], 'x', 1, true]) {
        final map = <String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'host.log',
          'params': params,
        };
        final result = decodePluginBridgeMessage(map);
        expect(result.isErr, isTrue, reason: '$params');
        expect(result.failureOrNull?.code, FailureCode.invalidArgument);
      }
    });

    test('请求不允许携带 result/error', () {
      final cases = <Map<String, Object?>>[
        {'jsonrpc': '2.0', 'id': 1, 'method': 'host.log', 'result': 1},
        {
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'host.log',
          'error': {'code': -32700, 'message': 'x'},
        },
      ];
      for (final map in cases) {
        expect(
          decodePluginBridgeMessage(map).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
      }
    });

    test('通知带 id 时按请求校验', () {
      final asRequest = _ok(
        decodePluginBridgeMessage({
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'host.log',
        }),
      );
      expect(asRequest, isA<PluginBridgeRequest>());
      final nullId = decodePluginBridgeMessage({
        'jsonrpc': '2.0',
        'id': null,
        'method': 'host.log',
      });
      expect(nullId.failureOrNull?.code, FailureCode.invalidArgument);
    });
  });

  group('严格解码：响应', () {
    test('成功响应必须同时有 id 与 result', () {
      final cases = <Map<String, Object?>>[
        {'jsonrpc': '2.0', 'result': 1},
        {'jsonrpc': '2.0', 'id': 1},
        {'jsonrpc': '2.0', 'id': null, 'result': 1},
        {'jsonrpc': '2.0', 'id': 1, 'result': 1, 'method': 'host.log'},
        {
          'jsonrpc': '2.0',
          'id': 1,
          'result': 1,
          'error': {'code': -32700, 'message': 'x'},
        },
      ];
      for (final map in cases) {
        expect(
          decodePluginBridgeMessage(map).failureOrNull?.code,
          FailureCode.invalidArgument,
          reason: '$map',
        );
      }
    });

    test('失败响应 error 结构必须严格', () {
      final cases = <Map<String, Object?>>[
        {
          'jsonrpc': '2.0',
          'error': {'code': -32700, 'message': 'x'},
        },
        {
          'jsonrpc': '2.0',
          'id': null,
          'error': {'code': -32603, 'message': 'x'},
        },
        {
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'code': '-32700', 'message': 'x'},
        },
        {
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'code': -99999, 'message': 'x'},
        },
        {
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'code': -32700},
        },
        {
          'jsonrpc': '2.0',
          'id': 1,
          'error': {'code': -32700, 'message': 7},
        },
        {'jsonrpc': '2.0', 'id': 1, 'error': <String, Object?>{}},
      ];
      for (final map in cases) {
        expect(
          decodePluginBridgeMessage(map).failureOrNull?.code,
          FailureCode.invalidArgument,
          reason: '$map',
        );
      }

      final ok = _ok(
        decodePluginBridgeMessage({
          'jsonrpc': '2.0',
          'id': 1,
          'error': {
            'code': -32700,
            'message': 'x',
            'data': <Object?>[1, 'two'],
          },
        }),
      );
      expect(ok, isA<PluginBridgeFailure>());
      expect((ok as PluginBridgeFailure).data, <Object?>[1, 'two']);
    });

    test('JSON 文本非法时返回 invalidArgument', () {
      for (final raw in ['', '{not json', '[]', '"text"', 'null']) {
        final result = decodePluginBridgeJson(raw);
        expect(result.isErr, isTrue, reason: raw);
        expect(result.failureOrNull?.code, FailureCode.invalidArgument);
      }
    });
  });

  group('限制：字节、深度、字符串总长', () {
    test('按 UTF-8 字节数应用 maxBytes', () {
      final raw = jsonEncode({
        'jsonrpc': '2.0',
        'method': 'host.log',
        'params': {'text': '你好'},
      });
      final byteLength = utf8.encode(raw).length;
      expect(
        decodePluginBridgeJson(
          raw,
          limits: PluginBridgeLimits(maxBytes: byteLength),
        ).isOk,
        isTrue,
      );
      expect(
        decodePluginBridgeJson(
          raw,
          limits: PluginBridgeLimits(maxBytes: byteLength - 1),
        ).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
    });

    test('嵌套深度按 JSON 文本计，字符串字面量内不计数', () {
      const deepRaw =
          '{"jsonrpc":"2.0","method":"host.log","params":{"a":{"b":1}}}';
      expect(
        decodePluginBridgeJson(
          deepRaw,
          limits: const PluginBridgeLimits(maxDepth: 2),
        ).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      final within = decodePluginBridgeJson(
        deepRaw,
        limits: const PluginBridgeLimits(maxDepth: 3),
      );
      expect(within.isOk, isTrue, reason: '${within.failureOrNull}');

      const literalRaw =
          '{"jsonrpc":"2.0","method":"host.log","params":{"text":"[[[[[[[["}}';
      final literal = decodePluginBridgeJson(
        literalRaw,
        limits: const PluginBridgeLimits(maxDepth: 2),
      );
      expect(literal.isOk, isTrue, reason: '${literal.failureOrNull}');
    });

    test('直接传入对象时同样限制嵌套深度', () {
      final map = <String, Object?>{
        'jsonrpc': '2.0',
        'method': 'host.log',
        'params': {
          'a': {'b': 1},
        },
      };
      expect(
        decodePluginBridgeMessage(
          map,
          limits: const PluginBridgeLimits(maxDepth: 2),
        ).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(
        decodePluginBridgeMessage(
          map,
          limits: const PluginBridgeLimits(maxDepth: 3),
        ).isOk,
        isTrue,
      );
    });

    test('params 内所有字符串总长受 maxStringLength 限制', () {
      const limits = PluginBridgeLimits(maxStringLength: 5);
      expect(
        decodePluginBridgeMessage({
          'jsonrpc': '2.0',
          'method': 'host.log',
          'params': {'a': 'xxxx'},
        }, limits: limits).isOk,
        isTrue,
      );
      expect(
        decodePluginBridgeMessage({
          'jsonrpc': '2.0',
          'method': 'host.log',
          'params': {'a': 'xxxxx'},
        }, limits: limits).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(
        decodePluginBridgeMessage({
          'jsonrpc': '2.0',
          'method': 'host.log',
          'params': {
            'a': {'b': 'xxx'},
          },
        }, limits: limits).isOk,
        isTrue,
      );
      expect(
        decodePluginBridgeMessage({
          'jsonrpc': '2.0',
          'method': 'host.log',
          'params': {
            'a': {'b': 'xxxx'},
          },
        }, limits: limits).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
    });
  });

  group('异常输入不抛出未受控异常', () {
    test('拒绝 JSON 不支持的数值', () {
      final map = <String, Object?>{
        'jsonrpc': '2.0',
        'method': 'host.log',
        'params': <String, Object?>{'x': double.nan},
      };
      expect(
        decodePluginBridgeMessage(map).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
    });

    test('拒绝非字符串对象键', () {
      final map = <String, Object?>{
        'jsonrpc': '2.0',
        'method': 'host.log',
        'params': <Object?, Object?>{1: 'x'},
      };
      expect(
        decodePluginBridgeMessage(map).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
    });

    test('拒绝非 JSON 值类型', () {
      final map = <String, Object?>{
        'jsonrpc': '2.0',
        'method': 'host.log',
        'params': <String, Object?>{'at': DateTime.utc(2026, 11, 28)},
      };
      expect(
        decodePluginBridgeMessage(map).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
    });
  });
}
