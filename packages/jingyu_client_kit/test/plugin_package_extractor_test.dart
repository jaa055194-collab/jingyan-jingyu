import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

/// 一份合法的单插件 `plugin.json`。
const Map<String, Object> _manifest = {
  'id': 'jingyu.demo.pkg',
  'name': '示例插件',
  'version': '0.1.0',
  'apiVersion': 1,
  'capabilities': ['slashCommands'],
  'platforms': ['android', 'windows'],
};

const String _manifestJson =
    '{"id":"jingyu.demo.pkg","name":"示例插件","version":"0.1.0","apiVersion":1}';

Uint8List _zip(List<ArchiveFile> files) {
  final archive = Archive();
  for (final file in files) {
    archive.addFile(file);
  }
  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded!);
}

ArchiveFile _bytesFile(String name, List<int> bytes) =>
    ArchiveFile(name, 0, Uint8List.fromList(bytes));

ArchiveFile _textFile(String name, String text) =>
    _bytesFile(name, utf8.encode(text));

ArchiveFile _dir(String name) =>
    ArchiveFile(name, 0, Uint8List(0))..isFile = false;

/// 把 zip 中指定条目的「声明未压缩尺寸」在中央目录与本地文件头里都改成
/// [declared]，模拟伪造头：DEFLATE 流实际能展开出远大于声明值的字节。
Uint8List _forgeUncompressedSize(Uint8List zip, String target, int declared) {
  final b = Uint8List.fromList(zip);
  final bd = ByteData.sublistView(b);
  var eocd = -1;
  for (var i = b.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw StateError('EOCD 未找到');
  final count = bd.getUint16(eocd + 10, Endian.little);
  var off = bd.getUint32(eocd + 16, Endian.little);
  for (var n = 0; n < count; n++) {
    if (bd.getUint32(off, Endian.little) != 0x02014b50) {
      throw StateError('中央目录头损坏');
    }
    final nameLen = bd.getUint16(off + 28, Endian.little);
    final extraLen = bd.getUint16(off + 30, Endian.little);
    final commentLen = bd.getUint16(off + 32, Endian.little);
    final localOff = bd.getUint32(off + 42, Endian.little);
    final name = utf8.decode(b.sublist(off + 46, off + 46 + nameLen));
    if (name == target) {
      bd.setUint32(off + 24, declared, Endian.little);
      if (bd.getUint32(localOff, Endian.little) == 0x04034b50) {
        bd.setUint32(localOff + 22, declared, Endian.little);
      }
    }
    off += 46 + nameLen + extraLen + commentLen;
  }
  return b;
}

/// 结果中是否包含指定 issue 码。
bool _has(PluginPackageExtraction r, PluginPackageIssueCode code) =>
    r.issues.any((i) => i.code == code);

String _repeat(String unit, int times) =>
    List<String>.filled(times, unit).join();

void main() {
  group('extractPluginPackage：正常路径', () {
    test('合法插件包：返回清单、全部文件内容与 sha256', () {
      final built = buildPluginPackage(
        manifest: _manifest,
        files: {
          'web/index.html': utf8.encode('<html></html>'),
          'assets/icon.svg': utf8.encode('<svg/>'),
        },
      );
      final r = extractPluginPackage(built.bytes);
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      expect(r.issues, isEmpty);
      expect(r.manifest?.id, 'jingyu.demo.pkg');
      expect(r.sha256Hex, built.sha256Hex);
      expect(
        r.files.keys,
        unorderedEquals(['plugin.json', 'web/index.html', 'assets/icon.svg']),
      );
      expect(utf8.decode(r.files['web/index.html']!), '<html></html>');
      expect(r.files['assets/icon.svg'], hasLength(6));
      final manifestJson = jsonDecode(utf8.decode(r.files['plugin.json']!));
      expect(manifestJson, isA<Map<String, dynamic>>());
      expect((manifestJson as Map)['id'], 'jingyu.demo.pkg');
    });

    test('plugin.json 以真实字节进 files（与清单序列化一致）', () {
      final built = buildPluginPackage(manifest: _manifest);
      final r = extractPluginPackage(built.bytes);
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      expect(r.files.containsKey('plugin.json'), isTrue);
      expect(jsonDecode(utf8.decode(r.files['plugin.json']!)), _manifest);
    });

    test('目录条目被跳过，不进入 files', () {
      final bytes = _zip([
        _textFile('plugin.json', _manifestJson),
        _dir('assets/'),
        _bytesFile('assets/a.txt', [1, 2, 3]),
      ]);
      final r = extractPluginPackage(bytes);
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      expect(r.files.keys, unorderedEquals(['plugin.json', 'assets/a.txt']));
      expect(r.files.containsKey('assets'), isFalse);
    });

    test('结果不可修改：files 是 unmodifiable Map，值是独立拷贝', () {
      final built = buildPluginPackage(
        manifest: _manifest,
        files: {
          'a.txt': [1, 2, 3],
        },
      );
      final r = extractPluginPackage(built.bytes);
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      expect(() => r.files['x'] = Uint8List(0), throwsUnsupportedError);
      expect(
        () => r.issues.add(
          const PluginPackageIssue(PluginPackageIssueCode.empty, 'x'),
        ),
        throwsUnsupportedError,
      );

      final before = List<int>.from(r.files['a.txt']!);
      // 破坏输入 zip 的底层缓冲；若 files 泄漏了原缓冲，内容会随之改变。
      built.bytes.fillRange(0, built.bytes.length, 0);
      expect(r.files['a.txt'], equals(before));
    });

    test('期望 sha256 匹配时成功（大小写不敏感）', () {
      final built = buildPluginPackage(manifest: _manifest);
      final r = extractPluginPackage(
        built.bytes,
        expectedSha256Hex: built.sha256Hex.toUpperCase(),
      );
      expect(r.ok, isTrue, reason: r.issues.join(', '));
    });
  });

  group('extractPluginPackage：校验失败透传', () {
    test('空字节：empty，files 为空', () {
      final r = extractPluginPackage(Uint8List(0));
      expect(r.ok, isFalse);
      expect(r.files, isEmpty);
      expect(_has(r, PluginPackageIssueCode.empty), isTrue);
      expect(r.sha256Hex, hasLength(64));
    });

    test('非 zip：notZip，files 为空', () {
      final r = extractPluginPackage(
        Uint8List.fromList(List<int>.generate(64, (i) => (i * 37) % 256)),
      );
      expect(r.ok, isFalse);
      expect(r.files, isEmpty);
      expect(_has(r, PluginPackageIssueCode.notZip), isTrue);
    });

    test('zip-slip（../）被拒且不产生 files', () {
      final bytes = _zip([
        _textFile('plugin.json', _manifestJson),
        _bytesFile('../evil.txt', [1]),
      ]);
      final r = extractPluginPackage(bytes);
      expect(r.ok, isFalse);
      expect(r.files, isEmpty);
      expect(_has(r, PluginPackageIssueCode.unsafeEntryPath), isTrue);
    });

    test('重复条目（大小写不敏感）被拒', () {
      final bytes = _zip([
        _textFile('plugin.json', _manifestJson),
        _bytesFile('a.txt', [1]),
        _bytesFile('A.txt', [2]),
      ]);
      final r = extractPluginPackage(bytes);
      expect(r.ok, isFalse);
      expect(r.files, isEmpty);
      expect(_has(r, PluginPackageIssueCode.duplicateEntry), isTrue);
    });

    test('sha 不符：integrityMismatch，files 为空', () {
      final built = buildPluginPackage(manifest: _manifest);
      final r = extractPluginPackage(
        built.bytes,
        expectedSha256Hex: _repeat('0', 64),
      );
      expect(r.ok, isFalse);
      expect(r.files, isEmpty);
      expect(_has(r, PluginPackageIssueCode.integrityMismatch), isTrue);
    });

    test('缺少 plugin.json：missingManifest', () {
      final bytes = _zip([
        _bytesFile('a.txt', [1]),
      ]);
      final r = extractPluginPackage(bytes);
      expect(r.ok, isFalse);
      expect(r.files, isEmpty);
      expect(_has(r, PluginPackageIssueCode.missingManifest), isTrue);
    });
  });

  group('extractPluginPackage：体积上限（超大条目 / 总量）', () {
    test('声明超大的单条目被拒（entryTooLarge）', () {
      final built = buildPluginPackage(
        manifest: _manifest,
        files: {'big.bin': List<int>.filled(2000, 7)},
      );
      final r = extractPluginPackage(
        built.bytes,
        limits: const PluginPackageLimits(maxEntryUncompressedBytes: 1000),
      );
      expect(r.ok, isFalse);
      expect(r.files, isEmpty);
      expect(_has(r, PluginPackageIssueCode.entryTooLarge), isTrue);
    });

    test('解压总量超限被拒（totalTooLarge）', () {
      final built = buildPluginPackage(
        manifest: _manifest,
        files: {
          'a.bin': List<int>.filled(600, 1),
          'b.bin': List<int>.filled(600, 2),
        },
      );
      final r = extractPluginPackage(
        built.bytes,
        limits: const PluginPackageLimits(maxTotalUncompressedBytes: 1000),
      );
      expect(r.ok, isFalse);
      expect(r.files, isEmpty);
      expect(_has(r, PluginPackageIssueCode.totalTooLarge), isTrue);
    });

    test('伪造头（普通条目）：声明 10 字节但真实解压超单条上限 → entryTooLarge', () {
      // 真实展开 200000 字节，远超单条上限 1000；头里撒谎说只有 10 字节。
      // 有界流式 inflate 必须在解压过程中中止，而不是先完整解压再检查。
      final built = buildPluginPackage(
        manifest: _manifest,
        files: {'bomb.bin': List<int>.filled(200000, 0)},
      );
      final forged = _forgeUncompressedSize(built.bytes, 'bomb.bin', 10);
      // 先用默认上限确认伪造头能通过 validatePluginPackage（否则测不到 extract 的路径）。
      expect(
        validatePluginPackage(forged).ok,
        isTrue,
        reason: validatePluginPackage(forged).issues.join(', '),
      );

      final r = extractPluginPackage(
        forged,
        limits: const PluginPackageLimits(maxEntryUncompressedBytes: 1000),
      );
      expect(r.ok, isFalse);
      expect(r.files, isEmpty);
      expect(_has(r, PluginPackageIssueCode.entryTooLarge), isTrue);
    });

    test('伪造头（多个条目）：真实总量超限 → totalTooLarge', () {
      final built = buildPluginPackage(
        manifest: _manifest,
        files: {
          'a.bin': List<int>.filled(600, 1),
          'b.bin': List<int>.filled(600, 2),
        },
      );
      final forged = _forgeUncompressedSize(
        _forgeUncompressedSize(built.bytes, 'a.bin', 10),
        'b.bin',
        10,
      );
      expect(
        validatePluginPackage(forged).ok,
        isTrue,
        reason: validatePluginPackage(forged).issues.join(', '),
      );

      final r = extractPluginPackage(
        forged,
        limits: const PluginPackageLimits(maxTotalUncompressedBytes: 1000),
      );
      expect(r.ok, isFalse);
      expect(r.files, isEmpty);
      expect(_has(r, PluginPackageIssueCode.totalTooLarge), isTrue);
    });

    test('伪造头但真实字节在上限内 → 成功', () {
      final built = buildPluginPackage(
        manifest: _manifest,
        files: {'small.bin': List<int>.filled(100, 0)},
      );
      final forged = _forgeUncompressedSize(built.bytes, 'small.bin', 10);
      final r = extractPluginPackage(
        forged,
        limits: const PluginPackageLimits(maxEntryUncompressedBytes: 1000),
      );
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      expect(r.files['small.bin'], hasLength(100));
    });
  });
}
