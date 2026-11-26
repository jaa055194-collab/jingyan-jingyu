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
  // Only the signature and complete IHDR chunk: these tests do not decode PNGs.
  final bytes = Uint8List(33);
  final data = ByteData.sublistView(bytes);
  bytes.setAll(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  data.setUint32(8, 13);
  bytes.setAll(12, ascii.encode('IHDR'));
  data.setUint32(16, width);
  data.setUint32(20, height);
  bytes.setAll(24, const [8, 6, 0, 0, 0]); // bit depth, color type, ...
  data.setUint32(29, getCrc32(bytes.sublist(12, 29)));
  return bytes;
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
  group('prepareLive2DPreview', () {
    test('emits only generated renderer inputs in texture-slot order', () {
      final zip = _zip([
        ..._validEntries(model3Text: _model3(textures: ['tex0.png', 'tex1.png', 'tex0.png'])),
        ArchiveFile.noCompress('model/tex1.png', 33, Uint8List.fromList(_pngHeader(32, 16))),
        _textFile('notes.txt', 'not a renderer resource'),
      ]);
      final bundle = prepareLive2DPreview(zip);
      expect(bundle.model3Name, 'model.model3.json');
      expect(bundle.files.keys, unorderedEquals([
        'model.model3.json', 'model.moc3', 'texture-0.png', 'texture-1.png',
      ]));
      expect(bundle.files['model.moc3'], _moc3());
      expect(jsonDecode(utf8.decode(bundle.files[bundle.model3Name]!)), {
        'Version': 3,
        'FileReferences': {'Moc': 'model.moc3', 'Textures': ['texture-0.png', 'texture-1.png', 'texture-0.png']},
      });
      expect(() => bundle.files.clear(), throwsUnsupportedError);
      expect(() => bundle.files['model.moc3']![0] = 0, throwsUnsupportedError);
    });

    test('caps the aggregate bytes of generated preview resources', () {
      final zip = _zip(_validEntries());
      final result = prepareLive2DPreview(zip);
      final size = result.files.values.fold(0, (sum, file) => sum + file.length);
      expect(prepareLive2DPreview(zip, maxPreviewBytes: size).files.keys,
          unorderedEquals(result.files.keys));
      expect(() => prepareLive2DPreview(zip, maxPreviewBytes: size - 1),
          throwsFormatException);
    });

    test('refuses invalid packages and honors the input cap', () {
      expect(() => prepareLive2DPreview(Uint8List(1)), throwsFormatException);
      expect(() => prepareLive2DPreview(_zip(_validEntries()), maxArchiveBytes: 1), throwsFormatException);
    });
  });
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
          'Physics': 'avatar.physics3.json',
          'Pose': 'avatar.pose3.json',
          'DisplayInfo': 'avatar.cdi3.json',
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
      final r = validateLive2DPackage(
        _zip([
          _textFile('模型/大肥鱼.model3.json', text),
          _bytesFile('模型/大肥鱼.moc3', _moc3()),
          _bytesFile('模型/tex0.png', _pngHeader(1024, 1024)),
          _textFile('模型/avatar.physics3.json', '{}'),
          _textFile('模型/avatar.pose3.json', '{}'),
          _textFile('模型/avatar.cdi3.json', '{}'),
          _textFile('模型/exp/happy.exp3.json', '{}'),
          _textFile('模型/motion/idle.motion3.json', '{}'),
        ]),
      );
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

    test('rejects a valid ZIP entry when manifest bytes exceed its cap', () {
      final r = validateLive2DPackage(
        _zip(_validEntries()),
        limits: const Live2DPackageLimits(maxModel3Bytes: 32),
      );
      expect(r.ok, isFalse);
      expect(r.issues.single.code, Live2DPackageIssueCode.model3TooLarge);
    });

    test('rejects an ordinary PNG with a corrupted ZIP checksum', () {
      final archive = Archive()
        ..addFile(_textFile('model/avatar.model3.json', _model3()))
        ..addFile(_bytesFile('model/avatar.moc3', _moc3()))
        ..addFile(ArchiveFile.noCompress(
          'model/tex0.png', 34, Uint8List.fromList([..._pngHeader(64, 64), 42]),
        ));
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive, level: 0)!);
      final marker = _pngHeader(64, 64);
      final start = Iterable<int>.generate(bytes.length - marker.length)
          .firstWhere((i) => List.generate(marker.length, (j) => bytes[i + j])
              .toString() == marker.toString());
      bytes[start + marker.length] ^= 1; // Ordinary data corruption, outside IHDR.
      final result = validateLive2DPackage(bytes);
      expect(result.ok, isFalse);
      expect(result.issues.single.code, Live2DPackageIssueCode.notZip);
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

    for (final reference in ['./tex0.png', r'textures\tex0.png']) {
      test('requires a canonical texture reference: $reference', () {
        final r = validateLive2DPackage(
          _zip([
            ..._validEntries(model3Text: _model3(textures: [reference])),
            _bytesFile('model/textures/tex0.png', _pngHeader(64, 64)),
          ]),
        );
        expect(r.ok, isFalse);
        expect(r.issues.single.code, Live2DPackageIssueCode.unsafeEntryPath);
        expect(r.issues.single.path, reference);
      });
    }

    final wrongTypes = <String, String Function(String)>{
      'Moc': (path) => _model3(moc: path),
      'Texture': (path) => _model3(textures: [path]),
      'Physics': (path) => _model3(extra: {'Physics': path}),
      'Pose': (path) => _model3(extra: {'Pose': path}),
      'DisplayInfo': (path) => _model3(extra: {'DisplayInfo': path}),
      'Expression': (path) => _model3(
        extra: {
          'Expressions': [
            {'Name': 'Smile', 'File': path},
          ],
        },
      ),
      'Motion': (path) => _model3(
        extra: {
          'Motions': {
            'Idle': [
              {'File': path},
            ],
          },
        },
      ),
    };
    for (final MapEntry(key: role, value: manifest) in wrongTypes.entries) {
      test('requires the expected file suffix for $role', () {
        const reference = 'asset.txt';
        final r = validateLive2DPackage(
          _zip([
            ..._validEntries(model3Text: manifest(reference)),
            _bytesFile('model/$reference', switch (role) {
              'Moc' => _moc3(),
              'Texture' => _pngHeader(64, 64),
              _ => utf8.encode('{}'),
            }),
          ]),
        );
        expect(r.ok, isFalse);
        expect(r.issues.single.code, Live2DPackageIssueCode.model3Invalid);
        expect(r.issues.single.path, reference);
      });
    }

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

    final header = _pngHeader(64, 64);
    final invalidHeaders = <String, List<int>>{
      'truncated IHDR': header.sublist(0, 29),
      'wrong first chunk': [...header]..setAll(12, ascii.encode('tEXt')),
      'wrong IHDR length': [...header]..[11] = 12,
      'incorrect IHDR CRC': [...header]..[32] ^= 1,
    };
    for (final MapEntry(key: reason, value: bytes) in invalidHeaders.entries) {
      test('rejects a PNG with $reason', () {
        final r = validateLive2DPackage(
          _zip([
            _textFile('model/avatar.model3.json', _model3()),
            _bytesFile('model/avatar.moc3', _moc3()),
            _bytesFile('model/tex0.png', bytes),
          ]),
        );
        expect(r.ok, isFalse);
        expect(r.issues.single.code, Live2DPackageIssueCode.badTextureMagic);
      });
    }

    test('reports the first texture outside the cumulative pixel budget', () {
      final zip = _zip([
        ..._validEntries(
          model3Text: _model3(textures: ['tex0.png', 'tex1.png']),
          width: 10,
          height: 10,
        ),
        _bytesFile('model/tex1.png', _pngHeader(5, 5)),
      ]);
      final exact = validateLive2DPackage(
        zip,
        limits: const Live2DPackageLimits(maxTotalPixels: 125),
      );
      expect(exact.ok, isTrue, reason: exact.issues.join(', '));
      expect(exact.totalPixels, 125);

      final over = validateLive2DPackage(
        zip,
        limits: const Live2DPackageLimits(maxTotalPixels: 124),
      );
      expect(over.ok, isFalse);
      expect(
        over.issues.single.code,
        Live2DPackageIssueCode.textureBudgetExceeded,
      );
      expect(over.issues.single.path, 'model/tex1.png');
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

  group('validateLive2DPackage: groups', () {
    String withGroups(Object? groups) => jsonEncode({
          'Version': 3,
          'FileReferences': {
            'Moc': 'avatar.moc3',
            'Textures': ['tex0.png'],
          },
          'Groups': groups,
        });

    Live2DPackageValidation validate(Object? groups) {
      final r = validateLive2DPackage(
        _zip(_validEntries(model3Text: withGroups(groups))),
      );
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      return r;
    }

    List<Map<String, Object>> groupsOf(List<Live2DModelGroup> groups) => [
          for (final group in groups) {'name': group.name, 'ids': group.ids},
        ];

    test('reads names and IDs in file order, whatever the target', () {
      final r = validate([
        {
          'Target': 'Parameter',
          'Name': 'EyeBlink',
          'Ids': ['ParamEyeLOpen', 'ParamEyeROpen'],
        },
        {'Target': 'Part', 'Name': 'LipSync', 'Ids': ['ParamMouthOpenY']},
        {'Name': 'LipSync', 'Ids': <String>[]},
      ]);
      expect(groupsOf(r.groups), [
        {'name': 'EyeBlink', 'ids': ['ParamEyeLOpen', 'ParamEyeROpen']},
        {'name': 'LipSync', 'ids': ['ParamMouthOpenY']},
        {'name': 'LipSync', 'ids': <String>[]},
      ]);
      expect(() => r.groups.clear(), throwsUnsupportedError);
      expect(() => r.groups.first.ids.clear(), throwsUnsupportedError);
    });

    test('skips entries and IDs that no lookup can match', () {
      final long = 'x' * 257;
      final r = validate([
        'EyeBlink',
        {'Ids': ['A']},
        {'Name': '', 'Ids': ['A']},
        {'Name': long, 'Ids': ['A']},
        {'Name': 7, 'Ids': ['A']},
        {'Name': 'LipSync', 'Ids': 'ParamMouthOpenY'},
        {'Name': 'EyeBlink', 'Ids': ['A', 3, '', long, null, 'B', 'x' * 256]},
      ]);
      expect(groupsOf(r.groups), [
        {'name': 'LipSync', 'ids': <String>[]},
        {'name': 'EyeBlink', 'ids': ['A', 'B', 'x' * 256]},
      ]);
    });

    test('gives no groups for a Groups value it cannot read whole', () {
      const max = Live2DModelInfo.maxEntries;
      for (final groups in [
        null,
        'EyeBlink',
        {'Name': 'EyeBlink', 'Ids': ['A']},
        [
          for (var i = 0; i <= max; i++) {'Name': 'G$i', 'Ids': <String>[]},
        ],
        [
          {'Name': 'EyeBlink', 'Ids': List.filled(max, 'A')},
          {'Name': 'LipSync', 'Ids': ['B']},
        ],
      ]) {
        expect(validate(groups).groups, isEmpty);
      }
      final atLimit = validate([
        {'Name': 'EyeBlink', 'Ids': List.filled(max - 1, 'A')},
        {'Name': 'LipSync', 'Ids': ['B']},
      ]);
      expect(atLimit.groups.map((group) => group.ids.length), [max - 1, 1]);
    });

    test('leaves groups empty for an invalid package', () {
      final r = validateLive2DPackage(_zip([
        _textFile(
          'model/avatar.model3.json',
          withGroups([
            {'Name': 'LipSync', 'Ids': ['ParamMouthOpenY']},
          ]),
        ),
        _bytesFile('model/avatar.moc3', _moc3()),
      ]));
      expect(r.ok, isFalse);
      expect(r.groups, isEmpty);
    });

    test('hands the groups to the preview without writing them out', () {
      final bundle = prepareLive2DPreview(_zip(_validEntries(
        model3Text: withGroups([
          {'Target': 'Parameter', 'Name': 'LipSync', 'Ids': ['ParamMouthOpenY']},
        ]),
      )));
      expect(groupsOf(bundle.groups), [
        {'name': 'LipSync', 'ids': ['ParamMouthOpenY']},
      ]);
      final manifest =
          jsonDecode(utf8.decode(bundle.files[bundle.model3Name]!));
      expect(manifest, isNot(contains('Groups')));
    });
  });
}
