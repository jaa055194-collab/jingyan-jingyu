/// 插件管理器测试：安装 / 更新 / 启停 / 卸载 / 依赖 / 权限 / 配置 / 快照。
///
/// 统一使用真实 `buildPluginPackage` 构造插件包、真实 `loadPluginBundle` 加载，
/// 不使用 fake loader（契约 §5 要求测试跑在真实加载链路上）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_plugin_runtime/src/plugin_loader.dart';
import 'package:jingyu_plugin_runtime/src/plugin_manager.dart';
import 'package:test/test.dart';

const String _alpha = 'com.example.alpha';
const String _beta = 'com.example.beta';
const String _gamma = 'com.example.gamma';
const String _base = 'com.example.base';
const String _app = 'com.example.app';
const String _multi = 'com.example.multi';

const String _alphaEntry = 'com.example.alpha.plugin';
const String _baseEntry = 'com.example.base.plugin';
const String _appEntry = 'com.example.app.main';

DateTime _fixedClock() => DateTime.utc(2026, 1, 2, 3, 4, 5);

PluginManager _newManager({
  PluginManagerStore? store,
  DateTime Function()? clock,
}) {
  return PluginManager(
    store: store ?? InMemoryPluginManagerStore(),
    platform: 'windows',
    clock: clock ?? _fixedClock,
  );
}

Map<String, Object?> _entry({
  String? id,
  String runtime = 'webview',
  String? entry = 'index.html',
  List<String> slots = const <String>[],
  List<String> permissions = const <String>[],
  String? configSchema,
  String network = 'deny',
}) {
  final map = <String, Object?>{
    'runtime': runtime,
    'slots': slots,
    'permissions': permissions,
    'network': network,
  };
  if (id != null) map['id'] = id;
  if (entry != null) map['entry'] = entry;
  if (configSchema != null) map['configSchema'] = configSchema;
  return map;
}

BuiltPluginPackage _buildPackage({
  required String bundleId,
  String version = '1.0.0',
  String name = '测试插件',
  List<Map<String, Object?>>? plugins,
  List<Object?> dependencies = const <Object?>[],
  Map<String, List<int>>? files,
  int apiVersion = 1,
  List<String> platforms = const <String>['android', 'windows'],
}) {
  final entries =
      plugins ?? <Map<String, Object?>>[_entry(id: '$bundleId.plugin')];
  final defaultFiles = <String, List<int>>{
    'index.html': utf8.encode('<html><body>ok</body></html>'),
  };
  return buildPluginPackage(
    manifest: <String, Object?>{
      'id': bundleId,
      'name': name,
      'version': version,
      'apiVersion': apiVersion,
      'type': 'bundle',
      'plugins': entries,
      'dependencies': dependencies,
      'platforms': platforms,
    },
    files: files ?? defaultFiles,
  );
}

Future<PluginInstallOutcome> _install(
  PluginManager manager,
  BuiltPluginPackage package, {
  Set<String> grantedPermissions = const <String>{},
  bool userApproved = true,
  PluginInstallSource source = PluginInstallSource.imported,
}) {
  return manager.install(
    package.bytes,
    source: source,
    grantedPermissions: grantedPermissions,
    userApproved: userApproved,
  );
}

/// 依赖对：base（提供 `com.example.base.plugin`，1.2.0）+ app（依赖它）。
BuiltPluginPackage _basePackage({String version = '1.2.0'}) => _buildPackage(
  bundleId: _base,
  version: version,
  name: '基础插件',
  plugins: <Map<String, Object?>>[_entry(id: _baseEntry)],
);

BuiltPluginPackage _appPackage({String version = '1.0.0'}) => _buildPackage(
  bundleId: _app,
  version: version,
  name: '应用插件',
  plugins: <Map<String, Object?>>[_entry(id: _appEntry)],
  dependencies: <Object?>['$_baseEntry@^1.0.0'],
);

/// 可注入失败的测试 store。
class _TestStore implements PluginManagerStore {
  _TestStore({this.initial});

  PluginManagerState? initial;
  PluginManagerState? lastSaved;
  int loadCalls = 0;
  int saveCalls = 0;
  bool failSave = false;
  bool throwFormatLoad = false;
  bool throwGenericLoad = false;

  @override
  Future<PluginManagerState?> load() async {
    loadCalls++;
    if (throwFormatLoad) throw const FormatException('坏快照');
    if (throwGenericLoad) throw StateError('磁盘读取失败');
    return initial;
  }

  @override
  Future<void> save(PluginManagerState state) async {
    saveCalls++;
    if (failSave) throw StateError('磁盘写入失败');
    initial = state;
    lastSaved = state;
  }
}

InstalledPluginBundle _sampleBundle() {
  return InstalledPluginBundle(
    bundleId: 'com.example.demo',
    name: '演示插件',
    version: '1.2.3',
    entries: <LoadedPluginEntry>[
      const LoadedPluginEntry(
        id: 'com.example.demo.main',
        runtime: PluginRuntime.webview,
        entry: 'index.html',
        slots: <String>['conversation.message.card.demo'],
        permissions: <String>{'chat.send', 'storage'},
        configSchema: 'config.schema.json',
        configSchemaJson: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'theme': <String, Object?>{'type': 'string'},
          },
        },
        network: 'host-gateway',
      ),
    ],
    sha256Hex: 'a' * 64,
    source: PluginInstallSource.market,
    installedAt: DateTime.utc(2026, 5, 6, 7, 8, 9),
    enabled: true,
    grantedPermissions: const <String>{'chat.send', 'storage'},
    dependencies: <PluginDependency>[
      PluginDependency.fromJson('com.example.base@^1.0.0'),
    ],
  );
}

Map<String, Object?> _jsonRoundtrip(Map<String, Object?> value) {
  return jsonDecode(jsonEncode(value)) as Map<String, Object?>;
}

void main() {
  group('快照序列化', () {
    test('InstalledPluginBundle.toJson/fromJson 往返保留全部字段', () {
      final bundle = _sampleBundle();
      final restored = InstalledPluginBundle.fromJson(
        _jsonRoundtrip(bundle.toJson()),
      );

      expect(restored.bundleId, bundle.bundleId);
      expect(restored.name, bundle.name);
      expect(restored.version, bundle.version);
      expect(restored.sha256Hex, bundle.sha256Hex);
      expect(restored.source, PluginInstallSource.market);
      expect(restored.installedAt, bundle.installedAt);
      expect(restored.enabled, isTrue);
      expect(restored.grantedPermissions, <String>{'chat.send', 'storage'});
      expect(restored.dependencies, hasLength(1));
      expect(restored.dependencies.single.id, 'com.example.base');
      expect(restored.dependencies.single.raw, '^1.0.0');
      expect(restored.entries, hasLength(1));

      final entry = restored.entries.single;
      expect(entry.id, 'com.example.demo.main');
      expect(entry.runtime, PluginRuntime.webview);
      expect(entry.entry, 'index.html');
      expect(entry.slots, <String>['conversation.message.card.demo']);
      expect(entry.permissions, <String>{'chat.send', 'storage'});
      expect(entry.configSchema, 'config.schema.json');
      expect(entry.configSchemaJson!['type'], 'object');
      expect(entry.network, 'host-gateway');
    });

    test('PluginManagerState.toJson/fromJson 往返 bundles 与 config', () {
      final state = PluginManagerState(
        bundles: <InstalledPluginBundle>[_sampleBundle()],
        config: <String, Map<String, Object?>>{
          'com.example.demo': <String, Object?>{
            'theme': 'dark',
            'nested': <String, Object?>{
              'list': <Object?>[1, 2, true],
            },
          },
        },
      );
      final restored = PluginManagerState.fromJson(
        _jsonRoundtrip(state.toJson()),
      );

      expect(restored.schemaVersion, 1);
      expect(restored.bundles, hasLength(1));
      expect(restored.bundles.single.bundleId, 'com.example.demo');
      expect(restored.config['com.example.demo']!['theme'], 'dark');
      expect(
        ((restored.config['com.example.demo']!['nested']!
                as Map<String, Object?>)['list']!
            as List<Object?>),
        <Object?>[1, 2, true],
      );
    });

    test('PluginManagerState.fromJson 严格拒绝坏数据', () {
      expect(
        () => PluginManagerState.fromJson(<String, Object?>{}),
        throwsFormatException,
      );
      expect(
        () => PluginManagerState.fromJson(<String, Object?>{
          'schemaVersion': '1',
        }),
        throwsFormatException,
      );
      expect(
        () =>
            PluginManagerState.fromJson(<String, Object?>{'schemaVersion': 2}),
        throwsFormatException,
      );
      expect(
        () => PluginManagerState.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'bundles': 'bad',
        }),
        throwsFormatException,
      );
      expect(
        () => PluginManagerState.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'bundles': <Object?>[
            <String, Object?>{'bundleId': 'com.example.broken'},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => PluginManagerState.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'config': <String, Object?>{'com.example.demo': 'not-a-map'},
        }),
        throwsFormatException,
      );
      expect(
        () => PluginManagerState.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'unknownField': 1,
        }),
        throwsFormatException,
      );
    });

    test('InstalledPluginBundle.fromJson 拒绝非法 runtime / source / 时间 / sha', () {
      final invalidRuntime = _jsonRoundtrip(_sampleBundle().toJson());
      final entries = (invalidRuntime['entries']! as List<Object?>)
          .cast<Map<String, Object?>>();
      entries.first['runtime'] = 'native';
      expect(
        () => InstalledPluginBundle.fromJson(invalidRuntime),
        throwsFormatException,
      );

      final invalidSource = _jsonRoundtrip(_sampleBundle().toJson())
        ..['source'] = 'unknown';
      expect(
        () => InstalledPluginBundle.fromJson(invalidSource),
        throwsFormatException,
      );

      final invalidTime = _jsonRoundtrip(_sampleBundle().toJson())
        ..['installedAt'] = 'not-a-time';
      expect(
        () => InstalledPluginBundle.fromJson(invalidTime),
        throwsFormatException,
      );

      final badSha = _jsonRoundtrip(_sampleBundle().toJson())
        ..['sha256Hex'] = 'xyz';
      expect(
        () => InstalledPluginBundle.fromJson(badSha),
        throwsFormatException,
      );
    });

    test('PluginManagerState.fromJson 拒绝重复 bundleId', () {
      final state = PluginManagerState(
        bundles: <InstalledPluginBundle>[_sampleBundle(), _sampleBundle()],
      );
      expect(
        () => PluginManagerState.fromJson(_jsonRoundtrip(state.toJson())),
        throwsFormatException,
      );
    });
  });

  group('restore', () {
    test('restore 读取有效快照', () async {
      final store = _TestStore(
        initial: PluginManagerState(
          bundles: <InstalledPluginBundle>[_sampleBundle()],
          config: <String, Map<String, Object?>>{
            'com.example.demo': <String, Object?>{'theme': 'dark'},
          },
        ),
      );
      final manager = _newManager(store: store);
      await manager.restore();

      expect(manager.installed, hasLength(1));
      expect(manager.installed.single.bundleId, 'com.example.demo');
      expect(manager.snapshot.config['com.example.demo']!['theme'], 'dark');
      expect(manager.lastLoadError, isNull);
      expect(store.loadCalls, 1);
    });

    test('restore 空 store 得到空状态', () async {
      final store = _TestStore();
      final manager = _newManager(store: store);
      await manager.restore();

      expect(manager.installed, isEmpty);
      expect(manager.enabledBundleIds, isEmpty);
      expect(manager.lastLoadError, isNull);
    });

    test('restore 坏快照保持空状态并记录 lastLoadError', () async {
      final store = _TestStore()..throwFormatLoad = true;
      final manager = _newManager(store: store);
      await manager.restore();

      expect(manager.installed, isEmpty);
      expect(manager.lastLoadError, contains('坏快照'));
    });

    test('restore 不支持 schemaVersion 时保持空状态', () async {
      final store = _TestStore(
        initial: const PluginManagerState(schemaVersion: 2),
      );
      final manager = _newManager(store: store);
      await manager.restore();

      expect(manager.installed, isEmpty);
      expect(manager.lastLoadError, contains('schemaVersion'));
    });

    test('restore 读取抛异常时记录 lastLoadError 且不抛出', () async {
      final store = _TestStore()..throwGenericLoad = true;
      final manager = _newManager(store: store);
      await manager.restore();

      expect(manager.installed, isEmpty);
      expect(manager.lastLoadError, isNotNull);
    });

    test('restore 只能调用一次', () async {
      final manager = _newManager(store: _TestStore());
      await manager.restore();
      await expectLater(manager.restore(), throwsStateError);
    });
  });

  group('install', () {
    test('install 成功：审批后默认启用并持久化', () async {
      final store = _TestStore();
      final manager = _newManager(store: store);
      final package = _buildPackage(
        bundleId: _alpha,
        version: '1.2.0',
        name: 'Alpha 插件',
        plugins: <Map<String, Object?>>[
          _entry(
            id: _alphaEntry,
            permissions: <String>['chat.send', 'storage'],
          ),
        ],
      );

      final outcome = await _install(
        manager,
        package,
        grantedPermissions: <String>{'chat.send', 'storage'},
        source: PluginInstallSource.market,
      );

      expect(outcome.ok, isTrue);
      expect(outcome.bundleId, _alpha);
      expect(outcome.issue, isNull);

      final installed = manager.installed.single;
      expect(installed.bundleId, _alpha);
      expect(installed.name, 'Alpha 插件');
      expect(installed.version, '1.2.0');
      expect(installed.sha256Hex, package.sha256Hex);
      expect(installed.source, PluginInstallSource.market);
      expect(installed.installedAt, _fixedClock());
      expect(installed.enabled, isTrue);
      expect(installed.grantedPermissions, <String>{'chat.send', 'storage'});
      expect(installed.entries.single.id, _alphaEntry);
      expect(store.saveCalls, 1);
      expect(store.initial!.bundles.single.bundleId, _alpha);
    });

    test('install 未审批拒绝（即使零权限）', () async {
      final manager = _newManager();
      final package = _buildPackage(bundleId: _alpha);
      final outcome = await manager.install(
        package.bytes,
        source: PluginInstallSource.imported,
        userApproved: false,
      );

      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.approvalRequired);
      expect(manager.installed, isEmpty);
    });

    test('install 重复 bundleId 拒绝', () async {
      final manager = _newManager();
      final package = _buildPackage(bundleId: _alpha);
      await _install(manager, package);

      final outcome = await _install(manager, package);
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.alreadyInstalled);
      expect(manager.installed, hasLength(1));
    });

    test('install 权限未全部授予时拒绝', () async {
      final manager = _newManager();
      final package = _buildPackage(
        bundleId: _alpha,
        plugins: <Map<String, Object?>>[
          _entry(
            id: _alphaEntry,
            permissions: <String>['chat.send', 'message.read'],
          ),
        ],
      );

      final outcome = await _install(
        manager,
        package,
        grantedPermissions: <String>{'chat.send'},
      );
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.permissionNotGranted);
      expect(outcome.issue!.message, contains('message.read'));
      expect(manager.installed, isEmpty);
    });

    test('install 依赖未满足时拒绝', () async {
      final manager = _newManager();
      final outcome = await _install(manager, _appPackage());

      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.dependencyUnmet);
      expect(outcome.issue!.message, contains(_baseEntry));
      expect(manager.installed, isEmpty);
    });

    test('install 依赖已安装但未启用也可满足', () async {
      final manager = _newManager();
      expect((await _install(manager, _basePackage())).ok, isTrue);
      expect((await manager.setEnabled(_base, false)).ok, isTrue);

      final outcome = await _install(manager, _appPackage());
      expect(outcome.ok, isTrue);
      expect(manager.installedVersions[_baseEntry], '1.2.0');
      expect(manager.enabledVersions.containsKey(_baseEntry), isFalse);
    });

    test('install 非法包返回 loadFailed', () async {
      final manager = _newManager();
      final outcome = await manager.install(
        Uint8List.fromList(<int>[1, 2, 3, 4]),
        source: PluginInstallSource.imported,
        userApproved: true,
      );

      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.loadFailed);
      expect(outcome.issue!.message, isNotEmpty);
    });

    test('install expectedSha256Hex 不匹配返回 loadFailed', () async {
      final manager = _newManager();
      final package = _buildPackage(bundleId: _alpha);
      final outcome = await manager.install(
        package.bytes,
        source: PluginInstallSource.imported,
        userApproved: true,
        expectedSha256Hex: 'b' * 64,
      );

      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.loadFailed);
    });

    test('install 多行 bundle 合并 entries 与权限', () async {
      final manager = _newManager();
      final package = _buildPackage(
        bundleId: _multi,
        name: '多行插件',
        plugins: <Map<String, Object?>>[
          _entry(
            id: '$_multi.web',
            runtime: 'webview',
            entry: 'web/index.html',
            slots: <String>['conversation.message.card.demo'],
            permissions: <String>['chat.send'],
          ),
          _entry(
            id: '$_multi.dart',
            runtime: 'dart',
            entry: 'lib/main.dart',
            permissions: <String>['model.invoke'],
          ),
          _entry(
            id: '$_multi.data',
            runtime: 'declarative',
            entry: null,
            slots: <String>['settings.section.demo'],
            permissions: <String>['config'],
          ),
        ],
        files: <String, List<int>>{
          'web/index.html': utf8.encode('<html></html>'),
          'lib/main.dart': utf8.encode('void main() {}'),
        },
      );

      final outcome = await _install(
        manager,
        package,
        grantedPermissions: <String>{'chat.send', 'model.invoke', 'config'},
      );

      expect(outcome.ok, isTrue);
      final installed = manager.installed.single;
      expect(installed.entries, hasLength(3));
      expect(installed.entries.map((entry) => entry.runtime), <PluginRuntime>[
        PluginRuntime.webview,
        PluginRuntime.dart,
        PluginRuntime.declarative,
      ]);
      expect(installed.grantedPermissions, <String>{
        'chat.send',
        'model.invoke',
        'config',
      });
    });

    test('install 多行 bundle 的 configSchemaJson 被持久化', () async {
      final manager = _newManager();
      final package = _buildPackage(
        bundleId: _multi,
        plugins: <Map<String, Object?>>[
          _entry(
            id: '$_multi.web',
            entry: 'web/index.html',
            configSchema: 'config/schema.json',
          ),
        ],
        files: <String, List<int>>{
          'web/index.html': utf8.encode('<html></html>'),
          'config/schema.json': utf8.encode('{"type":"object"}'),
        },
      );

      expect((await _install(manager, package)).ok, isTrue);
      final entry = manager.installed.single.entries.single;
      expect(entry.configSchema, 'config/schema.json');
      expect(entry.configSchemaJson, <String, Object?>{'type': 'object'});
    });

    test('install store 保存失败时回滚且不提交内存状态', () async {
      final store = _TestStore()..failSave = true;
      final manager = _newManager(store: store);
      final package = _buildPackage(bundleId: _alpha);

      final outcome = await _install(manager, package);
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.storeFailed);
      expect(manager.installed, isEmpty);
      expect(store.initial, isNull);
    });
  });

  group('update', () {
    test('update 升级成功并保留 enabled/config', () async {
      final manager = _newManager();
      final v1 = _buildPackage(bundleId: _alpha, version: '1.0.0');
      expect((await _install(manager, v1)).ok, isTrue);
      expect(
        (await manager.setConfig(_alpha, <String, Object?>{
          'theme': 'dark',
        })).ok,
        isTrue,
      );
      expect((await manager.setEnabled(_alpha, false)).ok, isTrue);
      final installedAt = manager.installed.single.installedAt;

      final v2 = _buildPackage(
        bundleId: _alpha,
        version: '2.0.0',
        name: 'Alpha v2',
      );
      final outcome = await manager.update(v2.bytes);

      expect(outcome.ok, isTrue);
      final installed = manager.installed.single;
      expect(installed.version, '2.0.0');
      expect(installed.name, 'Alpha v2');
      expect(installed.enabled, isFalse);
      expect(installed.installedAt, installedAt);
      expect(manager.snapshot.config[_alpha]!['theme'], 'dark');
    });

    test('update 同版本或降级返回 versionNotNewer', () async {
      final manager = _newManager();
      expect(
        (await _install(
          manager,
          _buildPackage(bundleId: _alpha, version: '2.0.0'),
        )).ok,
        isTrue,
      );

      final same = await manager.update(
        _buildPackage(bundleId: _alpha, version: '2.0.0').bytes,
      );
      expect(same.ok, isFalse);
      expect(same.issue!.code, PluginManagerIssueCode.versionNotNewer);

      final downgrade = await manager.update(
        _buildPackage(bundleId: _alpha, version: '1.0.0').bytes,
      );
      expect(downgrade.ok, isFalse);
      expect(downgrade.issue!.code, PluginManagerIssueCode.versionNotNewer);
      expect(manager.installed.single.version, '2.0.0');
    });

    test('update 换 bundle id 返回 bundleIdChanged', () async {
      final manager = _newManager();
      expect(
        (await _install(manager, _buildPackage(bundleId: _alpha))).ok,
        isTrue,
      );

      // 条目 id 与已安装 alpha 相同，但 bundle id 换成 beta。
      final other = _buildPackage(
        bundleId: _beta,
        plugins: <Map<String, Object?>>[_entry(id: _alphaEntry)],
      );
      final outcome = await manager.update(other.bytes);

      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.bundleIdChanged);
      expect(manager.installed.single.bundleId, _alpha);
    });

    test('update 完全未安装的插件返回 notFound', () async {
      final manager = _newManager();
      expect(
        (await _install(manager, _buildPackage(bundleId: _alpha))).ok,
        isTrue,
      );

      final outcome = await manager.update(
        _buildPackage(bundleId: _gamma).bytes,
      );
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.notFound);
    });

    test('update 新增权限未授予时 permissionNotGranted', () async {
      final manager = _newManager();
      final v1 = _buildPackage(
        bundleId: _alpha,
        plugins: <Map<String, Object?>>[
          _entry(id: _alphaEntry, permissions: <String>['chat.send']),
        ],
      );
      expect(
        (await _install(
          manager,
          v1,
          grantedPermissions: <String>{'chat.send'},
        )).ok,
        isTrue,
      );

      final v2 = _buildPackage(
        bundleId: _alpha,
        version: '1.1.0',
        plugins: <Map<String, Object?>>[
          _entry(
            id: _alphaEntry,
            permissions: <String>['chat.send', 'message.read'],
          ),
        ],
      );
      final outcome = await manager.update(v2.bytes);
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.permissionNotGranted);
      expect(manager.installed.single.version, '1.0.0');
    });

    test('update 新增权限已授予但未审批时 approvalRequired', () async {
      final manager = _newManager();
      final v1 = _buildPackage(
        bundleId: _alpha,
        plugins: <Map<String, Object?>>[
          _entry(id: _alphaEntry, permissions: <String>['chat.send']),
        ],
      );
      expect(
        (await _install(
          manager,
          v1,
          grantedPermissions: <String>{'chat.send'},
        )).ok,
        isTrue,
      );

      final v2 = _buildPackage(
        bundleId: _alpha,
        version: '1.1.0',
        plugins: <Map<String, Object?>>[
          _entry(
            id: _alphaEntry,
            permissions: <String>['chat.send', 'message.read'],
          ),
        ],
      );
      final outcome = await manager.update(
        v2.bytes,
        grantedPermissions: <String>{'message.read'},
        userApproved: false,
      );
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.approvalRequired);
      expect(manager.installed.single.version, '1.0.0');
    });

    test('update 新增权限审批后成功并更新 grantedPermissions', () async {
      final manager = _newManager();
      final v1 = _buildPackage(
        bundleId: _alpha,
        plugins: <Map<String, Object?>>[
          _entry(id: _alphaEntry, permissions: <String>['chat.send']),
        ],
      );
      expect(
        (await _install(
          manager,
          v1,
          grantedPermissions: <String>{'chat.send'},
        )).ok,
        isTrue,
      );

      final v2 = _buildPackage(
        bundleId: _alpha,
        version: '1.1.0',
        plugins: <Map<String, Object?>>[
          _entry(
            id: _alphaEntry,
            permissions: <String>['chat.send', 'message.read'],
          ),
        ],
      );
      final outcome = await manager.update(
        v2.bytes,
        grantedPermissions: <String>{'message.read'},
        userApproved: true,
      );
      expect(outcome.ok, isTrue);
      expect(manager.installed.single.grantedPermissions, <String>{
        'chat.send',
        'message.read',
      });
    });

    test('update 无新增权限时无需再次审批', () async {
      final manager = _newManager();
      final v1 = _buildPackage(bundleId: _alpha, version: '1.0.0');
      expect((await _install(manager, v1)).ok, isTrue);

      final v2 = _buildPackage(bundleId: _alpha, version: '1.0.1');
      final outcome = await manager.update(v2.bytes);
      expect(outcome.ok, isTrue);
      expect(manager.installed.single.version, '1.0.1');
    });

    test('update 移除被其它已安装 bundle 依赖的 entry id 返回 dependentsExist', () async {
      final manager = _newManager();
      expect((await _install(manager, _basePackage())).ok, isTrue);
      expect((await _install(manager, _appPackage())).ok, isTrue);

      // v2 删除了 app 依赖的 _baseEntry。
      final v2 = _buildPackage(
        bundleId: _base,
        version: '2.0.0',
        plugins: <Map<String, Object?>>[_entry(id: 'com.example.base.v2')],
      );
      final outcome = await manager.update(v2.bytes);

      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.dependentsExist);
      expect(
        manager.installed
            .firstWhere((bundle) => bundle.bundleId == _base)
            .version,
        '1.2.0',
      );
      expect(manager.installedVersions[_baseEntry], '1.2.0');
    });

    test('update 移除无依赖方的 entry id 允许并完成替换', () async {
      final manager = _newManager();
      expect((await _install(manager, _basePackage())).ok, isTrue);

      final v2 = _buildPackage(
        bundleId: _base,
        version: '2.0.0',
        plugins: <Map<String, Object?>>[_entry(id: 'com.example.base.v2')],
      );
      final outcome = await manager.update(v2.bytes);

      expect(outcome.ok, isTrue);
      expect(manager.installed.single.version, '2.0.0');
      expect(manager.installed.single.entries.single.id, 'com.example.base.v2');
    });

    test('update store 失败时回滚到旧版本', () async {
      final store = _TestStore();
      final manager = _newManager(store: store);
      expect(
        (await _install(
          manager,
          _buildPackage(bundleId: _alpha, version: '1.0.0'),
        )).ok,
        isTrue,
      );

      store.failSave = true;
      final outcome = await manager.update(
        _buildPackage(bundleId: _alpha, version: '2.0.0').bytes,
      );

      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.storeFailed);
      expect(manager.installed.single.version, '1.0.0');
    });
  });

  group('setEnabled', () {
    test('停用被已启用插件依赖的 bundle 返回 dependentsExist', () async {
      final manager = _newManager();
      expect((await _install(manager, _basePackage())).ok, isTrue);
      expect((await _install(manager, _appPackage())).ok, isTrue);

      final outcome = await manager.setEnabled(_base, false);
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.dependentsExist);
      expect(manager.isPluginEnabled(_baseEntry), isTrue);
    });

    test('依赖方未启用时不阻止停用依赖', () async {
      final manager = _newManager();
      expect((await _install(manager, _basePackage())).ok, isTrue);
      expect((await _install(manager, _appPackage())).ok, isTrue);
      expect((await manager.setEnabled(_app, false)).ok, isTrue);

      final outcome = await manager.setEnabled(_base, false);
      expect(outcome.ok, isTrue);
      expect(manager.isPluginEnabled(_baseEntry), isFalse);
    });

    test('启用时依赖未启用返回 dependencyUnmet', () async {
      final manager = _newManager();
      expect((await _install(manager, _basePackage())).ok, isTrue);
      expect((await _install(manager, _appPackage())).ok, isTrue);
      expect((await manager.setEnabled(_app, false)).ok, isTrue);
      expect((await manager.setEnabled(_base, false)).ok, isTrue);

      final outcome = await manager.setEnabled(_app, true);
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.dependencyUnmet);
      expect(manager.isPluginEnabled(_appEntry), isFalse);
    });

    test('依赖启用后可以成功启用', () async {
      final manager = _newManager();
      expect((await _install(manager, _basePackage())).ok, isTrue);
      expect((await _install(manager, _appPackage())).ok, isTrue);
      expect((await manager.setEnabled(_app, false)).ok, isTrue);
      expect((await manager.setEnabled(_base, false)).ok, isTrue);
      expect((await manager.setEnabled(_base, true)).ok, isTrue);

      final outcome = await manager.setEnabled(_app, true);
      expect(outcome.ok, isTrue);
      expect(manager.isPluginEnabled(_appEntry), isTrue);
    });

    test('setEnabled 不存在的 bundle 返回 notFound', () async {
      final manager = _newManager();
      final outcome = await manager.setEnabled('com.example.missing', false);
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.notFound);
    });

    test('setEnabled store 失败时回滚', () async {
      final store = _TestStore();
      final manager = _newManager(store: store);
      expect(
        (await _install(manager, _buildPackage(bundleId: _alpha))).ok,
        isTrue,
      );

      store.failSave = true;
      final outcome = await manager.setEnabled(_alpha, false);
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.storeFailed);
      expect(manager.installed.single.enabled, isTrue);
    });
  });

  group('uninstall', () {
    test('卸载被其它 bundle 依赖的插件返回 dependentsExist', () async {
      final manager = _newManager();
      expect((await _install(manager, _basePackage())).ok, isTrue);
      expect((await _install(manager, _appPackage())).ok, isTrue);

      final outcome = await manager.uninstall(_base);
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.dependentsExist);
      expect(manager.installed, hasLength(2));
    });

    test('卸载成功删除 bundle 与 config', () async {
      final manager = _newManager();
      expect(
        (await _install(manager, _buildPackage(bundleId: _alpha))).ok,
        isTrue,
      );
      expect(
        (await manager.setConfig(_alpha, <String, Object?>{
          'theme': 'dark',
        })).ok,
        isTrue,
      );

      final outcome = await manager.uninstall(_alpha);
      expect(outcome.ok, isTrue);
      expect(manager.installed, isEmpty);
      expect(manager.snapshot.config, isEmpty);
      expect(manager.installedVersions, isEmpty);
    });

    test('依赖方卸载后可卸载依赖', () async {
      final manager = _newManager();
      expect((await _install(manager, _basePackage())).ok, isTrue);
      expect((await _install(manager, _appPackage())).ok, isTrue);

      expect((await manager.uninstall(_app)).ok, isTrue);
      final outcome = await manager.uninstall(_base);
      expect(outcome.ok, isTrue);
      expect(manager.installed, isEmpty);
    });

    test('uninstall 不存在返回 notFound', () async {
      final manager = _newManager();
      final outcome = await manager.uninstall('com.example.missing');
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.notFound);
    });

    test('uninstall store 失败时回滚', () async {
      final store = _TestStore();
      final manager = _newManager(store: store);
      expect(
        (await _install(manager, _buildPackage(bundleId: _alpha))).ok,
        isTrue,
      );

      store.failSave = true;
      final outcome = await manager.uninstall(_alpha);
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.storeFailed);
      expect(manager.installed, hasLength(1));
    });
  });

  group('setConfig', () {
    test('setConfig 保存 JSON 配置并持久化', () async {
      final store = _TestStore();
      final manager = _newManager(store: store);
      expect(
        (await _install(manager, _buildPackage(bundleId: _alpha))).ok,
        isTrue,
      );

      final config = <String, Object?>{
        'theme': 'dark',
        'nested': <String, Object?>{
          'list': <Object?>[1, 2, true],
          'flag': false,
        },
      };
      final outcome = await manager.setConfig(_alpha, config);
      expect(outcome.ok, isTrue);
      expect(manager.snapshot.config[_alpha], config);
      expect(store.initial!.config[_alpha], config);
    });

    test('setConfig 不可序列化时返回 invalidState 且不保存', () async {
      final store = _TestStore();
      final manager = _newManager(store: store);
      expect(
        (await _install(manager, _buildPackage(bundleId: _alpha))).ok,
        isTrue,
      );
      final saveCallsBefore = store.saveCalls;

      final outcome = await manager.setConfig(_alpha, <String, Object?>{
        'bad': Object(),
      });
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.invalidState);
      expect(store.saveCalls, saveCallsBefore);
      expect(manager.snapshot.config, isEmpty);
    });

    test('setConfig 不存在的 bundle 返回 notFound', () async {
      final manager = _newManager();
      final outcome = await manager.setConfig(
        'com.example.missing',
        <String, Object?>{'a': 1},
      );
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.notFound);
    });

    test('setConfig store 失败时回滚', () async {
      final store = _TestStore();
      final manager = _newManager(store: store);
      expect(
        (await _install(manager, _buildPackage(bundleId: _alpha))).ok,
        isTrue,
      );
      expect(
        (await manager.setConfig(_alpha, <String, Object?>{
          'theme': 'dark',
        })).ok,
        isTrue,
      );

      store.failSave = true;
      final outcome = await manager.setConfig(_alpha, <String, Object?>{
        'theme': 'light',
      });
      expect(outcome.ok, isFalse);
      expect(outcome.issue!.code, PluginManagerIssueCode.storeFailed);
      expect(manager.snapshot.config[_alpha]!['theme'], 'dark');
    });

    test('setConfig 深拷贝：外部修改不影响快照', () async {
      final manager = _newManager();
      expect(
        (await _install(manager, _buildPackage(bundleId: _alpha))).ok,
        isTrue,
      );

      final list = <Object?>[1, 2];
      final config = <String, Object?>{'list': list};
      expect((await manager.setConfig(_alpha, config)).ok, isTrue);

      list.add(3);
      expect(manager.snapshot.config[_alpha]!['list'], <Object?>[1, 2]);
    });
  });

  group('查询与状态', () {
    test('installedVersions 含未启用，enabledVersions 仅启用', () async {
      final manager = _newManager();
      expect((await _install(manager, _basePackage())).ok, isTrue);
      expect((await _install(manager, _appPackage())).ok, isTrue);
      expect((await manager.setEnabled(_app, false)).ok, isTrue);

      expect(manager.installedVersions, <String, String>{
        _baseEntry: '1.2.0',
        _appEntry: '1.0.0',
      });
      expect(manager.enabledVersions, <String, String>{_baseEntry: '1.2.0'});
      expect(manager.enabledBundleIds, <String>[_base]);
      expect(manager.isPluginEnabled(_baseEntry), isTrue);
      expect(manager.isPluginEnabled(_appEntry), isFalse);
    });

    test('installed 与 snapshot.bundles 不可变', () async {
      final manager = _newManager();
      expect(
        (await _install(manager, _buildPackage(bundleId: _alpha))).ok,
        isTrue,
      );

      expect(
        () => manager.installed.add(manager.installed.single),
        throwsUnsupportedError,
      );
      expect(
        () => manager.snapshot.bundles.add(manager.installed.single),
        throwsUnsupportedError,
      );
      expect(
        () => manager.snapshot.config[_alpha] = <String, Object?>{},
        throwsUnsupportedError,
      );
    });

    test('InMemoryPluginManagerStore 支持 load/save', () async {
      final store = InMemoryPluginManagerStore();
      expect(await store.load(), isNull);

      const state = PluginManagerState();
      await store.save(state);
      expect(await store.load(), same(state));
      expect(store.loadCalls, 2);
      expect(store.saveCalls, 1);
    });

    test('持久化恢复：新 manager 从同一 store 恢复完整状态', () async {
      final store = _TestStore();
      final first = _newManager(store: store);
      expect(
        (await _install(
          first,
          _buildPackage(bundleId: _alpha, version: '1.4.0'),
        )).ok,
        isTrue,
      );
      expect(
        (await first.setConfig(_alpha, <String, Object?>{'theme': 'dark'})).ok,
        isTrue,
      );
      expect((await first.setEnabled(_alpha, false)).ok, isTrue);

      final persistedJson = _jsonRoundtrip(store.initial!.toJson());
      final secondStore = _TestStore(
        initial: PluginManagerState.fromJson(persistedJson),
      );
      final second = _newManager(store: secondStore);
      await second.restore();

      expect(second.installed.single.version, '1.4.0');
      expect(second.installed.single.enabled, isFalse);
      expect(second.snapshot.config[_alpha]!['theme'], 'dark');
      expect(second.lastLoadError, isNull);
    });
  });
}
