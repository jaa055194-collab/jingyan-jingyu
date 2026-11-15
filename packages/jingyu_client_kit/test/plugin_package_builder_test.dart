import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

const Map<String, Object> _manifest = {
  'id': 'jingyu.demo.pkg',
  'name': '示例插件',
  'version': '0.1.0',
  'apiVersion': 1,
  'capabilities': ['slashCommands', 'sendMessage'],
  'platforms': ['android', 'windows'],
};

void main() {
  group('buildPluginPackage', () {
    test('构建结果可通过 validatePluginPackage（打包↔校验往返）', () {
      final built = buildPluginPackage(
        manifest: _manifest,
        files: {
          'web/index.html': utf8.encode('<html></html>'),
          'assets/icon.svg': utf8.encode('<svg/>'),
        },
      );
      final v = validatePluginPackage(built.bytes);
      expect(v.ok, isTrue, reason: v.issues.map((i) => i.toString()).join(', '));
      expect(v.manifest?.id, 'jingyu.demo.pkg');
      expect(v.sha256Hex, built.sha256Hex);
      expect(built.sha256Hex, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('同输入确定性：字节与 sha256 稳定', () {
      final a = buildPluginPackage(manifest: _manifest, files: {'a.txt': [1, 2, 3]});
      final b = buildPluginPackage(manifest: _manifest, files: {'a.txt': [1, 2, 3]});
      expect(a.bytes, equals(b.bytes));
      expect(a.sha256Hex, b.sha256Hex);
    });

    test('不同固定时间戳产生不同 sha（时间戳确实参与编码）', () {
      final a = buildPluginPackage(
          manifest: _manifest, modifiedSecondsSinceEpoch: 315532800); // 1980-01-01Z
      final b = buildPluginPackage(
          manifest: _manifest, modifiedSecondsSinceEpoch: 946684800); // 2000-01-01Z
      expect(a.sha256Hex, isNot(b.sha256Hex));
    });

    test('sha256 与独立 crypto 计算一致', () {
      final built = buildPluginPackage(manifest: _manifest);
      expect(built.sha256Hex, crypto.sha256.convert(built.bytes).toString());
    });

    test('不安全路径被拒（zip-slip / 绝对路径 / 盘符）', () {
      expect(
          () => buildPluginPackage(
              manifest: _manifest, files: {'../evil.txt': [1]}),
          throwsA(isA<PluginPackageBuildException>()));
      expect(
          () => buildPluginPackage(manifest: _manifest, files: {'/etc/x': [1]}),
          throwsA(isA<PluginPackageBuildException>()));
      expect(
          () => buildPluginPackage(manifest: _manifest, files: {'C:/x.dll': [1]}),
          throwsA(isA<PluginPackageBuildException>()));
    });

    test('重复条目（大小写不敏感）被拒', () {
      expect(
          () => buildPluginPackage(manifest: _manifest, files: {
                'a.txt': [1],
                'A.txt': [2],
              }),
          throwsA(isA<PluginPackageBuildException>()));
    });

    test('显式提供 plugin.json 被拒', () {
      expect(
          () => buildPluginPackage(
              manifest: _manifest, files: {'plugin.json': [1]}),
          throwsA(isA<PluginPackageBuildException>()));
    });

    test('清单不可序列化为 JSON 被拒', () {
      expect(
          () => buildPluginPackage(manifest: {'bad': Object()}),
          throwsA(isA<PluginPackageBuildException>()));
    });
  });
}
