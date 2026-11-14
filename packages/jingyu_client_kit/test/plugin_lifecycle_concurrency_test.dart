import 'dart:async';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

class _Plugin extends ClientPlugin {
  _Plugin(this.manifest, this.onActivate, {this.onDeactivate});

  @override
  final PluginManifest manifest;
  final Future<void> Function(PluginRegistrar) onActivate;
  final Future<void> Function()? onDeactivate;

  @override
  Future<void> activate(PluginRegistrar registrar) => onActivate(registrar);

  @override
  Future<void> deactivate() async => onDeactivate?.call();
}

class _Generator extends RoomGenerator {
  _Generator(this.id);

  @override
  final String id;
  @override
  List<String> get presets => const [];
  @override
  Future<RoomLayout> generate(RoomBrief brief, PluginContext context) async =>
      RoomLayout(style: brief.style, rooms: brief.rooms);
}

PluginManifest _manifest(String id, Set<PluginCapability> capabilities) =>
    PluginManifest(
      id: id,
      name: id,
      version: '1.0.0',
      apiVersion: pluginApiVersion,
      capabilities: capabilities,
    );

SlashCommand _command(String name, String result) =>
    SlashCommand(name: name, description: name, run: (_, _) async => result);

void main() {
  late PluginHost host;
  late List<String> sent;
  setUp(() {
    sent = [];
    host = PluginHost(
      environment: const PluginEnvironment(
        platform: 'windows',
        isHostMachine: false,
      ),
      sendText: (conversation, text) async => sent.add('$conversation:$text'),
    );
  });

  test(
    'pending ID rejects a privileged duplicate without sharing context',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      var duplicateActivated = false;
      final first = host.load(
        _Plugin(_manifest('test.same', {PluginCapability.slashCommands}), (
          r,
        ) async {
          r.addSlashCommand(
            SlashCommand(
              name: 'restricted',
              description: 'cannot send',
              run: (_, context) async {
                await context.sendText('private', 'forbidden');
                return 'sent';
              },
            ),
          );
          started.complete();
          await release.future;
        }),
      );
      await started.future;
      final duplicate = await host.load(
        _Plugin(
          _manifest('test.same', {PluginCapability.sendMessage}),
          (_) async => duplicateActivated = true,
        ),
      );
      release.complete();
      expect(await first, isTrue);
      expect(duplicate, isFalse);
      expect(duplicateActivated, isFalse);
      expect(host.activeIds, ['test.same']);
      await expectLater(host.runSlash('/restricted'), throwsStateError);
      expect(sent, isEmpty);
      expect(host.errors.single.pluginId, 'test.same');
    },
  );

  test(
    'failure discards only its own contributions during independent load',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      const caps = {
        PluginCapability.slashCommands,
        PluginCapability.roomScene,
        PluginCapability.messageRenderer,
        PluginCapability.settingsPage,
      };
      void contribute(PluginRegistrar r, String name) {
        r.addSlashCommand(_command(name, name));
        r.addRoomGenerator(_Generator(name));
        r.addMessageCard(name, '$name card');
        r.addSettingsSection(name, '$name settings');
      }

      final failing = host.load(
        _Plugin(_manifest('test.bad', caps), (r) async {
          contribute(r, 'bad');
          started.complete();
          await release.future;
          throw StateError('expected activation failure');
        }),
      );
      await started.future;
      // This must complete before bad is released: load remains concurrent.
      expect(
        await host.load(
          _Plugin(_manifest('test.good', caps), (r) async {
            contribute(r, 'good');
          }),
        ),
        isTrue,
      );
      expect(await host.runSlash('/good'), 'good');
      release.complete();
      expect(await failing, isFalse);
      expect(host.activeIds, ['test.good']);
      expect(await host.runSlash('/good'), 'good');
      expect(await host.runSlash('/bad'), isNull);
      expect(host.commandsFor({}).map((c) => c.name), ['good']);
      expect(host.roomGenerators.map((g) => g.id), ['good']);
      expect(host.cardRenderer('good'), 'good card');
      expect(host.cardRenderer('bad'), isNull);
      expect(host.settingsSections.map((s) => s.key), ['good']);
    },
  );

  test(
    'pending contributions are invisible until their context commits',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final loading = host.load(
        _Plugin(
          _manifest('test.pending', {
            PluginCapability.slashCommands,
            PluginCapability.roomScene,
            PluginCapability.messageRenderer,
            PluginCapability.settingsPage,
            PluginCapability.localStorage,
          }),
          (r) async {
            r.context.storage['state'] = 'ready';
            r.addSlashCommand(
              SlashCommand(
                name: 'pending',
                description: 'reads activation context',
                run: (_, context) async => context.storage['state'],
              ),
            );
            r.addRoomGenerator(_Generator('pending'));
            r.addMessageCard('pending', 'card');
            r.addSettingsSection('pending', 'settings');
            started.complete();
            await release.future;
          },
        ),
      );
      await started.future;
      expect(host.activeIds, isEmpty);
      expect(await host.runSlash('/pending'), isNull);
      expect(host.commandsFor({}), isEmpty);
      expect(host.roomGenerators, isEmpty);
      expect(host.cardRenderer('pending'), isNull);
      expect(host.settingsSections, isEmpty);
      release.complete();
      expect(await loading, isTrue);
      expect(await host.runSlash('/pending'), 'ready');
      expect(host.commandsFor({}).single.name, 'pending');
      expect(host.roomGenerators.single.id, 'pending');
      expect(host.cardRenderer('pending'), 'card');
      expect(host.settingsSections.single.key, 'pending');
    },
  );

  test(
    'unload revokes pending context and prevents late activation commit',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      late PluginRegistrar captured;
      final loading = host.load(
        _Plugin(
          _manifest('test.pending', {
            PluginCapability.slashCommands,
            PluginCapability.sendMessage,
            PluginCapability.localStorage,
          }),
          (r) async {
            captured = r;
            r.context.storage['key'] = 'old';
            r.addSlashCommand(_command('old', 'old'));
            started.complete();
            await release.future;
          },
        ),
      );
      await started.future;
      await host.unloadAll();
      expect(captured.context.has(PluginCapability.sendMessage), isFalse);
      expect(
        () => captured.context.sendText('after', 'unload'),
        throwsStateError,
      );
      expect(() => captured.context.storage, throwsStateError);
      expect(
        () => captured.addSlashCommand(_command('late', 'late')),
        throwsStateError,
      );
      release.complete();
      expect(await loading, isFalse);
      expect(host.activeIds, isEmpty);
      expect(await host.runSlash('/old'), isNull);
      expect(await host.runSlash('/late'), isNull);
      expect(sent, isEmpty);
    },
  );

  test(
    'old pending completion cannot replace or erase a reloaded ID',
    () async {
      for (final failOld in [false, true]) {
        final started = Completer<void>();
        final release = Completer<void>();
        final old = host.load(
          _Plugin(_manifest('test.reused', {PluginCapability.slashCommands}), (
            r,
          ) async {
            r.addSlashCommand(_command('reused', 'old'));
            started.complete();
            await release.future;
            if (failOld) throw StateError('old failure');
          }),
        );
        await started.future;
        await host.unloadAll();
        expect(
          await host.load(
            _Plugin(
              _manifest('test.reused', {PluginCapability.slashCommands}),
              (r) async => r.addSlashCommand(_command('reused', 'new')),
            ),
          ),
          isTrue,
        );
        release.complete();
        expect(await old, isFalse);
        expect(host.activeIds, ['test.reused']);
        expect(await host.runSlash('/reused'), 'new');
        await host.unloadAll();
      }
    },
  );

  test(
    'unload revokes active context before awaiting deactivate and rejects load',
    () async {
      final deactivating = Completer<void>();
      final release = Completer<void>();
      late PluginContext captured;
      final order = <String>[];
      expect(
        await host.load(
          _Plugin(
            _manifest('test.first', {PluginCapability.sendMessage}),
            (r) async => captured = r.context,
            onDeactivate: () async => order.add('first'),
          ),
        ),
        isTrue,
      );
      expect(
        await host.load(
          _Plugin(
            _manifest('test.second', {}),
            (_) async {},
            onDeactivate: () async {
              order.add('second');
              deactivating.complete();
              await release.future;
              throw StateError('deactivate failure must be isolated');
            },
          ),
        ),
        isTrue,
      );
      final unloading = host.unloadAll();
      await deactivating.future;
      var secondReturned = false;
      final secondUnload = host.unloadAll().then((_) => secondReturned = true);
      await Future<void>.value();
      expect(secondReturned, isFalse);
      expect(host.activeIds, isEmpty);
      expect(() => captured.sendText('during', 'unload'), throwsStateError);
      expect(
        await host.load(_Plugin(_manifest('test.during', {}), (_) async {})),
        isFalse,
      );
      release.complete();
      await unloading;
      await secondUnload;
      expect(secondReturned, isTrue);
      expect(order, ['second', 'first']);
      expect(sent, isEmpty);
      expect(
        await host.load(_Plugin(_manifest('test.after', {}), (_) async {})),
        isTrue,
      );
    },
  );

  test(
    'activate may await independent load and unload without a global lock',
    () async {
      bool? nested;
      final outer = await host.load(
        _Plugin(_manifest('test.outer', {}), (_) async {
          nested = await host.load(
            _Plugin(_manifest('test.inner', {}), (_) async {}),
          );
          await host.unloadAll();
        }),
      );
      expect(nested, isTrue);
      expect(outer, isFalse);
      expect(host.activeIds, isEmpty);
    },
  );

  test(
    'deactivate may reenter unload and load without duplicate cleanup',
    () async {
      var deactivations = 0;
      bool? reloaded;
      expect(
        await host.load(
          _Plugin(
            _manifest('test.reentrant', {}),
            (_) async {},
            onDeactivate: () async {
              deactivations++;
              if (deactivations == 1) {
                reloaded = await host.load(
                  _Plugin(
                    _manifest('test.during', {PluginCapability.slashCommands}),
                    (r) async =>
                        r.addSlashCommand(_command('during', 'during')),
                  ),
                );
                await host.unloadAll();
              }
            },
          ),
        ),
        isTrue,
      );
      await host.unloadAll();
      expect(reloaded, isFalse);
      expect(deactivations, 1);
      expect(host.activeIds, isEmpty);
      expect(await host.runSlash('/during'), isNull);
    },
  );

  test(
    'cancelled activation releases resources once and reserves its object through cleanup',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final cleaning = Completer<void>();
      final finishCleanup = Completer<void>();
      final events = StreamController<int>.broadcast(sync: true);
      addTearDown(events.close);
      StreamSubscription<int>? subscription;
      var received = 0;
      var activations = 0;
      var deactivations = 0;
      final plugin = _Plugin(
        _manifest('test.resource', {}),
        (_) async {
          activations++;
          subscription = events.stream.listen((_) => received++);
          if (activations == 1) {
            started.complete();
            await release.future;
          }
        },
        onDeactivate: () async {
          deactivations++;
          await subscription?.cancel();
          if (deactivations == 1) {
            cleaning.complete();
            await finishCleanup.future;
            throw StateError('cleanup failure is isolated');
          }
        },
      );
      final loading = host.load(plugin);
      await started.future;
      events.add(1);
      expect(received, 1);
      await host.unloadAll();
      await host.unloadAll();
      expect(await host.load(plugin), isFalse);
      expect(activations, 1);
      release.complete();
      await cleaning.future;
      events.add(2);
      expect(received, 1);
      expect(await host.load(plugin), isFalse);
      await host.unloadAll();
      finishCleanup.complete();
      expect(await loading, isFalse);
      expect(deactivations, 1);
      expect(host.activeIds, isEmpty);
      expect(await host.load(plugin), isTrue);
      await host.unloadAll();
      expect(deactivations, 2);
    },
  );

  test(
    'cancelled activation failure still cleans up and may reenter unload',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      var deactivations = 0;
      final loading = host.load(
        _Plugin(
          _manifest('test.cancelled', {}),
          (_) async {
            started.complete();
            await release.future;
            throw StateError('cancelled activation failed');
          },
          onDeactivate: () async {
            deactivations++;
            await host.unloadAll();
          },
        ),
      );
      await started.future;
      await host.unloadAll();
      release.complete();
      expect(await loading, isFalse);
      expect(deactivations, 1);
      expect(host.activeIds, isEmpty);
    },
  );

  test(
    'cancelled cleanup can unload while active cleanup awaits its load',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final activeCleaning = Completer<void>();
      var pendingDeactivations = 0;
      final pendingLoad = host.load(
        _Plugin(
          _manifest('test.pending_cycle', {}),
          (_) async {
            started.complete();
            await release.future;
          },
          onDeactivate: () async {
            pendingDeactivations++;
            await host.unloadAll();
          },
        ),
      );
      await started.future;
      expect(
        await host.load(
          _Plugin(
            _manifest('test.active_cycle', {}),
            (_) async {},
            onDeactivate: () async {
              activeCleaning.complete();
              expect(await pendingLoad, isFalse);
            },
          ),
        ),
        isTrue,
      );
      final unloading = host.unloadAll();
      await activeCleaning.future;
      final concurrentUnload = host.unloadAll();
      release.complete();
      await Future.wait([
        unloading,
        concurrentUnload,
        pendingLoad,
      ]).timeout(const Duration(seconds: 1));
      expect(pendingDeactivations, 1);
      expect(host.activeIds, isEmpty);
      expect(
        await host.load(
          _Plugin(_manifest('test.after_cycle', {}), (_) async {}),
        ),
        isTrue,
      );
      await host.unloadAll();
    },
  );

  test(
    'cancelled cleanup reenters a later unload without a stale generation token',
    () async {
      final started = Completer<void>();
      final releaseActivation = Completer<void>();
      final cleaning = Completer<void>();
      final releaseCleanup = Completer<void>();
      var cleanupCalls = 0;
      final pendingLoad = host.load(
        _Plugin(
          _manifest('test.old_pending', {}),
          (_) async {
            started.complete();
            await releaseActivation.future;
          },
          onDeactivate: () async {
            cleanupCalls++;
            cleaning.complete();
            await releaseCleanup.future;
            await host.unloadAll();
          },
        ),
      );
      await started.future;
      await host.unloadAll();
      releaseActivation.complete();
      await cleaning.future;
      expect(
        await host.load(
          _Plugin(
            _manifest('test.later_active', {}),
            (_) async {},
            onDeactivate: () async {
              releaseCleanup.complete();
              expect(await pendingLoad, isFalse);
            },
          ),
        ),
        isTrue,
      );
      await host.unloadAll().timeout(const Duration(seconds: 1));
      expect(await pendingLoad, isFalse);
      expect(cleanupCalls, 1);
      expect(host.activeIds, isEmpty);
    },
  );

  test('finished cleanup descendants wait for a subsequent unload', () async {
    final releaseDescendant = Completer<void>();
    final descendantCalling = Completer<void>();
    final releaseActive = Completer<void>();
    final activeCleaning = Completer<void>();
    var descendantReturned = false;
    late Future<void> descendant;
    expect(
      await host.load(
        _Plugin(
          _manifest('test.old_cleanup', {}),
          (_) async {},
          onDeactivate: () async {
            descendant = () async {
              await releaseDescendant.future;
              descendantCalling.complete();
              await host.unloadAll();
              descendantReturned = true;
            }();
          },
        ),
      ),
      isTrue,
    );
    await host.unloadAll();
    expect(
      await host.load(
        _Plugin(
          _manifest('test.new_cleanup', {}),
          (_) async {},
          onDeactivate: () async {
            activeCleaning.complete();
            await releaseActive.future;
          },
        ),
      ),
      isTrue,
    );
    final unloading = host.unloadAll();
    await activeCleaning.future;
    releaseDescendant.complete();
    await descendantCalling.future;
    await Future<void>.value();
    expect(descendantReturned, isFalse);
    releaseActive.complete();
    await unloading;
    await descendant;
    expect(descendantReturned, isTrue);
  });

  test(
    'pending command and card names are reserved until activation fails',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final first = host.load(
        _Plugin(
          _manifest('test.reserving', {
            PluginCapability.slashCommands,
            PluginCapability.messageRenderer,
          }),
          (r) async {
            r.addSlashCommand(_command('reserved', 'first'));
            r.addMessageCard('reserved', 'first');
            started.complete();
            await release.future;
            throw StateError('release reservations');
          },
        ),
      );
      await started.future;
      expect(
        await host.load(
          _Plugin(
            _manifest('test.command', {PluginCapability.slashCommands}),
            (r) async => r.addSlashCommand(_command('reserved', 'second')),
          ),
        ),
        isFalse,
      );
      expect(
        await host.load(
          _Plugin(
            _manifest('test.card', {PluginCapability.messageRenderer}),
            (r) async => r.addMessageCard('reserved', 'second'),
          ),
        ),
        isFalse,
      );
      release.complete();
      expect(await first, isFalse);
      expect(
        await host.load(
          _Plugin(
            _manifest('test.reserving', {
              PluginCapability.slashCommands,
              PluginCapability.messageRenderer,
            }),
            (r) async {
              r.addSlashCommand(_command('reserved', 'retry'));
              r.addMessageCard('reserved', 'retry');
            },
          ),
        ),
        isTrue,
      );
      expect(await host.runSlash('/reserved'), 'retry');
      expect(host.cardRenderer('reserved'), 'retry');
    },
  );
}
