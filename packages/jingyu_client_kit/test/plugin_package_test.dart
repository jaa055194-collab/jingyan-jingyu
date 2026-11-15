import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

/// 一份合法的 `plugin.json`（能力/平台/版本均满足插件清单契约）。
const _validManifest =
    '{"id":"jingyu.demo.pkg","name":"示例插件","version":"0.1.0","apiVersion":1,'
    '"capabilities":["slashCommands"],"platforms":["android","windows"]}';

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

/// 校验结果的 issue 是否包含指定代码。
bool _has(PluginPackageValidation r, PluginPackageIssueCode code) =>
    r.issues.any((i) => i.code == code);

String _repeat(String unit, int times) => List<String>.filled(times, unit).join();

/// `archive` 的 ZipEncoder 写的是非 UNIX 的 `versionMadeBy`，而解码器只有在
/// `versionMadeBy` 高字节 == 3（UNIX）时才按 unix mode 识别符号链接。
/// 测试里把目标条目中央目录头的 versionMadeBy 高字节改成 3，模拟真实 UNIX 符号链接 zip。
Uint8List _asUnixMade(Uint8List zip, String target) {
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
    final name = utf8.decode(b.sublist(off + 46, off + 46 + nameLen));
    if (name == target) {
      b[off + 5] = 3; // versionMadeBy 高字节 = 3 (UNIX)
    }
    off += 46 + nameLen + extraLen + commentLen;
  }
  return b;
}

/// 把 zip 中指定条目的“声明未压缩尺寸”在中央目录与本地文件头里都改成 [declared]，
/// 模拟伪造头：DEFLATE 流实际能展开出远大于声明值的字节，但头里撒谎说很小。
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
      bd.setUint32(off + 24, declared, Endian.little); // 中央目录声明未压缩尺寸
      if (bd.getUint32(localOff, Endian.little) == 0x04034b50) {
        bd.setUint32(localOff + 22, declared, Endian.little); // 本地头同名伪造
      }
    }
    off += 46 + nameLen + extraLen + commentLen;
  }
  return b;
}

void main() {
  group('validatePluginPackage：正常路径', () {
    test('合法插件包通过，解析出清单并给出 sha256', () {
      final bytes = _zip([
        _textFile('plugin.json', _validManifest),
        _bytesFile('web/index.html', utf8.encode('<html></html>')),
        _dir('assets/'),
        _bytesFile('assets/icon.svg', utf8.encode('<svg/>')),
      ]);
      final r = validatePluginPackage(bytes);
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      expect(r.issues, isEmpty);
      expect(r.manifest?.id, 'jingyu.demo.pkg');
      expect(r.manifest?.capabilities, {PluginCapability.slashCommands});
      expect(r.sha256Hex, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('sha256 稳定：同一输入两次一致', () {
      final bytes = _zip([_textFile('plugin.json', _validManifest)]);
      expect(validatePluginPackage(bytes).sha256Hex,
          validatePluginPackage(bytes).sha256Hex);
    });

    test('期望 sha256 匹配（大小写不敏感）则通过', () {
      final bytes = _zip([_textFile('plugin.json', _validManifest)]);
      final digest = validatePluginPackage(bytes).sha256Hex.toUpperCase();
      final r = validatePluginPackage(bytes, expectedSha256Hex: digest);
      expect(r.ok, isTrue);
      expect(r.issues, isEmpty);
    });

    test('期望 sha256 不匹配则拒绝（完整性校验）', () {
      final bytes = _zip([_textFile('plugin.json', _validManifest)]);
      final r = validatePluginPackage(bytes,
          expectedSha256Hex: _repeat('0', 64));
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.integrityMismatch), isTrue);
    });
  });

  group('validatePluginPackage：结构与清单错误', () {
    test('空字节', () {
      final r = validatePluginPackage(Uint8List(0));
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.empty), isTrue);
    });

    test('不是 zip', () {
      final r = validatePluginPackage(
          Uint8List.fromList(List<int>.generate(64, (i) => (i * 37) % 256)));
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.notZip), isTrue);
    });

    test('空 zip（没有任何条目）', () {
      final r = validatePluginPackage(_zip([]));
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.empty), isTrue);
      expect(r.manifest, isNull);
    });

    test('缺少根 plugin.json', () {
      final r = validatePluginPackage(_zip([
        _bytesFile('assets/a.png', [1, 2, 3]),
      ]));
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.missingManifest), isTrue);
      expect(r.manifest, isNull);
    });

    test('plugin.json 非法 JSON', () {
      final r = validatePluginPackage(_zip([
        _textFile('plugin.json', '{ this is not json'),
      ]));
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.manifestInvalidJson), isTrue);
      expect(r.manifest, isNull);
    });

    test('plugin.json 非 UTF-8', () {
      final r = validatePluginPackage(_zip([
        _bytesFile('plugin.json', [0xFF, 0xFE, 0x00, 0x80, 0x81]),
      ]));
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.manifestInvalidJson), isTrue);
      expect(r.manifest, isNull);
    });

    test('plugin.json 顶层不是对象', () {
      final r = validatePluginPackage(_zip([
        _textFile('plugin.json', '[1,2,3]'),
      ]));
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.manifestInvalid), isTrue);
    });

    test('清单不满足契约（非法 id）', () {
      final r = validatePluginPackage(_zip([
        _textFile('plugin.json',
            '{"id":"NoDot","name":"x","version":"1.0.0","apiVersion":1}'),
      ]));
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.manifestInvalid), isTrue);
    });

    test('plugin.json 嵌套过深', () {
      final deep = '{"a":${_repeat('[', 40)}${_repeat(']', 40)}}';
      final r = validatePluginPackage(
        _zip([_textFile('plugin.json', deep)]),
        limits: const PluginPackageLimits(maxJsonDepth: 8),
      );
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.manifestTooDeep), isTrue);
    });

    test('plugin.json 体积超限', () {
      final padded = '$_validManifest${_repeat(' ', 200)}';
      final r = validatePluginPackage(
        _zip([_textFile('plugin.json', padded)]),
        limits: const PluginPackageLimits(maxManifestBytes: 50),
      );
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.manifestTooLarge), isTrue);
    });
  });

  group('validatePluginPackage：安全性（zip-slip / zip-bomb / 重复）', () {
    test('路径穿越 ../ 被拒', () {
      final r = validatePluginPackage(_zip([
        _textFile('plugin.json', _validManifest),
        _bytesFile('../evil.txt', [1]),
      ]));
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.unsafeEntryPath), isTrue);
    });

    test('绝对路径与盘符被拒', () {
      final abs = validatePluginPackage(_zip([
        _textFile('plugin.json', _validManifest),
        _bytesFile('/etc/passwd', [1]),
      ]));
      expect(_has(abs, PluginPackageIssueCode.unsafeEntryPath), isTrue);

      final drive = validatePluginPackage(_zip([
        _textFile('plugin.json', _validManifest),
        _bytesFile('C:/Windows/x.dll', [1]),
      ]));
      expect(_has(drive, PluginPackageIssueCode.unsafeEntryPath), isTrue);
    });

    test('重复条目（大小写不敏感）被拒', () {
      final r = validatePluginPackage(_zip([
        _textFile('plugin.json', _validManifest),
        _bytesFile('a.txt', [1]),
        _bytesFile('A.txt', [2]),
      ]));
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.duplicateEntry), isTrue);
    });

    test('符号链接条目被拒', () {
      // archive 的解码器靠 unix mode 的 0xA000 位 + UNIX versionMadeBy 识别符号链接。
      final link = ArchiveFile(
          'evil-link', 0, Uint8List.fromList(utf8.encode('/etc/passwd')))
        ..mode = 0xA1FF;
      final bytes = _asUnixMade(
        _zip([_textFile('plugin.json', _validManifest), link]),
        'evil-link',
      );
      final r = validatePluginPackage(bytes);
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.symbolicLink), isTrue);
    });

    test('条目数超限', () {
      final r = validatePluginPackage(
        _zip([
          _textFile('plugin.json', _validManifest),
          _bytesFile('a', [1]),
          _bytesFile('b', [1]),
          _bytesFile('c', [1]),
        ]),
        limits: const PluginPackageLimits(maxEntries: 2),
      );
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.tooManyEntries), isTrue);
    });

    test('单条目解压后超限', () {
      final r = validatePluginPackage(
        _zip([
          _textFile('plugin.json', _validManifest),
          _bytesFile('big.bin', List<int>.filled(2000, 7)),
        ]),
        limits: const PluginPackageLimits(maxEntryUncompressedBytes: 1000),
      );
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.entryTooLarge), isTrue);
    });

    test('解压总量超限', () {
      final r = validatePluginPackage(
        _zip([
          _textFile('plugin.json', _validManifest),
          _bytesFile('a.bin', List<int>.filled(600, 1)),
          _bytesFile('b.bin', List<int>.filled(600, 2)),
        ]),
        limits: const PluginPackageLimits(maxTotalUncompressedBytes: 1000),
      );
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.totalTooLarge), isTrue);
    });

    test('高压缩比（zip 炸弹）被拒', () {
      final r = validatePluginPackage(
        _zip([
          _textFile('plugin.json', _validManifest),
          _bytesFile('bomb.bin', List<int>.filled(200000, 0)),
        ]),
        limits: const PluginPackageLimits(
          maxTotalUncompressedBytes: 1 << 30,
          maxCompressionRatio: 5,
        ),
      );
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.compressionRatioTooHigh), isTrue);
    });
  });

  group('sanitizePackageEntryPath', () {
    test('规范化安全路径', () {
      expect(sanitizePackageEntryPath('a/b.png'), 'a/b.png');
      expect(sanitizePackageEntryPath('./a.txt'), 'a.txt');
      expect(sanitizePackageEntryPath('dir//x'), 'dir/x');
      expect(sanitizePackageEntryPath('a\\b\\c'), 'a/b/c');
    });

    test('拒绝不安全路径', () {
      expect(sanitizePackageEntryPath(''), isNull);
      expect(sanitizePackageEntryPath('/abs'), isNull);
      expect(sanitizePackageEntryPath('C:/x'), isNull);
      expect(sanitizePackageEntryPath('../x'), isNull);
      expect(sanitizePackageEntryPath('a/../../x'), isNull);
      expect(sanitizePackageEntryPath('a/../b'), isNull);
      expect(sanitizePackageEntryPath('a\u0000b'), isNull);
      expect(sanitizePackageEntryPath('a:b'), isNull);
    });
  });

  group('安全加固（复审修复）', () {
    test('Windows 尾点 / 保留设备名被拒', () {
      for (final name in ['a.', 'dir/b.', 'CON', 'aux.txt', 'sub/NUL', 'com1']) {
        expect(sanitizePackageEntryPath(name), isNull, reason: name);
      }
      expect(sanitizePackageEntryPath('console.txt'), 'console.txt');
      expect(sanitizePackageEntryPath('assets/icon.svg'), 'assets/icon.svg');
    });

    test('plugin.json 的 license 为非字符串时返回 manifestInvalid 而非抛异常', () {
      final r = validatePluginPackage(_zip([
        _textFile(
            'plugin.json',
            '{"id":"a.b","name":"x","version":"1.0.0","apiVersion":1,"license":123}'),
      ]));
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.manifestInvalid), isTrue);
    });

    test('符号链接在解码前被预扫拒绝（不进入解压）', () {
      final link = ArchiveFile(
          'evil-link', 0, Uint8List.fromList(utf8.encode('/etc/passwd')))
        ..mode = 0xA1FF;
      final bytes = _asUnixMade(
          _zip([_textFile('plugin.json', _validManifest), link]), 'evil-link');
      final r = validatePluginPackage(bytes);
      expect(r.ok, isFalse);
      final sym = r.issues
          .where((i) => i.code == PluginPackageIssueCode.symbolicLink)
          .toList();
      expect(sym, isNotEmpty);
      // 必须是“解码前预扫”发现（而非解码后才发现）。
      expect(sym.any((i) => i.message.contains('预扫')), isTrue);
    });

    test('伪造 EOCD 条目数不能绕过解码前符号链接预扫', () {
      final link = ArchiveFile(
          'evil-link', 0, Uint8List.fromList(utf8.encode('/etc/passwd')))
        ..mode = 0xA1FF;
      final bytes = _asUnixMade(
          _zip([_textFile('plugin.json', _validManifest), link]), 'evil-link');
      final patched = Uint8List.fromList(bytes);
      final bd = ByteData.sublistView(patched);
      var eocd = -1;
      for (var i = patched.length - 22; i >= 0; i--) {
        if (bd.getUint32(i, Endian.little) == 0x06054b50) {
          eocd = i;
          break;
        }
      }
      expect(eocd >= 0, isTrue);
      // 谎报条目数为 1（中央目录尺寸不变）——朴素的按计数遍历会漏掉符号链接。
      bd.setUint16(eocd + 10, 1, Endian.little);
      final r = validatePluginPackage(patched);
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.symbolicLink), isTrue);
      expect(
          r.issues
              .where((i) => i.code == PluginPackageIssueCode.symbolicLink)
              .any((i) => i.message.contains('预扫')),
          isTrue);
    });

    test('cdSize 越过文件边界必须 fail-closed（不解码）', () {
      final link = ArchiveFile(
          'evil-link', 0, Uint8List.fromList(utf8.encode('/etc/passwd')))
        ..mode = 0xA1FF;
      final bytes = _asUnixMade(
          _zip([_textFile('plugin.json', _validManifest), link]), 'evil-link');
      final patched = Uint8List.fromList(bytes);
      final bd = ByteData.sublistView(patched);
      var eocd = -1;
      for (var i = patched.length - 22; i >= 0; i--) {
        if (bd.getUint32(i, Endian.little) == 0x06054b50) {
          eocd = i;
          break;
        }
      }
      expect(eocd >= 0, isTrue);
      // 把 cdSize 改成整个文件长度 → cdEnd 越过 EOF；archive 会截断而非报错。
      bd.setUint32(eocd + 12, patched.length, Endian.little);
      final r = validatePluginPackage(patched);
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.notZip), isTrue);
      // 必须未进入解码：不应出现任何 symbolicLink 诊断。
      expect(_has(r, PluginPackageIssueCode.symbolicLink), isFalse);
    });

    test('zip64 触发字段被 fail-closed 拒绝', () {
      final patched =
          Uint8List.fromList(_zip([_textFile('plugin.json', _validManifest)]));
      final bd = ByteData.sublistView(patched);
      var eocd = -1;
      for (var i = patched.length - 22; i >= 0; i--) {
        if (bd.getUint32(i, Endian.little) == 0x06054b50) {
          eocd = i;
          break;
        }
      }
      expect(eocd >= 0, isTrue);
      bd.setUint16(eocd + 8, 0xFFFF, Endian.little); // entries-on-this-disk
      final r = validatePluginPackage(patched);
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.notZip), isTrue);
    });
  });

  group('伪造头 / 有界解压（I1）', () {
    test('伪造头：清单声明很小但真实解压超过单条上限 → entryTooLarge（不信任声明值）', () {
      // 真实展开 200000 字节（> 单条上限 1000），但头里只声明 10 字节。
      final content = '$_validManifest${_repeat(' ', 200000)}';
      final bytes = _forgeUncompressedSize(
          _zip([_textFile('plugin.json', content)]), 'plugin.json', 10);
      final r = validatePluginPackage(bytes,
          limits: const PluginPackageLimits(maxEntryUncompressedBytes: 1000));
      expect(r.ok, isFalse, reason: r.issues.join(', '));
      expect(_has(r, PluginPackageIssueCode.entryTooLarge), isTrue);
      expect(r.manifest, isNull);
    });

    test('伪造头：清单真实解压超过 maxManifestBytes → manifestTooLarge', () {
      final content = '$_validManifest${_repeat(' ', 400000)}';
      final bytes = _forgeUncompressedSize(
          _zip([_textFile('plugin.json', content)]), 'plugin.json', 10);
      final r = validatePluginPackage(bytes);
      expect(r.ok, isFalse, reason: r.issues.join(', '));
      expect(_has(r, PluginPackageIssueCode.manifestTooLarge), isTrue);
      expect(r.manifest, isNull);
    });

    test('伪造头（STORE 未压缩清单）：声明很小但真实很大 → entryTooLarge', () {
      final content = '$_validManifest${_repeat(' ', 200000)}';
      final file =
          ArchiveFile('plugin.json', 0, Uint8List.fromList(utf8.encode(content)))
            ..compress = false;
      final bytes = _forgeUncompressedSize(_zip([file]), 'plugin.json', 10);
      final r = validatePluginPackage(bytes,
          limits: const PluginPackageLimits(maxEntryUncompressedBytes: 1000));
      expect(r.ok, isFalse, reason: r.issues.join(', '));
      expect(_has(r, PluginPackageIssueCode.entryTooLarge), isTrue);
      expect(r.manifest, isNull);
    });

    test('伪造头：真实清单使总量超过 maxTotalUncompressedBytes → totalTooLarge', () {
      final content = '$_validManifest${_repeat(' ', 2000)}';
      final bytes = _forgeUncompressedSize(
          _zip([_textFile('plugin.json', content)]), 'plugin.json', 10);
      final r = validatePluginPackage(bytes,
          limits: const PluginPackageLimits(maxTotalUncompressedBytes: 1000));
      expect(r.ok, isFalse, reason: r.issues.join(', '));
      expect(_has(r, PluginPackageIssueCode.totalTooLarge), isTrue);
    });

    test('伪造头但真实尺寸在上限内 → 仍通过（不误伤合法小清单）', () {
      final bytes = _forgeUncompressedSize(
          _zip([_textFile('plugin.json', _validManifest)]), 'plugin.json', 10);
      final r = validatePluginPackage(bytes,
          limits: const PluginPackageLimits(maxEntryUncompressedBytes: 1000));
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      expect(r.manifest?.id, 'jingyu.demo.pkg');
    });

    test('伪造头谎报过大（声明超限）→ 预扫描即拒绝 entryTooLarge（fail-closed）', () {
      final bytes = _forgeUncompressedSize(
          _zip([_textFile('plugin.json', _validManifest)]), 'plugin.json', 999999);
      final r = validatePluginPackage(bytes,
          limits: const PluginPackageLimits(maxEntryUncompressedBytes: 1000));
      expect(r.ok, isFalse);
      expect(_has(r, PluginPackageIssueCode.entryTooLarge), isTrue);
    });
  });
}
