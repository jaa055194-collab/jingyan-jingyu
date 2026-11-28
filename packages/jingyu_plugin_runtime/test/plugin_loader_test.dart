import 'dart:convert';
import 'dart:typed_data';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_plugin_runtime/src/plugin_loader.dart';
import 'package:test/test.dart';

/// 一份合法的多行 bundle `plugin.json`（webview + dart + declarative）。
Map<String, Object?> _validBundle() => {
  'id': 'jingyu.music.bundle',
  'name': '音乐房 bundle',
  'version': '1.2.0',
  'apiVersion': 1,
  'type': 'bundle',
  'plugins': [
    {
      'runtime': 'webview',
      'id': 'jingyu.music.bundle.player',
      'entry': 'web/index.html',
      'slots': ['page.plugin', 'conversation.composer.actions'],
      'permissions': ['chat.send', 'storage'],
      'configSchema': 'config.schema.json',
      'network': 'host-gateway',
    },
    {
      'runtime': 'dart',
      'id': 'jingyu.music.bundle.engine',
      'entry': 'lib/engine.dart',
      'permissions': ['storage'],
    },
    {
      'runtime': 'declarative',
      'id': 'jingyu.music.bundle.presets',
      'slots': ['conversation.message.card.music'],
    },
  ],
  'platforms': ['android', 'windows'],
};

Map<String, List<int>> _validFiles() => {
  'web/index.html': utf8.encode('<html>music</html>'),
  'lib/engine.dart': utf8.encode('void main() {}'),
  'config.schema.json': utf8.encode('{"type":"object","properties":{}}'),
};

BuiltPluginPackage _build({
  Map<String, Object?>? bundle,
  Map<String, List<int>>? files,
}) => buildPluginPackage(
  manifest: bundle ?? _validBundle(),
  files: files ?? _validFiles(),
);

bool _has(PluginBundleLoadResult r, PluginLoadIssueCode code) =>
    r.issues.any((i) => i.code == code);

/// 单行插件 bundle（无 id，加载时回退为 bundle id）。
Map<String, Object?> _singlePluginBundle({
  String runtime = 'webview',
  String? entry = 'web/index.html',
}) => {
  'id': 'jingyu.single.bundle',
  'name': '单插件',
  'version': '0.1.0',
  'apiVersion': 1,
  'plugins': [
    {'runtime': runtime, 'entry': ?entry},
  ],
};

void main() {
  group('loadPluginBundle：合法路径', () {
    test('合法多行 bundle（webview+dart+declarative）全部字段解析正确', () {
      final built = _build();
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      expect(r.issues, isEmpty);
      expect(r.sha256Hex, built.sha256Hex);
      expect(r.bundle, isNotNull);

      final loaded = r.bundle!;
      expect(loaded.bundle.id, 'jingyu.music.bundle');
      expect(loaded.bundle.version.toString(), '1.2.0');
      expect(loaded.entries, hasLength(3));
      expect(loaded.files.keys, contains('web/index.html'));

      final webview = loaded.entries[0];
      expect(webview.id, 'jingyu.music.bundle.player');
      expect(webview.runtime, PluginRuntime.webview);
      expect(webview.entry, 'web/index.html');
      expect(webview.slots, ['page.plugin', 'conversation.composer.actions']);
      expect(webview.permissions, {'chat.send', 'storage'});
      expect(webview.configSchema, 'config.schema.json');
      expect(webview.configSchemaJson?['type'], 'object');
      expect(() => webview.configSchemaJson!['x'] = 1, throwsUnsupportedError);
      expect(webview.network, 'host-gateway');

      final dart = loaded.entries[1];
      expect(dart.id, 'jingyu.music.bundle.engine');
      expect(dart.runtime, PluginRuntime.dart);
      expect(dart.entry, 'lib/engine.dart');
      expect(dart.configSchema, isNull);
      expect(dart.configSchemaJson, isNull);
      expect(dart.network, 'deny');

      final declarative = loaded.entries[2];
      expect(declarative.id, 'jingyu.music.bundle.presets');
      expect(declarative.runtime, PluginRuntime.declarative);
      expect(declarative.entry, isNull);
      expect(declarative.slots, ['conversation.message.card.music']);
    });

    test('单插件 bundle 缺 id 时回退为 bundle id', () {
      final built = _build(
        bundle: _singlePluginBundle(),
        files: {'web/index.html': utf8.encode('<html></html>')},
      );
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      expect(r.bundle!.entries.single.id, 'jingyu.single.bundle');
      expect(r.bundle!.entries.single.runtime, PluginRuntime.webview);
    });

    test('declarative 给出且存在的 entry 正常通过', () {
      final built = _build(
        bundle: _singlePluginBundle(
          runtime: 'declarative',
          entry: 'data/seed.json',
        ),
        files: {'data/seed.json': utf8.encode('{}')},
      );
      final r = loadPluginBundle(built.bytes, platform: 'windows');
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      expect(r.bundle!.entries.single.entry, 'data/seed.json');
    });

    test('hostApiVersion 与 bundle 一致时通过', () {
      final built = _build();
      final r = loadPluginBundle(
        built.bytes,
        platform: 'android',
        hostApiVersion: 1,
      );
      expect(r.ok, isTrue, reason: r.issues.join(', '));
    });

    test('结果列表不可修改', () {
      final built = _build();
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      expect(() => r.issues.clear(), throwsUnsupportedError);
      expect(() => r.bundle!.entries.clear(), throwsUnsupportedError);
    });
  });

  group('loadPluginBundle：包与清单错误', () {
    test('空字节 => packageInvalid，bundle 为 null', () {
      final r = loadPluginBundle(Uint8List(0), platform: 'android');
      expect(r.ok, isFalse);
      expect(r.bundle, isNull);
      expect(_has(r, PluginLoadIssueCode.packageInvalid), isTrue);
      expect(r.issues, isNotEmpty);
      expect(r.issues.every((i) => i.message.isNotEmpty), isTrue);
    });

    test('非 zip 字节 => packageInvalid', () {
      final r = loadPluginBundle(
        Uint8List.fromList(List<int>.generate(80, (i) => (i * 31) % 256)),
        platform: 'android',
      );
      expect(r.ok, isFalse);
      expect(r.bundle, isNull);
      expect(_has(r, PluginLoadIssueCode.packageInvalid), isTrue);
    });

    test('期望 sha 不符 => packageInvalid（保留实际 sha）', () {
      final built = _build();
      final r = loadPluginBundle(
        built.bytes,
        platform: 'android',
        expectedSha256Hex: '0' * 64,
      );
      expect(r.ok, isFalse);
      expect(_has(r, PluginLoadIssueCode.packageInvalid), isTrue);
      expect(r.sha256Hex, built.sha256Hex);
    });

    test('plugin.json 不满足 bundle 契约 => bundleInvalid', () {
      // 能通过单插件 PluginManifest 校验（id/name/version/apiVersion 齐全），
      // 但缺少 bundle 必需的 plugins 数组 => bundleInvalid。
      final built = _build(
        bundle: {
          'id': 'jingyu.bad.bundle',
          'name': '坏包',
          'version': '1.0.0',
          'apiVersion': 1,
        },
      );
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isFalse);
      expect(r.bundle, isNull);
      expect(_has(r, PluginLoadIssueCode.bundleInvalid), isTrue);
    });

    test('未知 runtime => bundleInvalid', () {
      final built = _build(
        bundle: {
          'id': 'jingyu.bad.bundle',
          'name': '坏包',
          'version': '1.0.0',
          'apiVersion': 1,
          'plugins': [
            {'runtime': 'native', 'entry': 'index.html'},
          ],
        },
      );
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isFalse);
      expect(_has(r, PluginLoadIssueCode.bundleInvalid), isTrue);
    });
  });

  group('loadPluginBundle：apiVersion / platform', () {
    test('apiVersion 与宿主不一致 => apiVersionMismatch', () {
      final bundle = _validBundle()..['apiVersion'] = 2;
      final built = _build(bundle: bundle);
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isFalse);
      expect(r.bundle, isNull);
      expect(_has(r, PluginLoadIssueCode.apiVersionMismatch), isTrue);
    });

    test('platform 不在声明列表 => platformUnsupported', () {
      final bundle = _validBundle()..['platforms'] = ['windows'];
      final built = _build(bundle: bundle);
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isFalse);
      expect(_has(r, PluginLoadIssueCode.platformUnsupported), isTrue);
    });

    test('platform 命中 => 通过', () {
      final bundle = _validBundle()..['platforms'] = ['windows'];
      final built = _build(bundle: bundle);
      final r = loadPluginBundle(built.bytes, platform: 'windows');
      expect(r.ok, isTrue, reason: r.issues.join(', '));
    });
  });

  group('loadPluginBundle：入口文件', () {
    test('webview 入口文件缺失 => missingEntryFile（含 path）', () {
      final built = _build(bundle: _singlePluginBundle(), files: {});
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isFalse);
      expect(_has(r, PluginLoadIssueCode.missingEntryFile), isTrue);
      expect(
        r.issues
            .where((i) => i.code == PluginLoadIssueCode.missingEntryFile)
            .any((i) => i.path == 'web/index.html'),
        isTrue,
      );
    });

    test('dart 入口文件缺失 => missingEntryFile', () {
      final built = _build(
        bundle: _singlePluginBundle(runtime: 'dart', entry: 'lib/missing.dart'),
        files: {},
      );
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isFalse);
      expect(_has(r, PluginLoadIssueCode.missingEntryFile), isTrue);
    });

    test('declarative 的 entry 给出但缺失 => missingEntryFile', () {
      final built = _build(
        bundle: _singlePluginBundle(
          runtime: 'declarative',
          entry: 'data/seed.json',
        ),
        files: {},
      );
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isFalse);
      expect(_has(r, PluginLoadIssueCode.missingEntryFile), isTrue);
    });
  });

  group('loadPluginBundle：configSchema', () {
    Map<String, Object?> bundleWithConfig(String path) {
      final bundle = _singlePluginBundle();
      final plugin = (bundle['plugins'] as List).first as Map<String, Object?>;
      plugin['configSchema'] = path;
      return bundle;
    }

    test('configSchema 文件缺失 => configInvalid', () {
      final built = _build(
        bundle: bundleWithConfig('config.json'),
        files: {'web/index.html': utf8.encode('<html></html>')},
      );
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isFalse);
      expect(_has(r, PluginLoadIssueCode.configInvalid), isTrue);
    });

    test('configSchema 非法 JSON => configInvalid', () {
      final built = _build(
        bundle: bundleWithConfig('config.json'),
        files: {
          'web/index.html': utf8.encode('<html></html>'),
          'config.json': utf8.encode('not json'),
        },
      );
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isFalse);
      expect(_has(r, PluginLoadIssueCode.configInvalid), isTrue);
    });

    test('configSchema 顶层不是对象 => configInvalid', () {
      final built = _build(
        bundle: bundleWithConfig('config.json'),
        files: {
          'web/index.html': utf8.encode('<html></html>'),
          'config.json': utf8.encode('[]'),
        },
      );
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isFalse);
      expect(_has(r, PluginLoadIssueCode.configInvalid), isTrue);
    });

    test('configSchema 的 type 不是字符串 => configInvalid', () {
      final built = _build(
        bundle: bundleWithConfig('config.json'),
        files: {
          'web/index.html': utf8.encode('<html></html>'),
          'config.json': utf8.encode('{"type":5}'),
        },
      );
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isFalse);
      expect(_has(r, PluginLoadIssueCode.configInvalid), isTrue);
    });
  });

  group('loadPluginBundle：依赖', () {
    Map<String, Object?> bundleWithDependencies() => {
      ..._singlePluginBundle(),
      'dependencies': [
        {'id': 'jingyu.room', 'version': '^1.2.0'},
      ],
    };

    test('依赖未安装 => dependencyUnmet（message 含 id）', () {
      final built = _build(
        bundle: bundleWithDependencies(),
        files: {'web/index.html': utf8.encode('<html></html>')},
      );
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isFalse);
      expect(_has(r, PluginLoadIssueCode.dependencyUnmet), isTrue);
      expect(
        r.issues
            .where((i) => i.code == PluginLoadIssueCode.dependencyUnmet)
            .any((i) => i.message.contains('jingyu.room')),
        isTrue,
      );
    });

    test('依赖版本不满足 => dependencyUnmet', () {
      final built = _build(
        bundle: bundleWithDependencies(),
        files: {'web/index.html': utf8.encode('<html></html>')},
      );
      final r = loadPluginBundle(
        built.bytes,
        platform: 'android',
        installedVersions: {'jingyu.room': '1.0.0'},
      );
      expect(r.ok, isFalse);
      expect(_has(r, PluginLoadIssueCode.dependencyUnmet), isTrue);
    });

    test('依赖版本满足 => 通过', () {
      final built = _build(
        bundle: bundleWithDependencies(),
        files: {'web/index.html': utf8.encode('<html></html>')},
      );
      final r = loadPluginBundle(
        built.bytes,
        platform: 'android',
        installedVersions: {'jingyu.room': '1.5.0'},
      );
      expect(r.ok, isTrue, reason: r.issues.join(', '));
    });

    test('已安装版本号非法 => dependencyUnmet', () {
      final built = _build(
        bundle: bundleWithDependencies(),
        files: {'web/index.html': utf8.encode('<html></html>')},
      );
      final r = loadPluginBundle(
        built.bytes,
        platform: 'android',
        installedVersions: {'jingyu.room': 'not-a-version'},
      );
      expect(r.ok, isFalse);
      expect(_has(r, PluginLoadIssueCode.dependencyUnmet), isTrue);
    });
  });

  group('loadPluginBundle：重复插件 id', () {
    test('多行 bundle 中缺少 id => duplicatePluginId', () {
      final built = _build(
        bundle: {
          'id': 'jingyu.multi.bundle',
          'name': '多行',
          'version': '1.0.0',
          'apiVersion': 1,
          'plugins': [
            {'runtime': 'declarative'},
            {'runtime': 'declarative'},
          ],
        },
        files: {},
      );
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isFalse);
      expect(_has(r, PluginLoadIssueCode.duplicatePluginId), isTrue);
    });

    test('回退 id 与显式 id 冲突（不区分大小写）=> duplicatePluginId', () {
      final built = _build(
        bundle: {
          'id': 'jingyu.multi.bundle',
          'name': '多行',
          'version': '1.0.0',
          'apiVersion': 1,
          'plugins': [
            {'runtime': 'declarative'},
            {'runtime': 'declarative', 'id': 'Jingyu.Multi.Bundle'},
          ],
        },
        files: {},
      );
      final r = loadPluginBundle(built.bytes, platform: 'android');
      expect(r.ok, isFalse);
      expect(_has(r, PluginLoadIssueCode.duplicatePluginId), isTrue);
    });
  });
}
