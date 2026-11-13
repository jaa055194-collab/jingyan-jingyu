@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

import 'message_store_contract.dart';

void main() {
  messageStoreContract('内存', () => InMemoryMessageStore());

  group('UrlGuard（NFR-05）', () {
    Future<List<InternetAddress>> publicDns(String host) async => [
      InternetAddress('93.184.216.34'),
    ];
    Future<List<InternetAddress>> rebindDns(String host) async => [
      InternetAddress('10.0.0.5'),
    ];

    test('拒绝非 http(s) 协议', () async {
      final guard = UrlGuard(resolver: publicDns);
      for (final url in [
        'ftp://example.com',
        'file:///etc/passwd',
        'gopher://x',
      ]) {
        expect(
          (await guard.check(url)).failureOrNull?.code,
          FailureCode.forbidden,
          reason: url,
        );
      }
    });

    test('拒绝 localhost、环回、私有与保留地址字面量', () async {
      final guard = UrlGuard(resolver: publicDns);
      for (final url in [
        'http://localhost:8080',
        'http://127.0.0.1',
        'http://10.1.2.3',
        'http://172.20.0.1',
        'http://192.168.1.1',
        'http://169.254.169.254',
        'http://100.100.1.1',
        'http://0.0.0.0',
        'http://[::1]',
        'http://[fd00::1]',
        'http://[fe80::1]',
        'http://[::ffff:127.0.0.1]',
      ]) {
        expect((await guard.check(url)).isErr, isTrue, reason: url);
      }
    });

    test('DNS 解析到私有地址时拒绝（防 rebinding）', () async {
      final guard = UrlGuard(resolver: rebindDns);
      expect(
        (await guard.check('https://evil.example')).failureOrNull?.code,
        FailureCode.forbidden,
      );
    });

    test('公网地址放行', () async {
      final guard = UrlGuard(resolver: publicDns);
      final result = await guard.check('https://api.example.com/v1');
      expect(result.isOk, isTrue);
      expect(result.value.host, 'api.example.com');
    });
  });

  group('审计', () {
    test('拒绝正文与密钥字段', () {
      AuditEntry make(Map<String, Object?> meta) => AuditEntry(
        at: DateTime.utc(2026),
        actorId: 'u1',
        action: 'message.recall',
        targetKind: 'message',
        targetId: 'm1',
        meta: meta,
      );
      expect(() => make({'text': '正文'}), throwsArgumentError);
      expect(() => make({'apiKey': 'sk-x'}), throwsArgumentError);
      expect(() => make({'nested': <String, Object?>{}}), throwsArgumentError);
      expect(make({'seq': 3, 'ok': true}).meta['seq'], 3);
    });
  });

  group('宿主装配与 HTTP 管线', () {
    late Host host;
    late Directory dataDir;
    late AccountId adminId;
    late AccountId userId;
    late String token;
    late String adminToken;
    late DeviceId deviceId;
    late String conversation;
    late String privateConversation;
    const password = 'test-password-123';

    setUpAll(() async {
      dataDir = await Directory.systemTemp.createTemp('jingyu-host-accounts-');
      host = await buildHost(
        config: HostConfig(dataDir: dataDir.path),
        clock: FakeClock(DateTime.utc(2026, 11, 13, 6)),
      );
      adminId = (await host.auth.bootstrapAdmin(
        displayName: 'Root',
        password: password,
      )).value;
      final login = (await host.auth.login(
        adminId,
        password,
        deviceName: 'bootstrap',
      )).value;
      final session = (await host.auth.scope(login.accessToken)).value;
      userId = (await session.accounts.createHuman(
        displayName: 'User',
        password: password,
      )).value;
      final conversations = host.registry.services.get<ConversationService>();
      conversation = (await conversations.createGroup(
        ownerAccountId: userId.value,
        name: 'Test group',
      )).value.id;
      privateConversation = (await conversations.createGroup(
        ownerAccountId: userId.value,
        name: 'Private group',
      )).value.id;
    });

    setUp(() async {
      final user = (await host.auth.login(
        userId,
        password,
        deviceName: 'test',
      )).value;
      token = user.accessToken;
      deviceId = user.deviceId;
      adminToken = (await host.auth.login(
        adminId,
        password,
        deviceName: 'admin',
      )).value.accessToken;
    });

    tearDownAll(() async {
      await host.shutdown();
      await dataDir.delete(recursive: true);
    });

    Map<String, String> authed() => {'authorization': 'Bearer $token'};
    String path(String pattern, String conv) =>
        pattern.replaceFirst('{conversationId}', conv);

    test('health 公开可用', () async {
      final res = await host.pipeline.handle(
        HostRequest(method: 'GET', path: Routes.health),
      );
      expect(res.status, 200);
    });

    test('host 信息只给管理员且管理响应不包含消息正文', () async {
      const secretBody = 'private message body excluded from admin metadata';
      final sent = await host.pipeline.handle(
        HostRequest(
          method: 'POST',
          path: path(Routes.messages, privateConversation),
          headers: authed(),
          body: {
            'clientMsgId': 'private-1',
            'kind': 'text',
            'body': {'text': secretBody},
          },
        ),
      );
      expect(sent.status, 200);
      final user = await host.pipeline.handle(
        HostRequest(method: 'GET', path: Routes.hostInfo, headers: authed()),
      );
      expect(user.status, 403);
      final escalation = await host.pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.adminAccounts,
          headers: authed(),
          body: {
            'displayName': 'Escalated',
            'password': password,
            'isAdmin': true,
          },
        ),
      );
      expect(escalation.status, 403);
      final admin = await host.pipeline.handle(
        HostRequest(
          method: 'GET',
          path: Routes.hostInfo,
          headers: {'authorization': 'Bearer $adminToken'},
        ),
      );
      expect(admin.status, 200);
      expect((admin.json as Map)['modules'], [
        'system',
        'storage',
        'accounts',
        'messages',
        'social',
      ]);
      final metadata = await host.pipeline.handle(
        HostRequest(
          method: 'GET',
          path: Routes.adminAccounts,
          headers: {'authorization': 'Bearer $adminToken'},
        ),
      );
      expect(metadata.status, 200);
      expect(
        jsonEncode([admin.json, metadata.json]),
        isNot(contains(secretBody)),
      );
    });

    test('发送 → 幂等重发 → 差集同步', () async {
      Future<HostResponse> post(String cmid) => host.pipeline.handle(
        HostRequest(
          method: 'POST',
          path: path(Routes.messages, conversation),
          headers: authed(),
          body: {
            'clientMsgId': cmid,
            'kind': 'text',
            'body': {'text': '刚浇完花'},
          },
        ),
      );

      final first = await post('cm-1');
      expect(first.status, 200);
      expect((first.json as Map)['duplicate'], isFalse);
      final again = await post('cm-1');
      expect((again.json as Map)['duplicate'], isTrue);
      await post('cm-2');

      final sync = await host.pipeline.handle(
        HostRequest(
          method: 'GET',
          path: path(Routes.sync, conversation),
          query: const {'afterSeq': '0'},
          headers: authed(),
        ),
      );
      final messages = (sync.json as Map)['messages'] as List;
      expect(messages.map((m) => (m as Map)['seq']), [1, 2]);
    });

    test(
      'joined history is enforced through default authenticated HTTP assembly',
      () async {
        final created = await host.pipeline.handle(
          HostRequest(
            method: 'POST',
            path: Routes.conversations,
            headers: authed(),
            body: {'name': 'Joined group', 'historyVisibility': 'joined'},
          ),
        );
        expect(created.status, 200);
        final id = (created.json as Map)['id'] as String;
        Future<HostResponse> post(String key) => host.pipeline.handle(
          HostRequest(
            method: 'POST',
            path: path(Routes.messages, id),
            headers: authed(),
            body: {
              'clientMsgId': key,
              'kind': 'text',
              'body': {'text': key},
            },
          ),
        );
        expect((await post('before-join')).status, 200);
        Future<HostResponse> adminSync() => host.pipeline.handle(
          HostRequest(
            method: 'GET',
            path: path(Routes.sync, id),
            headers: {'authorization': 'Bearer $adminToken'},
          ),
        );
        expect((await adminSync()).status, 404);
        final joined = await host.pipeline.handle(
          HostRequest(
            method: 'POST',
            path: Routes.conversationMembers.replaceFirst(
              '{conversationId}',
              id,
            ),
            headers: authed(),
            body: {'accountId': adminId.value},
          ),
        );
        expect(joined.status, 200);
        expect((await post('after-join')).status, 200);
        final synced = await adminSync();
        expect(synced.status, 200);
        final visible = (synced.json as Map)['messages'] as List;
        expect(visible.map((m) => ((m as Map)['body'] as Map)['text']), [
          'after-join',
        ]);
        final lists = await host.pipeline.handle(
          HostRequest(
            method: 'GET',
            path: Routes.conversations,
            headers: {'authorization': 'Bearer $adminToken'},
          ),
        );
        expect(lists.status, 200);
        expect(
          ((lists.json as Map)['conversations'] as List).any(
            (c) => (c as Map)['id'] == id,
          ),
          isTrue,
        );
      },
    );

    test('未登录 401；坏请求体 400；吊销后立即失效', () async {
      final anon = await host.pipeline.handle(
        HostRequest(method: 'POST', path: path(Routes.messages, conversation)),
      );
      expect(anon.status, 401);
      final bad = await host.pipeline.handle(
        HostRequest(
          method: 'POST',
          path: path(Routes.messages, conversation),
          headers: authed(),
          body: {'kind': 'nope'},
        ),
      );
      expect(bad.status, 400);
      final revoke = await host.pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.authDeviceRevoke.replaceFirst(
            '{deviceId}',
            deviceId.value,
          ),
          headers: authed(),
        ),
      );
      expect(revoke.status, 200);
      final revoked = await host.pipeline.handle(
        HostRequest(
          method: 'GET',
          path: path(Routes.sync, conversation),
          headers: authed(),
        ),
      );
      expect(revoked.status, 401);
    });
  });

  group('真实端口冒烟', () {
    test('transport peer ignores spoofed forwarding headers', () async {
      final router = Router()
        ..get(
          '/peer/{id}',
          (request) async => HostResponse.ok({'peer': request.remoteAddress}),
          access: Access.public,
        );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serving = serve(
        server,
        Pipeline(router: router, authenticate: (_) async => null),
      );
      final client = HttpClient();
      try {
        for (var i = 0; i < 5; i++) {
          final request = await client.get(
            '127.0.0.1',
            server.port,
            '/peer/$i',
          );
          request.headers.set('x-forwarded-for', '203.0.113.8');
          request.headers.set('forwarded', 'for=203.0.113.9');
          final response = await request.close();
          expect(response.statusCode, 200);
          final payload =
              jsonDecode(await utf8.decoder.bind(response).join()) as Map;
          expect(payload['peer'], '127.0.0.1', reason: 'request $i');
        }
      } finally {
        client.close(force: true);
        await server.close(force: true);
        await serving;
      }
    });
    test('transport peer survives reading a JSON POST body', () async {
      final router = Router()
        ..post(
          '/peer/{id}',
          (request) async => HostResponse.ok({
            'peer': request.remoteAddress,
            'body': request.body,
          }),
          access: Access.public,
        );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serving = serve(
        server,
        Pipeline(router: router, authenticate: (_) async => null),
      );
      final client = HttpClient();
      try {
        final request = await client.post('127.0.0.1', server.port, '/peer/42');
        request.headers.contentType = ContentType.json;
        request.headers.set('x-forwarded-for', '203.0.113.8');
        request.headers.set('forwarded', 'for=203.0.113.9');
        request.write(jsonEncode({'accountId': 'test-account'}));
        final response = await request.close();
        expect(response.statusCode, 200);
        final payload =
            jsonDecode(await utf8.decoder.bind(response).join()) as Map;
        expect(payload['body'], {'accountId': 'test-account'});
        expect(payload['peer'], '127.0.0.1');
      } finally {
        client.close(force: true);
        await server.close(force: true);
        await serving;
      }
    });
    test('HttpServer 上 health 返回 200', () async {
      final dataDir = await Directory.systemTemp.createTemp('jingyu-health-');
      final host = await buildHost(config: HostConfig(dataDir: dataDir.path));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serving = serve(server, host.pipeline);
      final client = HttpClient();
      try {
        final req = await client.get('127.0.0.1', server.port, Routes.health);
        final res = await req.close();
        expect(res.statusCode, 200);
        await res.drain<void>();
      } finally {
        client.close(force: true);
        await server.close(force: true);
        await serving;
        await host.shutdown();
        await dataDir.delete(recursive: true);
      }
    });
  });
}
