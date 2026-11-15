import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

Map<String, Object?> _validBundle() => {
      'id': 'jingyu.music.bundle',
      'name': '音乐房 bundle',
      'version': '1.2.0',
      'apiVersion': 1,
      'type': 'bundle',
      'icon': 'icon.svg',
      'locales': {'zh': 'locale/zh.json', 'en': 'locale/en.json'},
      'plugins': [
        {
          'runtime': 'webview',
          'entry': 'web/index.html',
          'slots': ['page.plugin', 'conversation.composer.actions'],
          'permissions': ['chat.send', 'storage'],
          'configSchema': 'config.schema.json',
          'network': 'host-gateway',
        },
        {
          'runtime': 'declarative',
          'id': 'jingyu.music.bundle.notifier',
          'slots': ['notification.action'],
        },
      ],
      'dependencies': [
        {'id': 'jingyu.room', 'version': '^1.2.0'},
      ],
      'platforms': ['android', 'windows'],
      'integrity': {'sha256': _rep('a', 64)},
    };

String _rep(String unit, int n) => List<String>.filled(n, unit).join();

void main() {
  group('PluginBundle.fromJson', () {
    test('解析合法 bundle（多行插件、依赖、locales、integrity）', () {
      final b = PluginBundle.fromJson(_validBundle());
      expect(b.id, 'jingyu.music.bundle');
      expect(b.version.toString(), '1.2.0');
      expect(b.apiVersion, 1);
      expect(b.type, 'bundle');
      expect(b.plugins, hasLength(2));
      expect(b.plugins.first.runtime, PluginRuntime.webview);
      expect(b.plugins.first.permissions, {'chat.send', 'storage'});
      expect(b.plugins.first.network, 'host-gateway');
      expect(b.plugins.last.runtime, PluginRuntime.declarative);
      expect(b.plugins.last.id, 'jingyu.music.bundle.notifier');
      expect(b.locales['zh'], 'locale/zh.json');
      expect(b.dependencies.single.id, 'jingyu.room');
      expect(b.integritySha256, _rep('a', 64));
      expect(b.platforms, {'android', 'windows'});
    });

    test('declarative 插件可不带 entry；type 可为 plugin', () {
      final b = PluginBundle.fromJson({
        'id': 'jingyu.data.pack',
        'name': '数据包',
        'version': '0.1.0',
        'apiVersion': 1,
        'type': 'plugin',
        'plugins': [
          {'runtime': 'declarative'},
        ],
      });
      expect(b.type, 'plugin');
      expect(b.plugins.single.entry, isNull);
      expect(b.platforms, {'android', 'windows'}); // 默认
    });

    test('依赖支持字符串 id@range 形式', () {
      final b = PluginBundle.fromJson({
        'id': 'jingyu.a.b',
        'name': 'a',
        'version': '1.0.0',
        'apiVersion': 1,
        'plugins': [
          {'runtime': 'webview', 'entry': 'index.html'},
        ],
        'dependencies': ['jingyu.room@>=1.2.0 <2.0.0'],
      });
      expect(b.dependencies.single.id, 'jingyu.room');
      expect(b.dependencies.single.constraint.allows(Version(1, 5, 0)), isTrue);
      expect(b.dependencies.single.constraint.allows(Version(2, 0, 0)), isFalse);
    });

    test('依赖对象可用 constraint 字段名', () {
      final b = PluginBundle.fromJson({
        'id': 'jingyu.a.b',
        'name': 'a',
        'version': '1.0.0',
        'apiVersion': 1,
        'plugins': [
          {'runtime': 'webview', 'entry': 'index.html'},
        ],
        'dependencies': [
          {'id': 'jingyu.room', 'constraint': '^1.0.0'},
        ],
      });
      expect(b.dependencies.single.raw, '^1.0.0');
    });
  });

  group('PluginBundle.fromJson 拒绝非法输入', () {
    Map<String, Object?> base() => {
          'id': 'jingyu.a.b',
          'name': 'a',
          'version': '1.0.0',
          'apiVersion': 1,
          'plugins': [
            {'runtime': 'webview', 'entry': 'index.html'},
          ],
        };

    test('非法 id / 语义化版本', () {
      expect(() => PluginBundle.fromJson({...base(), 'id': 'NoDot'}),
          throwsFormatException);
      expect(() => PluginBundle.fromJson({...base(), 'version': '1.0'}),
          throwsFormatException);
    });

    test('apiVersion 非整数 / type 非法', () {
      expect(() => PluginBundle.fromJson({...base(), 'apiVersion': '1'}),
          throwsFormatException);
      expect(() => PluginBundle.fromJson({...base(), 'type': 'weird'}),
          throwsFormatException);
    });

    test('plugins 为空 / 未知 runtime / webview 缺 entry', () {
      expect(() => PluginBundle.fromJson({...base(), 'plugins': []}),
          throwsFormatException);
      expect(
          () => PluginBundle.fromJson({
                ...base(),
                'plugins': [
                  {'runtime': 'native'},
                ],
              }),
          throwsFormatException);
      expect(
          () => PluginBundle.fromJson({
                ...base(),
                'plugins': [
                  {'runtime': 'webview'},
                ],
              }),
          throwsFormatException);
    });

    test('bundle 内插件 id 重复', () {
      expect(
          () => PluginBundle.fromJson({
                ...base(),
                'plugins': [
                  {'runtime': 'webview', 'entry': 'a.html', 'id': 'x.y'},
                  {'runtime': 'webview', 'entry': 'b.html', 'id': 'x.y'},
                ],
              }),
          throwsFormatException);
    });

    test('platforms 非法 / integrity.sha256 非法', () {
      expect(() => PluginBundle.fromJson({...base(), 'platforms': ['ios']}),
          throwsFormatException);
      expect(
          () => PluginBundle.fromJson({
                ...base(),
                'integrity': {'sha256': 'xyz'},
              }),
          throwsFormatException);
    });

    test('依赖版本区间非法 / 依赖字符串缺 @', () {
      expect(
          () => PluginBundle.fromJson({
                ...base(),
                'dependencies': [
                  {'id': 'jingyu.room', 'version': 'not-a-range!'},
                ],
              }),
          throwsFormatException);
      expect(
          () => PluginBundle.fromJson({
                ...base(),
                'dependencies': ['jingyu.room'],
              }),
          throwsFormatException);
    });

    test('network / icon / name / permissions 非法', () {
      expect(() => PluginBundle.fromJson({...base(), 'icon': 123}),
          throwsFormatException);
      expect(() => PluginBundle.fromJson({...base(), 'name': null}),
          throwsFormatException);
      expect(
          () => PluginBundle.fromJson({
                ...base(),
                'plugins': [
                  {'runtime': 'webview', 'entry': 'a.html', 'network': 'allow-all'},
                ],
              }),
          throwsFormatException);
      expect(
          () => PluginBundle.fromJson({
                ...base(),
                'plugins': [
                  {
                    'runtime': 'webview',
                    'entry': 'a.html',
                    'permissions': [1],
                  },
                ],
              }),
          throwsFormatException);
    });
  });

  group('依赖满足性 / API 兼容', () {
    PluginBundle bundleWith(List<Object?> deps) => PluginBundle.fromJson({
          'id': 'jingyu.a.b',
          'name': 'a',
          'version': '1.0.0',
          'apiVersion': 1,
          'plugins': [
            {'runtime': 'webview', 'entry': 'index.html'},
          ],
          'dependencies': deps,
        });

    test('全部满足时返回空', () {
      final b = bundleWith([
        {'id': 'jingyu.room', 'version': '^1.2.0'},
      ]);
      expect(b.unmetDependencies({'jingyu.room': '1.5.0'}), isEmpty);
    });

    test('未安装 / 版本不满足 / 版本非法都被检出', () {
      final b = bundleWith([
        {'id': 'jingyu.room', 'version': '^1.2.0'},
        {'id': 'jingyu.slow', 'version': '^2.0.0'},
        {'id': 'jingyu.bad', 'version': '^1.0.0'},
      ]);
      final unmet = b.unmetDependencies({
        'jingyu.slow': '1.9.0',
        'jingyu.bad': 'not-semver',
      });
      final ids = unmet.map((u) => u.id).toSet();
      expect(ids, {'jingyu.room', 'jingyu.slow', 'jingyu.bad'});
    });

    test('isApiCompatible 按主版本相等', () {
      final b = bundleWith([]);
      expect(b.isApiCompatible(1), isTrue);
      expect(b.isApiCompatible(2), isFalse);
    });
  });

  group('路径安全（复审修复）', () {
    Map<String, Object?> base() => {
          'id': 'jingyu.a.b',
          'name': 'a',
          'version': '1.0.0',
          'apiVersion': 1,
          'plugins': [
            {'runtime': 'webview', 'entry': 'index.html'},
          ],
        };

    test('icon / entry / configSchema / locales 不安全路径被拒', () {
      expect(
          () => PluginBundle.fromJson({...base(), 'icon': '../evil.svg'}),
          throwsFormatException);
      expect(
          () => PluginBundle.fromJson({
                ...base(),
                'locales': {'zh': '/abs.json'},
              }),
          throwsFormatException);
      expect(
          () => PluginBundle.fromJson({
                ...base(),
                'plugins': [
                  {'runtime': 'webview', 'entry': '../e.html'},
                ],
              }),
          throwsFormatException);
      expect(
          () => PluginBundle.fromJson({
                ...base(),
                'plugins': [
                  {
                    'runtime': 'webview',
                    'entry': 'index.html',
                    'configSchema': 'C:/x.json',
                  },
                ],
              }),
          throwsFormatException);
    });

    test('plugins[].id 大小写不敏感去重', () {
      expect(
          () => PluginBundle.fromJson({
                ...base(),
                'plugins': [
                  {'runtime': 'webview', 'entry': 'a.html', 'id': 'Abc'},
                  {'runtime': 'webview', 'entry': 'b.html', 'id': 'abc'},
                ],
              }),
          throwsFormatException);
    });
  });
}
