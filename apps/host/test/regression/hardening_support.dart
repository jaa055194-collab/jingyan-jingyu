/// M13 hardening 回归测试共享夹具。
///
/// 说明：本文件只用于 `apps/host/test/regression/` 下的回归测试，不进入产品装配。
/// 一律使用默认宿主装配（`buildHost`，真实 SQLite/加密/HTTP 管线）与临时目录，
/// 不访问真实公网、不写入仓库。所有账号、设备、令牌都是测试专用合成值。
///
/// 直接播种账号的好处：主干的 PBKDF2(600k rounds) 口令派生在受限 CI/离线机器上
/// 每次约十秒，且 `hashAsync` 的 Isolate 在此环境会停滞；而 `SqlAccountsStore`
/// 每次事务都从 SQLite 重新加载账号状态，因此测试可直接写入账号/设备行并生成
/// 合法 bearer，使鉴权走真实代码路径而不必做口令哈希。这不会跳过任何被测逻辑
/// （会员/可见性/加密/审计仍在真实存储上执行），只跳过与串数据无关的口令派生。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

/// 22 位 URL 安全令牌（DbAuthenticator 要求 bearer 长度为 22）。
String syntheticToken(String marker) => List<String>.filled(22, marker).join();

/// 已登录测试账号。
class TestUser {
  TestUser({
    required this.id,
    required this.token,
    required this.deviceId,
    required this.isAdmin,
  });

  final String id;
  final String token;
  final String deviceId;
  final bool isAdmin;
}

/// 默认宿主 + 临时数据目录 + 真实 SQLite 账号存储。
class Harness {
  Harness._(this.host, this.dataDir, this.clock);

  final Host host;
  final Directory dataDir;
  final Clock clock;

  static Future<Harness> boot() async {
    final dir = await Directory.systemTemp.createTemp('jingyu-m13-regression-');
    final clock = FakeClock(DateTime.utc(2026, 11, 16, 6));
    final host = await buildHost(
      config: HostConfig(dataDir: dir.path),
      clock: clock,
    );
    return Harness._(host, dir, clock);
  }

  /// 直接经账号存储契约播种一个已激活账号及其设备令牌行。
  ///
  /// 该路径只跳过口令哈希；随后所有 HTTP 请求仍由默认 `DbAuthenticator`
  /// 用真实 bearer 哈希、账号状态与过期时间校验。
  Future<TestUser> seedAccount({
    required String displayName,
    required String id,
    required String token,
    String? deviceId,
    bool isAdmin = false,
  }) async {
    final device = deviceId ?? 'dev-$id';
    final now = clock.now().toUtc().millisecondsSinceEpoch;
    final tokenHash = sha256.convert(utf8.encode(token)).toString();
    final refreshHash = sha256
        .convert(utf8.encode('refresh-$token'))
        .toString();
    await host.auth.store.transaction((state) {
      state.accounts[id] = <String, Object?>{
        'id': id,
        'displayName': displayName,
        'kind': 'human',
        'isAdmin': isAdmin,
        'disabled': false,
        // 不使用口令登录；占位哈希满足 human 非空约束。
        'passwordHash': 'seeded-unused-no-login',
        'failedPasswords': 0,
        'lockedUntil': 0,
      };
      state.devices[device] = <String, Object?>{
        'id': device,
        'account': id,
        'deviceName': 'seeded-device',
        'accessHash': tokenHash,
        'refreshHash': refreshHash,
        'accessExpires': now + const Duration(hours: 1).inMilliseconds,
        'refreshExpires': now + const Duration(days: 30).inMilliseconds,
        'lastUsedAt': now,
      };
      return null;
    });
    return TestUser(id: id, token: token, deviceId: device, isAdmin: isAdmin);
  }

  Map<String, String> bearer(String token) => <String, String>{
    'authorization': 'Bearer $token',
  };

  /// 经默认 HTTP 管线（`Pipeline.handle`）调用，不经过真实 socket。
  Future<HostResponse> handle(
    String method,
    String path, {
    String? token,
    Map<String, String> query = const <String, String>{},
    Object? body,
  }) => host.pipeline.handle(
    HostRequest(
      method: method,
      path: path,
      query: query,
      headers: token == null ? const <String, String>{} : bearer(token),
      body: body,
    ),
  );

  Future<List<Map<String, Object?>>> auditRows() async {
    final db = host.registry.services.get<Database>();
    return db.query(
      'SELECT action, target_kind, target_id FROM audit_log ORDER BY id',
    );
  }

  Future<void> dispose() async {
    await host.shutdown();
    await dataDir.delete(recursive: true);
  }
}

/// 把响应 JSON 视作对象（调用方需确认响应是对象；列表型响应请勿使用）。
Map<String, Object?> asMap(HostResponse response) =>
    (response.json as Map<dynamic, dynamic>).cast<String, Object?>();

void expectOk(HostResponse response, String what) {
  if (response.status != 200) {
    throw StateError('$what failed: ${response.status} ${jsonEncode(response.json)}');
  }
}

/// 把 `{name}` 路径占位符替换成给定值。
String fillPath(String pattern, Map<String, String> params) => pattern
    .replaceAllMapped(RegExp(r'\{([^}]+)\}'), (match) {
      final value = params[match.group(1)!];
      return Uri.encodeComponent(value ?? 'probe');
    });

/// 解析 `Router.describe()` 的单行，例如：
/// `GET /api/v1/x [authenticated] <messages>`。
class DescribedRoute {
  DescribedRoute(this.method, this.pattern, this.access, this.owner);

  final String method;
  final String pattern;
  final String access;
  final String owner;
}

List<DescribedRoute> describeRoutes(Host host) {
  final matcher = RegExp(r'^([A-Z]+) (\S+) \[([a-z]+)\] <([^>]+)>$');
  final routes = <DescribedRoute>[];
  for (final line in host.registry.router.describe()) {
    final match = matcher.firstMatch(line);
    if (match == null) continue;
    routes.add(
      DescribedRoute(
        match.group(1)!,
        match.group(2)!,
        match.group(3)!,
        match.group(4)!,
      ),
    );
  }
  return routes;
}

// ---------------------------------------------------------------------------
// 造数辅助：全部通过默认 HTTP 管线，等价于真实调用者。
// ---------------------------------------------------------------------------

Future<String> createGroup(
  Harness harness,
  String token,
  String name,
) async {
  final response = await harness.handle(
    'POST',
    Routes.conversations,
    token: token,
    body: <String, Object?>{'name': name},
  );
  expectOk(response, 'createGroup');
  return asMap(response)['id'] as String;
}

Future<String> sendText(
  Harness harness,
  String token,
  String conversationId,
  String text,
  String clientMsgId,
) async {
  final response = await harness.handle(
    'POST',
    fillPath(Routes.messages, {'conversationId': conversationId}),
    token: token,
    body: <String, Object?>{
      'clientMsgId': clientMsgId,
      'kind': 'text',
      'body': <String, Object?>{'text': text},
    },
  );
  expectOk(response, 'sendText');
  final message = (asMap(response)['message'] as Map<dynamic, dynamic>)
      .cast<String, Object?>();
  return message['messageId'] as String;
}

Future<void> editMessage(
  Harness harness,
  String token,
  String conversationId,
  String messageId,
  String text,
) async {
  final response = await harness.handle(
    'POST',
    fillPath(Routes.messageEdit, {
      'conversationId': conversationId,
      'messageId': messageId,
    }),
    token: token,
    body: <String, Object?>{
      'body': <String, Object?>{'text': text},
    },
  );
  expectOk(response, 'editMessage');
}

Future<void> recallMessage(
  Harness harness,
  String token,
  String conversationId,
  String messageId,
) async {
  final response = await harness.handle(
    'POST',
    fillPath(Routes.messageRecall, {
      'conversationId': conversationId,
      'messageId': messageId,
    }),
    token: token,
  );
  expectOk(response, 'recallMessage');
}

Future<String> addTextFavorite(
  Harness harness,
  String token,
  String title,
  String content,
) async {
  final response = await harness.handle(
    'POST',
    Routes.favorites,
    token: token,
    body: <String, Object?>{'kind': 'text', 'title': title, 'content': content},
  );
  expectOk(response, 'addTextFavorite');
  return asMap(response)['id'] as String;
}

Future<String> uploadTextAttachment(
  Harness harness,
  String token,
  String text, {
  String? conversationId,
}) async {
  final bytes = utf8.encode(text);
  final initiate = await harness.handle(
    'POST',
    Routes.attachmentUploads,
    token: token,
    body: <String, Object?>{
      'mime': 'text/plain',
      'size': bytes.length,
      'kind': 'text',
      'conversationId': conversationId,
    },
  );
  expectOk(initiate, 'initiateUpload');
  final uploadId = asMap(initiate)['uploadId'] as String;
  final chunk = await harness.handle(
    'PUT',
    fillPath(Routes.attachmentUploadChunk, {'uploadId': uploadId, 'index': '0'}),
    token: token,
    body: <String, Object?>{'dataBase64': base64Encode(bytes)},
  );
  expectOk(chunk, 'uploadChunk');
  final complete = await harness.handle(
    'POST',
    fillPath(Routes.attachmentUploadComplete, {'uploadId': uploadId}),
    token: token,
  );
  expectOk(complete, 'completeUpload');
  return asMap(complete)['id'] as String;
}

/// 使用公网 IP 字面量作为 base_url，避免离线环境下真实 DNS 解析。
const String offlineSafeBaseUrl = 'https://93.184.216.34/v1';

Future<String> createProvider(
  Harness harness,
  String token, {
  required String name,
  required String apiKey,
  String baseUrl = offlineSafeBaseUrl,
}) async {
  final response = await harness.handle(
    'POST',
    Routes.modelProviders,
    token: token,
    body: <String, Object?>{
      'name': name,
      'base_url': baseUrl,
      'api_key': apiKey,
      'capabilities': <String>['chat'],
    },
  );
  expectOk(response, 'createProvider');
  return asMap(response)['id'] as String;
}
