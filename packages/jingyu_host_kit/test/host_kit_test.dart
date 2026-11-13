import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

abstract class Greeter {
  String greet();
}

class _Greeter implements Greeter {
  @override
  String greet() => 'hi';
}

class _Mod extends HostModule {
  _Mod(this.name, {this.deps = const [], this.log, this.failStart = false});

  @override
  final String name;
  final List<String> deps;
  final List<String>? log;
  final bool failStart;

  @override
  List<String> get dependsOn => deps;

  @override
  Future<void> start() async {
    if (failStart) throw StateError('boom');
    log?.add('start:$name');
  }

  @override
  Future<void> stop() async => log?.add('stop:$name');
}

class _GreeterModule extends HostModule {
  @override
  String get name => 'greeter';

  @override
  Future<void> configure(HostServices services) async =>
      services.provide<Greeter>(_Greeter(), owner: name);

  @override
  void mount(Router router) {
    router.get('/api/v1/hello', (_) async => HostResponse.ok({'ok': true}),
        access: Access.public);
    router.get('/api/v1/items/{id}',
        (r) async => HostResponse.ok({'id': r.pathParams['id'], 'who': r.principal?.accountId}));
    router.get('/api/v1/admin', (_) async => HostResponse.ok(null), access: Access.admin);
    router.get('/api/v1/crash', (_) async => throw StateError('secret body'));
  }
}

void main() {
  group('Registry', () {
    test('按依赖顺序启动，逆序停止', () async {
      final log = <String>[];
      final registry = Registry()
        ..register(_Mod('messages', deps: ['accounts'], log: log))
        ..register(_Mod('accounts', log: log))
        ..register(_Mod('memory', deps: ['messages'], log: log));
      await registry.boot();
      expect(log, ['start:accounts', 'start:messages', 'start:memory']);
      await registry.shutdown();
      expect(log.sublist(3), ['stop:memory', 'stop:messages', 'stop:accounts']);
    });

    test('缺依赖与循环依赖都被拒绝', () {
      final missing = Registry()..register(_Mod('a', deps: ['x']));
      expect(missing.resolveOrder, throwsStateError);
      final cycle = Registry()
        ..register(_Mod('a', deps: ['b']))
        ..register(_Mod('b', deps: ['a']));
      expect(cycle.resolveOrder, throwsStateError);
    });

    test('启动失败时回滚已启动模块', () async {
      final log = <String>[];
      final registry = Registry()
        ..register(_Mod('a', log: log))
        ..register(_Mod('b', deps: ['a'], log: log, failStart: true));
      await expectLater(registry.boot(), throwsStateError);
      expect(log, ['start:a', 'stop:a']);
    });

    test('服务重复登记被拒绝，缺失服务报错', () {
      final services = HostServices()..provide<Greeter>(_Greeter(), owner: 'a');
      expect(() => services.provide<Greeter>(_Greeter(), owner: 'b'), throwsStateError);
      expect(services.get<Greeter>().greet(), 'hi');
      expect(HostServices().maybeGet<Greeter>(), isNull);
      expect(() => HostServices().get<Greeter>(), throwsStateError);
    });
  });

  group('Router 与 Pipeline', () {
    late Pipeline pipeline;
    final errors = <Object>[];

    setUp(() async {
      final registry = Registry()..register(_GreeterModule());
      await registry.boot();
      pipeline = Pipeline(
        router: registry.router,
        authenticate: (req) async => switch (req.headers['authorization']) {
          'Bearer user' => const Principal(accountId: 'u1', deviceId: 'd1'),
          'Bearer admin' => const Principal(accountId: 'root', deviceId: 'd0', isAdmin: true),
          _ => null,
        },
        onError: (e, _, _) => errors.add(e),
      );
    });

    test('公开路由无需登录', () async {
      final res = await pipeline.handle(HostRequest(method: 'GET', path: '/api/v1/hello'));
      expect(res.status, 200);
    });

    test('默认要求登录，并解析路径参数', () async {
      final anon = await pipeline.handle(HostRequest(method: 'GET', path: '/api/v1/items/42'));
      expect(anon.status, 401);
      final res = await pipeline.handle(HostRequest(
        method: 'GET',
        path: '/api/v1/items/42',
        headers: {'authorization': 'Bearer user'},
      ));
      expect(res.status, 200);
      expect(res.json, {'id': '42', 'who': 'u1'});
    });

    test('管理员路由拒绝普通用户', () async {
      final user = await pipeline.handle(HostRequest(
          method: 'GET', path: '/api/v1/admin', headers: {'authorization': 'Bearer user'}));
      expect(user.status, 403);
      final admin = await pipeline.handle(HostRequest(
          method: 'GET', path: '/api/v1/admin', headers: {'authorization': 'Bearer admin'}));
      expect(admin.status, 200);
    });

    test('未知路由 404，异常转 500 且不泄露细节', () async {
      expect((await pipeline.handle(HostRequest(method: 'GET', path: '/nope'))).status, 404);
      final crash = await pipeline.handle(HostRequest(
          method: 'GET', path: '/api/v1/crash', headers: {'authorization': 'Bearer user'}));
      expect(crash.status, 500);
      expect(crash.encodeBody().contains('secret'), isFalse);
      expect(errors, isNotEmpty);
    });

    test('路由冲突被拒绝', () {
      final router = Router()..get('/api/v1/a/{x}', (_) async => HostResponse.ok(null));
      expect(() => router.get('/api/v1/a/{y}', (_) async => HostResponse.ok(null)),
          throwsStateError);
    });
  });
}
