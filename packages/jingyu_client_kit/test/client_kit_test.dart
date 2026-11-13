import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _Plugin extends ClientPlugin {
  _Plugin(this.manifest, this.onActivate);

  @override
  final PluginManifest manifest;
  final void Function(PluginRegistrar r) onActivate;

  @override
  Future<void> activate(PluginRegistrar registrar) async => onActivate(registrar);
}

PluginManifest _m(String id,
        {Set<PluginCapability> caps = const {}, int api = pluginApiVersion, bool hostOnly = false}) =>
    PluginManifest(id: id, name: id, version: '1.0.0', apiVersion: api, capabilities: caps, hostOnly: hostOnly);

void main() {
  group('PluginManifest', () {
    test('解析合法清单', () {
      final m = PluginManifest.fromJson({
        'id': 'jingyu.room.generator',
        'name': '房间生成',
        'version': '0.1.0',
        'apiVersion': 1,
        'capabilities': ['roomScene', 'modelInvoke'],
        'platforms': ['windows'],
        'license': 'MIT',
        'assetCredits': ['dsh-pet CC BY-NC-SA 4.0'],
      });
      expect(m.capabilities, {PluginCapability.roomScene, PluginCapability.modelInvoke});
      expect(m.platforms, {'windows'});
    });

    test('拒绝非法 id、版本、能力与平台', () {
      Map<String, Object?> base() => {'id': 'a.b', 'name': 'x', 'version': '1.0.0', 'apiVersion': 1};
      expect(() => PluginManifest.fromJson({...base(), 'id': 'NoDot'}), throwsFormatException);
      expect(() => PluginManifest.fromJson({...base(), 'version': '1.0'}), throwsFormatException);
      expect(() => PluginManifest.fromJson({...base(), 'capabilities': ['root']}), throwsFormatException);
      expect(() => PluginManifest.fromJson({...base(), 'platforms': ['ios']}), throwsFormatException);
      expect(() => PluginManifest.fromJson({...base()}..remove('apiVersion')), throwsFormatException);
    });
  });

  group('PluginHost', () {
    late PluginHost host;
    final sent = <String>[];

    setUp(() {
      sent.clear();
      host = PluginHost(
        environment: const PluginEnvironment(platform: 'android', isHostMachine: false),
        sendText: (c, t) async => sent.add('$c:$t'),
      );
    });

    test('按能力授权：未声明能力的登记失败并回滚', () async {
      final ok = await host.load(_Plugin(
        _m('x.bad'),
        (r) => r.addSlashCommand(SlashCommand(name: 'hi', description: '', run: (_, _) async => null)),
      ));
      expect(ok, isFalse);
      expect(host.errors.single.pluginId, 'x.bad');
      expect(host.commandsFor({}), isEmpty);
    });

    test('激活中途失败时已登记贡献全部回滚', () async {
      final ok = await host.load(_Plugin(_m('x.half', caps: {PluginCapability.slashCommands}), (r) {
        r.addSlashCommand(SlashCommand(name: 'a', description: '', run: (_, _) async => null));
        throw StateError('boom');
      }));
      expect(ok, isFalse);
      expect(host.commandsFor({}), isEmpty);
      expect(host.activeIds, isEmpty);
    });

    test('版本、平台与 hostOnly 不符被拒绝', () async {
      expect(await host.load(_Plugin(_m('x.old', api: 99), (_) {})), isFalse);
      expect(await host.load(_Plugin(_m('x.live2d', hostOnly: true), (_) {})), isFalse);
      expect(host.errors.map((e) => e.pluginId), ['x.old', 'x.live2d']);
    });

    test('斜杠指令按绑定能力显示并可执行', () async {
      await host.load(_Plugin(
        _m('x.draw', caps: {PluginCapability.slashCommands, PluginCapability.sendMessage}),
        (r) => r.addSlashCommand(SlashCommand(
          name: '画图',
          description: '生成图片',
          requiresAiCapability: 'image_gen',
          run: (args, ctx) async {
            await ctx.sendText('c1', '画：$args');
            return 'ok';
          },
        )),
      ));
      expect(host.commandsFor({'chat'}), isEmpty);
      expect(host.commandsFor({'chat', 'image_gen'}).single.name, '画图');
      expect(await host.runSlash('/画图 一只猫'), 'ok');
      expect(sent, ['c1:画：一只猫']);
      expect(await host.runSlash('/没有'), isNull);
    });

    test('同名指令冲突时后者加载失败', () async {
      SlashCommand cmd() => SlashCommand(name: 'x', description: '', run: (_, _) async => null);
      expect(await host.load(_Plugin(_m('a.one', caps: {PluginCapability.slashCommands}), (r) => r.addSlashCommand(cmd()))), isTrue);
      expect(await host.load(_Plugin(_m('a.two', caps: {PluginCapability.slashCommands}), (r) => r.addSlashCommand(cmd()))), isFalse);
      expect(host.activeIds, ['a.one']);
    });

    test('未申请 localStorage 时读存储抛错', () async {
      late PluginContext ctx;
      await host.load(_Plugin(_m('x.ctx'), (r) => ctx = r.context));
      expect(() => ctx.storage, throwsStateError);
      expect(() => ctx.sendText('c', 't'), throwsStateError);
    });
  });

  group('SyncCursor', () {
    test('连续前进、重复忽略、缺口报告', () {
      final cursor = SyncCursor();
      expect(cursor.accept(1), MergeOutcome.applied);
      expect(cursor.accept(1), MergeOutcome.duplicate);
      expect(cursor.accept(3), MergeOutcome.gap);
      expect(cursor.lastSeq, 1);
      expect(cursor.acceptPage([2, 3, 5, 6]), 3);
    });
  });

  group('Outbox', () {
    OutboxItem? dropped;
    setUp(() => dropped = null);

    test('按顺序发送，网络失败时保留队首', () async {
      final box = Outbox(newClientMsgId: () => 'id${DateTime.now().microsecondsSinceEpoch}');
      box.enqueue('c1', MessageKind.text, {'text': 'a'});
      box.enqueue('c1', MessageKind.text, {'text': 'b'});
      var calls = 0;
      final report = await box.flush((item) async {
        calls++;
        return calls == 1 ? const Ok<void>(null) : err<void>(FailureCode.unavailable, 'offline');
      });
      expect(report.sent, 1);
      expect(report.remaining, 1);
      expect(box.items.single.body['text'], 'b');
      expect(box.items.single.attempts, 1);
    });

    test('永久失败的条目被丢弃且不阻塞后续', () async {
      var n = 0;
      final box = Outbox(newClientMsgId: () => 'k${++n}');
      box.enqueue('c1', MessageKind.text, {'text': 'bad'});
      box.enqueue('c1', MessageKind.text, {'text': 'good'});
      final report = await box.flush(
        (item) async => item.body['text'] == 'bad'
            ? err<void>(FailureCode.forbidden, 'blocked')
            : const Ok<void>(null),
        onDropped: (item, _) => dropped = item,
      );
      expect(report.sent, 1);
      expect(report.remaining, 0);
      expect(dropped?.clientMsgId, 'k1');
    });
  });
}
