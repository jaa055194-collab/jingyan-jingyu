import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

class _Plugin extends ClientPlugin {
  _Plugin(this.manifest, this.onActivate);
  @override
  final PluginManifest manifest;
  final Future<void> Function(PluginRegistrar registrar) onActivate;
  @override
  Future<void> activate(PluginRegistrar registrar) => onActivate(registrar);
}

PluginManifest _manifest(String id, Set<PluginCapability> capabilities) =>
    PluginManifest(
      id: id,
      name: id,
      version: '1.0.0',
      apiVersion: pluginApiVersion,
      capabilities: capabilities,
    );

void main() {
  late PluginHost host;
  setUp(() {
    host = PluginHost(
      environment: const PluginEnvironment(
        platform: 'windows',
        isHostMachine: false,
      ),
      sendText: (_, _) async {},
    );
  });

  test(
    'activation storage survives first command and subsequent commands',
    () async {
      final plugin = _Plugin(
        _manifest('test.state', {
          PluginCapability.localStorage,
          PluginCapability.slashCommands,
        }),
        (registrar) async {
          registrar.context.storage['count'] = '10';
          registrar.addSlashCommand(
            SlashCommand(
              name: 'state',
              description: 'increment',
              run: (_, context) async {
                final next = int.parse(context.storage['count'] ?? '0') + 1;
                context.storage['count'] = '$next';
                return '$next';
              },
            ),
          );
        },
      );
      expect(await host.load(plugin), isTrue);
      expect(await host.runSlash('/state'), '11');
      expect(await host.runSlash('/state'), '12');
    },
  );

  test('identical storage keys are isolated between active plugins', () async {
    Future<void> activate(PluginRegistrar registrar) async {
      registrar.context.storage['count'] = '10';
      registrar.addSlashCommand(
        SlashCommand(
          name: registrar.context.pluginId,
          description: 'increment',
          run: (_, context) async {
            final next = int.parse(context.storage['count'] ?? '0') + 1;
            context.storage['count'] = '$next';
            return '$next';
          },
        ),
      );
    }

    await host.load(
      _Plugin(
        _manifest('test.one', {
          PluginCapability.localStorage,
          PluginCapability.slashCommands,
        }),
        activate,
      ),
    );
    await host.load(
      _Plugin(
        _manifest('test.two', {
          PluginCapability.localStorage,
          PluginCapability.slashCommands,
        }),
        activate,
      ),
    );
    expect(await host.runSlash('/test.one'), '11');
    expect(await host.runSlash('/test.two'), '11');
    expect(await host.runSlash('/test.one'), '12');
  });

  test('unload and reload starts a fresh activation state', () async {
    final plugin = _Plugin(
      _manifest('test.state', {
        PluginCapability.localStorage,
        PluginCapability.slashCommands,
      }),
      (registrar) async {
        registrar.context.storage['count'] = '10';
        registrar.addSlashCommand(
          SlashCommand(
            name: 'state',
            description: 'increment',
            run: (_, context) async {
              final next = int.parse(context.storage['count'] ?? '0') + 1;
              context.storage['count'] = '$next';
              return '$next';
            },
          ),
        );
      },
    );
    await host.load(plugin);
    await host.runSlash('/state');
    await host.unloadAll();
    expect(await host.runSlash('/state'), isNull);
    await host.load(plugin);
    expect(await host.runSlash('/state'), '11');
  });

  test(
    'failed activation rolls back and retry creates a fresh context',
    () async {
      var attempts = 0;
      final plugin = _Plugin(
        _manifest('test.retry', {
          PluginCapability.localStorage,
          PluginCapability.slashCommands,
        }),
        (registrar) async {
          attempts++;
          registrar.context.storage['attempt'] = '$attempts';
          registrar.addSlashCommand(
            SlashCommand(
              name: 'retry',
              description: 'show activation state',
              run: (_, context) async => context.storage['attempt'],
            ),
          );
          if (attempts == 1) throw StateError('activation failed');
        },
      );
      expect(await host.load(plugin), isFalse);
      expect(await host.runSlash('/retry'), isNull);
      expect(await host.load(plugin), isTrue);
      expect(await host.runSlash('/retry'), '2');
    },
  );

  test(
    'capability declarations are snapshotted when the plugin context is created',
    () async {
      final capabilities = <PluginCapability>{PluginCapability.slashCommands};
      final plugin = _Plugin(_manifest('test.mutable', capabilities), (
        registrar,
      ) async {
        registrar.addSlashCommand(
          SlashCommand(
            name: 'mutable',
            description: 'must not gain storage access',
            run: (_, context) async {
              try {
                context.storage;
                return 'allowed';
              } on StateError {
                return 'denied';
              }
            },
          ),
        );
      });
      expect(await host.load(plugin), isTrue);
      capabilities.add(PluginCapability.localStorage);
      expect(await host.runSlash('/mutable'), 'denied');
    },
  );

  test('captured context is unusable after unload', () async {
    late PluginContext captured;
    final plugin = _Plugin(
      _manifest('test.capture', {
        PluginCapability.localStorage,
        PluginCapability.sendMessage,
      }),
      (registrar) async {
        captured = registrar.context;
        captured.storage['key'] = 'value';
      },
    );
    expect(await host.load(plugin), isTrue);
    expect(captured.storage['key'], 'value');
    await host.unloadAll();
    expect(() => captured.storage, throwsStateError);
    expect(() => captured.sendText('c', 't'), throwsStateError);
  });

  test('command cannot access storage without declared capability', () async {
    final plugin = _Plugin(
      _manifest('test.denied', {PluginCapability.slashCommands}),
      (registrar) async {
        registrar.addSlashCommand(
          SlashCommand(
            name: 'denied',
            description: 'storage must be denied',
            run: (_, context) async => context.storage['key'],
          ),
        );
      },
    );
    expect(await host.load(plugin), isTrue);
    await expectLater(host.runSlash('/denied'), throwsStateError);
  });
}
