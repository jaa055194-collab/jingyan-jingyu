import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class P extends ClientPlugin {
  P(this.caps);
  final Set<PluginCapability> caps;
  late PluginContext context;
  @override
  PluginManifest get manifest => PluginManifest(
    id: 'x.callbacks',
    name: 'test',
    version: '1.0.0',
    apiVersion: 1,
    capabilities: caps,
  );
  @override
  Future<void> activate(PluginRegistrar r) async {
    context = r.context;
  }
}

void main() {
  test(
    'read and invoke denied without declaration, authorized callbacks carry plugin identity',
    () async {
      final calls = <String>[];
      final host = PluginHost(
        environment: const PluginEnvironment(
          platform: 'windows',
          isHostMachine: false,
        ),
        sendText: (_, _) async {},
        readConversation: (pluginId, conversationId) async {
          calls.add('$pluginId:$conversationId');
          return const Ok<List<MessageEventFrame>>([]);
        },
        modelInvoke: (pluginId, request) async {
          calls.add('$pluginId:${request.aiId}:${request.capability}');
          return const Ok<Map<String, Object?>>({'text': 'ok'});
        },
      );
      final denied = P({});
      await host.load(denied);
      expect(() => denied.context.readConversation('c'), throwsStateError);
      expect(
        () => denied.context.modelInvoke(
          const PluginModelRequest(aiId: 'ai', capability: 'chat', input: {}),
        ),
        throwsStateError,
      );
      expect(calls, isEmpty);
      await host.unloadAll();
      final allowed = P({
        PluginCapability.readConversation,
        PluginCapability.modelInvoke,
      });
      await host.load(allowed);
      expect((await allowed.context.readConversation('c')).isOk, isTrue);
      expect(
        (await allowed.context.modelInvoke(
          const PluginModelRequest(
            aiId: 'ai',
            capability: 'chat',
            input: {'prompt': 'hi'},
          ),
        )).value,
        {'text': 'ok'},
      );
      expect(calls, ['x.callbacks:c', 'x.callbacks:ai:chat']);
    },
  );
  test('missing host callbacks fail closed with unavailable result', () async {
    final host = PluginHost(
      environment: const PluginEnvironment(
        platform: 'windows',
        isHostMachine: false,
      ),
      sendText: (_, _) async {},
    );
    final plugin = P({
      PluginCapability.readConversation,
      PluginCapability.modelInvoke,
    });
    await host.load(plugin);
    expect(
      (await plugin.context.readConversation('c')).failureOrNull?.code,
      FailureCode.unavailable,
    );
    expect(
      (await plugin.context.modelInvoke(
        const PluginModelRequest(aiId: 'ai', capability: 'chat', input: {}),
      )).failureOrNull?.code,
      FailureCode.unavailable,
    );
  });
}
