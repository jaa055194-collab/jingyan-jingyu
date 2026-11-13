import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

import 'message_store_contract.dart';

void main() {
  messageStoreContract('内存', () => InMemoryMessageStore());

  group('UrlGuard（NFR-05）', () {
    Future<List<InternetAddress>> publicDns(String host) async => [InternetAddress('93.184.216.34')];
    Future<List<InternetAddress>> rebindDns(String host) async => [InternetAddress('10.0.0.5')];

    test('拒绝非 http(s) 协议', () async {
      final guard = UrlGuard(resolver: publicDns);
      for (final url in ['ftp://example.com', 'file:///etc/passwd', 'gopher://x']) {
        expect((await guard.check(url)).failureOrNull?.code, FailureCode.forbidden, reason: url);
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
      expect((await guard.check('https://evil.example')).failureOrNull?.code, FailureCode.forbidden);
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
    late String token;

    setUp(() async {
      host = await buildHost(clock: FakeClock(DateTime.utc(2026, 11, 13, 6)));
      token = host.auth.issue(const Principal(accountId: 'u1', deviceId: 'd1'));
    });

    tearDown(() => host.shutdown());

    Map<String, String> authed() => {'authorization': 'Bearer $token'};
    String path(String pattern, String conv) => pattern.replaceFirst('{conversationId}', conv);

    test('health 公开可用', () async {
      final res = await host.pipeline.handle(HostRequest(method: 'GET', path: Routes.health));
      expect(res.status, 200);
    });

    test('host 信息只给管理员', () async {
      final user = await host.pipeline.handle(HostRequest(method: 'GET', path: Routes.hostInfo, headers: authed()));
      expect(user.status, 403);
      final adminToken = host.auth.issue(const Principal(accountId: 'root', deviceId: 'd0', isAdmin: true));
      final admin = await host.pipeline.handle(
          HostRequest(method: 'GET', path: Routes.hostInfo, headers: {'authorization': 'Bearer $adminToken'}));
      expect(admin.status, 200);
      expect((admin.json as Map)['modules'], ['system', 'messages']);
    });

    test('发送 → 幂等重发 → 差集同步', () async {
      Future<HostResponse> post(String cmid) => host.pipeline.handle(HostRequest(
            method: 'POST',
            path: path(Routes.messages, 'c1'),
            headers: authed(),
            body: {'clientMsgId': cmid, 'kind': 'text', 'body': {'text': '刚浇完花'}},
          ));

      final first = await post('cm-1');
      expect(first.status, 200);
      expect((first.json as Map)['duplicate'], isFalse);
      final again = await post('cm-1');
      expect((again.json as Map)['duplicate'], isTrue);
      await post('cm-2');

      final sync = await host.pipeline.handle(HostRequest(
        method: 'GET',
        path: path(Routes.sync, 'c1'),
        query: const {'afterSeq': '0'},
        headers: authed(),
      ));
      final messages = (sync.json as Map)['messages'] as List;
      expect(messages.map((m) => (m as Map)['seq']), [1, 2]);
    });

    test('未登录 401；坏请求体 400；吊销后立即失效', () async {
      final anon = await host.pipeline.handle(HostRequest(method: 'POST', path: path(Routes.messages, 'c1')));
      expect(anon.status, 401);
      final bad = await host.pipeline.handle(HostRequest(
        method: 'POST',
        path: path(Routes.messages, 'c1'),
        headers: authed(),
        body: {'kind': 'nope'},
      ));
      expect(bad.status, 400);
      host.auth.revoke(token);
      final revoked = await host.pipeline.handle(HostRequest(method: 'GET', path: path(Routes.sync, 'c1'), headers: authed()));
      expect(revoked.status, 401);
    });
  });

  group('真实端口冒烟', () {
    test('HttpServer 上 health 返回 200', () async {
      final host = await buildHost();
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
      }
    });
  });
}
