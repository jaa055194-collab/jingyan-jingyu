import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

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

List<int> _pngHeader(int width, int height) {
  final b = BytesBuilder();
  b.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  final data = ByteData(13 + 4);
  data.setUint32(0, 13, Endian.big); // IHDR length
  b.add(data.buffer.asUint8List(0, 4));
  b.add(ascii.encode('IHDR'));
  data.setUint32(0, width, Endian.big);
  data.setUint32(4, height, Endian.big);
  b.add(data.buffer.asUint8List(0, 8));
  b.add(const [8, 6, 0, 0, 0]); // bit depth, color type, ...
  return b.toBytes();
}

List<int> _moc3([int version = 5]) {
  final b = BytesBuilder();
  b.add(ascii.encode('MOC3'));
  final v = ByteData(4)..setUint32(0, version, Endian.little);
  b.add(v.buffer.asUint8List());
  b.add(List<int>.filled(32, 0));
  return b.toBytes();
}

String _model3({
  String moc = 'avatar.moc3',
  List<String> textures = const ['tex0.png'],
  Map<String, Object?>? extra,
}) =>
    jsonEncode({
      'Version': 3,
      'FileReferences': {
        'Moc': moc,
        'Textures': textures,
        ...?extra,
      },
    });

List<ArchiveFile> _validEntries({
  String model3 = 'model/avatar.model3.json',
  String model3Text = '',
  int width = 2048,
  int height = 2048,
}) =>
    [
      _textFile(
        model3,
        model3Text.isEmpty ? _model3() : model3Text,
      ),
      _bytesFile('model/avatar.moc3', _moc3()),
      _bytesFile('model/tex0.png', _pngHeader(width, height)),
    ];

bool _has(Live2DPackageValidation r, Live2DPackageIssueCode code) =>
    r.issues.any((i) => i.code == code);

void main() {
  group('validateLive2DPackage: valid', () {
    test('accepts a model3 package and reports its resources', () {
      final r = validateLive2DPackage(_zip(_validEntries()));
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      expect(r.model3Path, 'model/avatar.model3.json');
      expect(r.mocPath, 'model/avatar.moc3');
      expect(r.textures, ['model/tex0.png']);
      expect(r.totalPixels, 2048 * 2048);
      expect(r.sha256Hex, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('accepts nested unicode paths and optional referenced files', () {
      final text = _model3(
        moc: '大肥鱼.moc3',
        textures: ['tex0.png'],
        extra: {
          'Physics': 'physics3.json',
          'Expressions': [
            {'Name': 'happy', 'File': 'exp/happy.exp3.json'},
          ],
          'Motions': {
            'Idle': [
              {'File': 'motion/idle.motion3.json'},
            ],
          },
        },
      );
      final r = validateLive2DPackage(_zip([
        _textFile('模型/大肥鱼.model3.json', text),
        _bytesFile('模型/大肥鱼.moc3', _moc3()),
        _bytesFile('模型/tex0.png', _pngHeader(1024, 1024)),
        _textFile('模型/physics3.json', '{}'),
        _textFile('模型/exp/happy.exp3.json', '{}'),
        _textFile('模型/motion/idle.motion3.json', '{}'),
      ]));
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      expect(r.model3Path, '模型/大肥鱼.model3.json');
    });
  });

  group('validateLive2DPackage: archive safety', () {
    test('rejects empty and non-zip', () {
      expect(_has(validateLive2DPackage(Uint8List(0)),
          Live2DPackageIssueCode.empty), isTrue);
      expect(
          _has(validateLive2DPackage(Uint8List.fromList([1, 2, 3, 4])),
              Live2DPackageIssueCode.notZip),
          isTrue);
    });

    test('rejects traversal and absolute entry paths', () {
      for (final evil in ['../evil.png', '/etc/passwd', 'C:/x.png']) {
        final r = validateLive2DPackage(_zip([
          ..._validEntries(),
          _bytesFile(evil, [1, 2, 3]),
        ]));
        expect(_has(r, Live2DPackageIssueCode.unsafeEntryPath), isTrue,
            reason: evil);
      }
    });

    test('rejects executable or script extensions', () {
      for (final name in [
        'model/a.js',
        'model/a.html',
        'model/a.svg',
        'model/a.wasm',
        'model/a.exe',
        'model/a.dll',
        'model/a.so',
        'model/a.bat',
        'model/a.sh',
      ]) {
        final r = validateLive2DPackage(_zip([
          ..._validEntries(),
          _bytesFile(name, [1]),
        ]));
        expect(_has(r, Live2DPackageIssueCode.disallowedFileType), isTrue,
            reason: name);
      }
    });

    test('rejects too many entries and oversized package', () {
      final many = validateLive2DPackage(
        _zip(_validEntries()),
        limits: const Live2DPackageLimits(maxEntries: 2),
      );
      expect(_has(many, Live2DPackageIssueCode.tooManyEntries), isTrue);

      final big = validateLive2DPackage(
        _zip(_validEntries(width: 2048, height: 2048)),
        limits: const Live2DPackageLimits(maxTotalUncompressedBytes: 100),
      );
      expect(_has(big, Live2DPackageIssueCode.totalTooLarge), isTrue);
    });
  });

  group('validateLive2DPackage: model3 structure', () {
    test('requires exactly one model3 manifest', () {
      final none = validateLive2DPackage(_zip([
        _bytesFile('model/avatar.moc3', _moc3()),
        _bytesFile('model/tex0.png', _pngHeader(64, 64)),
      ]));
      expect(_has(none, Live2DPackageIssueCode.missingModel3), isTrue);

      final two = validateLive2DPackage(_zip([
        ..._validEntries(),
        _textFile('other/second.model3.json', _model3()),
        _bytesFile('other/avatar.moc3', _moc3()),
        _bytesFile('other/tex0.png', _pngHeader(64, 64)),
      ]));
      expect(_has(two, Live2DPackageIssueCode.multipleModel3), isTrue);
    });

    test('rejects invalid JSON and excessive nesting', () {
      final bad = validateLive2DPackage(_zip(
        _validEntries(model3Text: '{not json'),
      ));
      expect(_has(bad, Live2DPackageIssueCode.model3InvalidJson), isTrue);

      var deep = '1';
      for (var i = 0; i < 80; i++) {
        deep = '[$deep]';
      }
      final nested = validateLive2DPackage(_zip(
        _validEntries(model3Text: '{"Version":3,"x":$deep}'),
      ));
      expect(_has(nested, Live2DPackageIssueCode.model3TooDeep), isTrue);
    });

    test('requires Moc and Textures references', () {
      final noMoc = validateLive2DPackage(_zip(_validEntries(
        model3Text: jsonEncode({
          'Version': 3,
          'FileReferences': {'Textures': ['tex0.png']},
        }),
      )));
      expect(_has(noMoc, Live2DPackageIssueCode.missingMocReference), isTrue);

      final noTex = validateLive2DPackage(_zip(_validEntries(
        model3Text: jsonEncode({
          'Version': 3,
          'FileReferences': {'Moc': 'avatar.moc3', 'Textures': []},
        }),
      )));
      expect(_has(noTex, Live2DPackageIssueCode.missingTextures), isTrue);
    });

    test('rejects missing referenced entries', () {
      final missingMoc = validateLive2DPackage(_zip([
        _textFile('model/avatar.model3.json', _model3()),
        _bytesFile('model/tex0.png', _pngHeader(64, 64)),
      ]));
      expect(_has(missingMoc, Live2DPackageIssueCode.missingReferencedFile),
          isTrue);

      final missingTexture = validateLive2DPackage(_zip([
        _textFile('model/avatar.model3.json', _model3()),
        _bytesFile('model/avatar.moc3', _moc3()),
      ]));
      expect(
          _has(missingTexture, Live2DPackageIssueCode.missingReferencedFile),
          isTrue);
    });

    test('rejects bad MOC3 magic and PNG magic', () {
      final badMoc = validateLive2DPackage(_zip([
        _textFile('model/avatar.model3.json', _model3()),
        _bytesFile('model/avatar.moc3', ascii.encode('NOPE')),
        _bytesFile('model/tex0.png', _pngHeader(64, 64)),
      ]));
      expect(_has(badMoc, Live2DPackageIssueCode.badMocMagic), isTrue);

      final badPng = validateLive2DPackage(_zip([
        _textFile('model/avatar.model3.json', _model3()),
        _bytesFile('model/avatar.moc3', _moc3()),
        _bytesFile('model/tex0.png', [1, 2, 3, 4]),
      ]));
      expect(_has(badPng, Live2DPackageIssueCode.badTextureMagic), isTrue);
    });

    test('enforces texture pixel budget', () {
      final r = validateLive2DPackage(
        _zip(_validEntries(width: 4096, height: 4096)),
        limits: const Live2DPackageLimits(maxTotalPixels: 1000),
      );
      expect(_has(r, Live2DPackageIssueCode.textureBudgetExceeded), isTrue);
    });

    test('rejects duplicate entries case-insensitively', () {
      final r = validateLive2DPackage(_zip([
        ..._validEntries(),
        _textFile('model/AVATAR.model3.json', _model3()),
      ]));
      expect(_has(r, Live2DPackageIssueCode.duplicateEntry), isTrue);
    });
  });
}
