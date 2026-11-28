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

    Map<String, Object?> manifestOf(Live2DPreviewBundle bundle) =>
        jsonDecode(utf8.decode(bundle.files[bundle.model3Name]!))
            as Map<String, Object?>;

    Live2DPreviewBundle prepare(Object? groups) {
      final model3Text = withGroups(groups);
      return prepareLive2DPreview(_zip(_validEntries(model3Text: model3Text)));
    }

    test('hands the groups to the preview, which writes out LipSync', () {
      final bundle = prepare([
        {'Target': 'Parameter', 'Name': 'LipSync', 'Ids': ['ParamMouthOpenY']},
      ]);
      expect(groupsOf(bundle.groups), [
        {'name': 'LipSync', 'ids': ['ParamMouthOpenY']},
      ]);
      expect(manifestOf(bundle)['Groups'], [
        {'Target': 'Parameter', 'Name': 'LipSync', 'Ids': ['ParamMouthOpenY']},
      ]);
    });

    test('writes out only the first EyeBlink and the first LipSync', () {
      final bundle = prepare([
        {'Target': 'Parameter', 'Name': 'Custom', 'Ids': ['ParamAngleX']},
        {'Target': 'Part', 'Name': 'LipSync', 'Ids': ['ParamMouthOpenY', 3]},
        {'Name': 'eyeblink', 'Ids': ['ParamCheek']},
        {'Name': 'EyeBlink', 'Ids': ['ParamEyeLOpen', '', 'ParamEyeROpen']},
        {'Name': 'EyeBlink', 'Ids': ['ParamBrowLY']},
        {'Name': 'LipSync', 'Ids': ['ParamMouthForm']},
      ]);
      // Every group still feeds mapping suggestions.
      expect(bundle.groups.map((group) => group.name), [
        'Custom', 'LipSync', 'eyeblink', 'EyeBlink', 'EyeBlink', 'LipSync',
      ]);
      expect(manifestOf(bundle)['Groups'], [
        {
          'Target': 'Parameter',
          'Name': 'EyeBlink',
          'Ids': ['ParamEyeLOpen', 'ParamEyeROpen'],
        },
        {'Target': 'Parameter', 'Name': 'LipSync', 'Ids': ['ParamMouthOpenY']},
      ]);
      // The first group of a name counts even without IDs, as in Cubism.
      final empty = prepare([
        {'Name': 'EyeBlink', 'Ids': <String>[]},
        {'Name': 'EyeBlink', 'Ids': ['ParamEyeLOpen']},
      ]);
      expect(manifestOf(empty)['Groups'], [
        {'Target': 'Parameter', 'Name': 'EyeBlink', 'Ids': <String>[]},
      ]);
    });

    test('writes no Groups without an EyeBlink or LipSync group', () {
      final cases = <Object?>[
        null,
        'EyeBlink',
        <Object?>[],
        [
          {'Target': 'Parameter', 'Name': 'Custom', 'Ids': ['ParamAngleX']},
          {'Name': 'eyeblink', 'Ids': ['ParamEyeLOpen']},
          {'Name': 'LipSync ', 'Ids': ['ParamMouthOpenY']},
          {'Ids': ['ParamMouthOpenY']},
        ],
      ];
      for (final groups in cases) {
        expect(manifestOf(prepare(groups)), isNot(contains('Groups')),
            reason: '$groups');
      }
      final plain = prepareLive2DPreview(_zip(_validEntries()));
      expect(manifestOf(plain), isNot(contains('Groups')));
    });

    test('counts the written groups against the preview byte cap', () {
      final zip = _zip([
        ..._validEntries(
          model3Text: jsonEncode({
            'Version': 3,
            'FileReferences': {
              'Moc': 'avatar.moc3',
              'Textures': ['tex0.png'],
              'Expressions': [
                {'Name': 'Smile', 'File': 'smile.exp3.json'},
              ],
            },
            'Groups': [
              {'Name': 'EyeBlink', 'Ids': ['ParamEyeLOpen', 'ParamEyeROpen']},
            ],
          }),
        ),
        _textFile('model/smile.exp3.json', '{}'),
      ]);
      int sizeOf(Live2DPreviewBundle bundle) =>
          bundle.files.values.fold(0, (sum, file) => sum + file.length);
      // An exact fit keeps the expression; one byte less leaves it out.
      final size = sizeOf(prepareLive2DPreview(zip));
      final fit = prepareLive2DPreview(zip, maxPreviewBytes: size);
      expect(fit.warnings, isEmpty);
      expect(fit.files, contains('expression-0.exp3.json'));
      final capped = prepareLive2DPreview(zip, maxPreviewBytes: size - 1);
      expect(capped.files, isNot(contains('expression-0.exp3.json')));
      expect(capped.warnings.single.message, contains('byte cap'));
      for (final bundle in [fit, capped]) {
        expect(manifestOf(bundle), contains('Groups'));
      }
    });
  });

  group('expressions and motions', () {
    // The valid entries, a model3 that lists [expressions] and [motions], and
    // [files] (text or bytes) under model/.
    Uint8List package({
      Object? expressions,
      Object? motions,
      Map<String, Object> files = const {},
    }) =>
        _zip([
          ..._validEntries(
            model3Text: _model3(extra: {
              'Expressions': ?expressions,
              'Motions': ?motions,
            }),
          ),
          for (final MapEntry(key: path, value: data) in files.entries)
            data is String
                ? _textFile('model/$path', data)
                : _bytesFile('model/$path', data as List<int>),
        ]);

    Object? fileRefsOf(Live2DPreviewBundle bundle) =>
        (jsonDecode(utf8.decode(bundle.files[bundle.model3Name]!))
            as Map<String, Object?>)['FileReferences'];

    String describe(Live2DPackageIssue issue) =>
        '${issue.code.name} ${issue.index} ${issue.path}';

    int sizeOf(Live2DPreviewBundle bundle) =>
        bundle.files.values.fold(0, (sum, file) => sum + file.length);

    test('stages them under generated names that the model3 lists', () {
      final zip = package(
        expressions: [
          {'Name': 'Smile', 'File': 'exp/smile.exp3.json'},
          {'Name': '笑', 'File': 'exp/laugh.exp3.json'},
        ],
        motions: {
          'Idle': [
            {
              'File': 'motion/idle.motion3.json',
              'FadeInTime': 0.5,
              'FadeOutTime': -1,
              'Sound': 'sounds/idle.wav',
            },
            {'File': 'motion/breath.motion3.json', 'FadeOutTime': 1},
          ],
          '': [
            {'File': 'motion/tap.motion3.json', 'Sound': 'sounds/tap.wav'},
          ],
        },
        files: {
          'exp/smile.exp3.json': '{"Type":"Live2D Expression"}',
          'exp/laugh.exp3.json': '{}',
          'motion/idle.motion3.json': '{"Version":3}',
          'motion/breath.motion3.json': '{}',
          'motion/tap.motion3.json': '{"Meta":{}}',
        },
      );
      final bundle = prepareLive2DPreview(zip);
      expect(bundle.warnings, isEmpty);
      expect(bundle.files.keys, unorderedEquals([
        'model.model3.json', 'model.moc3', 'texture-0.png',
        'expression-0.exp3.json', 'expression-1.exp3.json',
        'motion-0.motion3.json', 'motion-1.motion3.json',
        'motion-2.motion3.json',
      ]));
      expect(utf8.decode(bundle.files['expression-0.exp3.json']!),
          '{"Type":"Live2D Expression"}');
      expect(utf8.decode(bundle.files['motion-2.motion3.json']!),
          '{"Meta":{}}');
      expect(fileRefsOf(bundle), {
        'Moc': 'model.moc3',
        'Textures': ['texture-0.png'],
        'Expressions': [
          {'Name': 'Smile', 'File': 'expression-0.exp3.json'},
          {'Name': '笑', 'File': 'expression-1.exp3.json'},
        ],
        'Motions': {
          'Idle': [
            {'File': 'motion-0.motion3.json', 'FadeInTime': 0.5},
            {'File': 'motion-1.motion3.json', 'FadeOutTime': 1},
          ],
          '': [
            {'File': 'motion-2.motion3.json'},
          ],
        },
      });
      final r = validateLive2DPackage(zip);
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      expect(r.warnings, isEmpty);
    });

    test('leaves out only an entry with a problem, with a warning', () {
      final zip = package(
        expressions: [
          {'Name': 'Gone', 'File': 'exp/gone.exp3.json'},
          {'Name': 'Smile', 'File': 'exp/smile.exp3.json'},
          {'Name': 'Smile', 'File': 'exp/wink.exp3.json'},
          {'Name': 'Big', 'File': 'exp/big.exp3.json'},
          {'File': 'exp/wink.exp3.json'},
          {'Name': 'Number', 'File': 7},
          'Frown',
          {'Name': 'Wink', 'File': 'exp/wink.exp3.json'},
        ],
        motions: {
          'Idle': [
            {'File': 'motion/broken.motion3.json'},
            {'File': 'motion/idle.motion3.json'},
            {'File': 'motion/list.motion3.json'},
            {'File': 'motion/latin1.motion3.json'},
            {'File': 'motion/deep.motion3.json'},
          ],
          'Tap': 'motion/tap.motion3.json',
        },
        files: {
          'exp/smile.exp3.json': '{}',
          'exp/wink.exp3.json': '{"Wink":1}',
          'exp/big.exp3.json': '{"Pad":"${'x' * 40}"}',
          'motion/broken.motion3.json': '{"Version":',
          'motion/idle.motion3.json': '{}',
          'motion/list.motion3.json': '[]',
          'motion/latin1.motion3.json': [0x7b, 0xe9, 0x7d],
          'motion/deep.motion3.json': '${'[' * 65}${']' * 65}',
        },
      );
      const limits = Live2DPackageLimits(maxExpressionBytes: 32);
      const expected = [
        'expressionSkipped 0 model/exp/gone.exp3.json',
        'expressionSkipped 2 model/exp/wink.exp3.json',
        'expressionSkipped 3 model/exp/big.exp3.json',
        'expressionSkipped 4 model/exp/wink.exp3.json',
        'expressionSkipped 5 null',
        'expressionSkipped 6 null',
        'motionSkipped 0 model/motion/broken.motion3.json',
        'motionSkipped 2 model/motion/list.motion3.json',
        'motionSkipped 3 model/motion/latin1.motion3.json',
        'motionSkipped 4 model/motion/deep.motion3.json',
        'motionSkipped null null',
      ];
      final bundle = prepareLive2DPreview(zip, limits: limits);
      expect(bundle.warnings.map(describe), expected);
      final messages = [for (final w in bundle.warnings) w.message];
      expect(messages[0], contains('missing'));
      expect(messages[1], contains('duplicate Name "Smile"'));
      expect(messages[2], contains('exceeds 32 bytes'));
      expect(messages[3], contains('Name'));
      expect(messages[6],
          allOf(startsWith('group "Idle": '), contains('not valid JSON')));
      expect(messages[7], contains('not a JSON object'));
      expect(messages[8], contains('not UTF-8'));
      expect(messages[9], contains('nesting exceeds 64'));
      expect(messages[10], contains('"Tap"'));
      expect(fileRefsOf(bundle), {
        'Moc': 'model.moc3',
        'Textures': ['texture-0.png'],
        'Expressions': [
          {'Name': 'Smile', 'File': 'expression-0.exp3.json'},
          {'Name': 'Wink', 'File': 'expression-1.exp3.json'},
        ],
        'Motions': {
          'Idle': [
            {'File': 'motion-0.motion3.json'},
          ],
        },
      });
      expect(utf8.decode(bundle.files['expression-1.exp3.json']!),
          '{"Wink":1}');
      expect(bundle.files.keys, unorderedEquals([
        'model.model3.json', 'model.moc3', 'texture-0.png',
        'expression-0.exp3.json', 'expression-1.exp3.json',
        'motion-0.motion3.json',
      ]));
      final r = validateLive2DPackage(zip, limits: limits);
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      expect(r.warnings.map(describe), expected);
    });

    test('leaves out an entry whose data fails its checksum', () {
      final zip = _zip([
        ..._validEntries(
          model3Text: _model3(extra: {
            'Expressions': [
              {'Name': 'Smile', 'File': 'exp/smile.exp3.json'},
            ],
          }),
        ),
        ArchiveFile.noCompress('model/exp/smile.exp3.json', 12,
            Uint8List.fromList(utf8.encode('{"A":"QQQQ"}'))),
      ]);
      // Change one stored byte: the data is still JSON, the CRC is wrong.
      final needle = utf8.encode('QQQQ');
      var at = -1;
      for (var i = 0; at < 0 && i + needle.length <= zip.length; i++) {
        var match = true;
        for (var j = 0; match && j < needle.length; j++) {
          match = zip[i + j] == needle[j];
        }
        if (match) at = i;
      }
      expect(at, isNonNegative);
      zip[at] = 0x52;
      final r = validateLive2DPackage(zip);
      expect(r.ok, isTrue, reason: r.issues.join(', '));
      final bundle = prepareLive2DPreview(zip);
      for (final warnings in [r.warnings, bundle.warnings]) {
        expect(warnings.single.toString(),
            'expressionSkipped[0](model/exp/smile.exp3.json): '
            'invalid ZIP entry data');
      }
      expect(fileRefsOf(bundle), isNot(contains('Expressions')));
    });

    test('still rejects an unsafe expression or motion path', () {
      for (final extra in <Map<String, Object?>>[
        {
          'Expressions': [
            {'Name': 'Smile', 'File': '../smile.exp3.json'},
          ],
        },
        {
          'Motions': {
            'Idle': [
              {'File': 'motion/../../idle.motion3.json'},
            ],
          },
        },
      ]) {
        final zip = _zip(_validEntries(model3Text: _model3(extra: extra)));
        final r = validateLive2DPackage(zip);
        expect(r.ok, isFalse);
        expect(r.issues.single.code, Live2DPackageIssueCode.unsafeEntryPath);
        expect(r.warnings, isEmpty);
        expect(() => prepareLive2DPreview(zip), throwsFormatException);
      }
    });

    test('lists no Expressions or Motions when it keeps none', () {
      for (final zip in [
        _zip(_validEntries()),
        package(
          expressions: <Object?>[],
          motions: <String, Object?>{'Idle': <Object?>[]},
        ),
        package(
          expressions: [
            {'Name': 'Smile', 'File': 'exp/gone.exp3.json'},
          ],
          motions: {
            'Idle': [
              {'File': 'motion/gone.motion3.json'},
            ],
          },
        ),
      ]) {
        final bundle = prepareLive2DPreview(zip);
        expect(fileRefsOf(bundle), {
          'Moc': 'model.moc3',
          'Textures': ['texture-0.png'],
        });
        expect(bundle.files.keys, unorderedEquals(
            ['model.model3.json', 'model.moc3', 'texture-0.png']));
      }
    });

    test('leaves out what the preview byte cap cannot hold', () {
      final zip = package(
        expressions: [
          {'Name': 'Smile', 'File': 'exp/smile.exp3.json'},
        ],
        motions: {
          'Idle': [
            {'File': 'motion/idle.motion3.json', 'FadeInTime': 1},
          ],
        },
        files: {
          'exp/smile.exp3.json': '{}',
          'motion/idle.motion3.json': '{"Version":3}',
        },
      );
      // The model3 grows with each entry kept; an exact fit keeps them all.
      final size = sizeOf(prepareLive2DPreview(zip));
      expect(prepareLive2DPreview(zip, maxPreviewBytes: size).warnings,
          isEmpty);
      final capped = prepareLive2DPreview(zip, maxPreviewBytes: size - 1);
      expect(capped.files.keys, unorderedEquals([
        'model.model3.json', 'model.moc3', 'texture-0.png',
        'expression-0.exp3.json',
      ]));
      expect(capped.warnings.map(describe),
          ['motionSkipped 0 model/motion/idle.motion3.json']);
      expect(capped.warnings.single.message, contains('byte cap'));
      // Room for the model alone leaves both out; less fails as before.
      final base = sizeOf(prepareLive2DPreview(_zip(_validEntries())));
      expect(prepareLive2DPreview(zip, maxPreviewBytes: base).warnings,
          hasLength(2));
      expect(() => prepareLive2DPreview(zip, maxPreviewBytes: base - 1),
          throwsFormatException);
      // Validation has no byte cap.
      expect(validateLive2DPackage(zip).warnings, isEmpty);
    });

    test('keeps at most the capped number of entries', () {
      List<Map<String, Object?>> motionList(int count) => [
            for (var i = 0; i < count; i++) {'File': 'motion/m.motion3.json'},
          ];
      final zip = package(
        expressions: [
          for (var i = 0; i <= 1024; i++)
            {'Name': 'E$i', 'File': 'exp/e.exp3.json'},
        ],
        motions: {
          'Long': motionList(1025),
          for (var g = 0; g < 4; g++) 'G$g': motionList(1000),
        },
        files: {'exp/e.exp3.json': '{}', 'motion/m.motion3.json': '{}'},
      );
      // The repetitive model3 compresses far better than real packages.
      const limits = Live2DPackageLimits(maxCompressionRatio: 1 << 20);
      final bundle = prepareLive2DPreview(zip, limits: limits);
      expect(bundle.warnings.map(describe), [
        'expressionSkipped 1024 null',
        'motionSkipped 1024 null',
        'motionSkipped 72 null',
      ]);
      expect(bundle.warnings.last.message, contains('"G3"'));
      final refs = fileRefsOf(bundle) as Map<String, Object?>;
      expect(refs['Expressions'], hasLength(1024));
      final motions = refs['Motions'] as Map<String, Object?>;
      expect(motions.keys, ['Long', 'G0', 'G1', 'G2', 'G3']);
      expect(motions['Long'], hasLength(1024));
      expect(motions['G3'], hasLength(72));
      expect(bundle.files, contains('motion-4095.motion3.json'));
      expect(bundle.files, isNot(contains('motion-4096.motion3.json')));
      expect(validateLive2DPackage(zip, limits: limits).warnings.map(describe),
          bundle.warnings.map(describe));
    });

    test('leaves out long names and motion groups beyond the cap', () {
      final long = 'x' * 257;
      final zip = package(
        expressions: [
          {'Name': long, 'File': 'exp/e.exp3.json'},
          {'Name': 'x' * 256, 'File': 'exp/e.exp3.json'},
        ],
        motions: {
          long: [
            {'File': 'motion/m.motion3.json'},
          ],
          for (var g = 0; g < 4096; g++) 'G$g': <Object?>[],
        },
        files: {'exp/e.exp3.json': '{}', 'motion/m.motion3.json': '{}'},
      );
      const limits = Live2DPackageLimits(maxCompressionRatio: 1 << 20);
      final bundle = prepareLive2DPreview(zip, limits: limits);
      expect(bundle.warnings.map(describe), [
        'expressionSkipped 0 model/exp/e.exp3.json',
        'motionSkipped null null',
        'motionSkipped null null',
      ]);
      expect(bundle.warnings[1].message, contains('longer than 256'));
      expect(bundle.warnings[2].message, contains('1 left out'));
      expect(fileRefsOf(bundle), {
        'Moc': 'model.moc3',
        'Textures': ['texture-0.png'],
        'Expressions': [
          {'Name': 'x' * 256, 'File': 'expression-0.exp3.json'},
        ],
      });
    });
  });

  group('physics and pose staging', () {
    Uint8List package({required Map<String, String> files}) =>
        _zip([
          ..._validEntries(
            model3Text: _model3(extra: const {
              'Physics': 'phys/avatar.physics3.json',
              'Pose': 'pose/avatar.pose3.json',
            }),
          ),
          for (final MapEntry(key: path, value: text) in files.entries)
            _textFile('model/$path', text),
        ]);

    Object? fileRefsOf(Live2DPreviewBundle bundle) =>
        (jsonDecode(utf8.decode(bundle.files[bundle.model3Name]!))
            as Map<String, Object?>)['FileReferences'];

    String describe(Live2DPackageIssue issue) =>
        '${issue.code.name} ${issue.index} ${issue.path}';

    test('stages them under fixed names that the model3 lists', () {
      final zip = package(files: {
        'phys/avatar.physics3.json': '{"Version":3,"Meta":{}}',
        'pose/avatar.pose3.json': '{"Type":"Live2D Pose"}',
      });
      final bundle = prepareLive2DPreview(zip);
      expect(bundle.warnings, isEmpty);
      expect(utf8.decode(bundle.files['physics.physics3.json']!),
          '{"Version":3,"Meta":{}}');
      expect(utf8.decode(bundle.files['pose.pose3.json']!),
          '{"Type":"Live2D Pose"}');
      expect(fileRefsOf(bundle), {
        'Moc': 'model.moc3',
        'Textures': ['texture-0.png'],
        'Physics': 'physics.physics3.json',
        'Pose': 'pose.pose3.json',
      });
    });

    test('leaves out a bad file with a warning and keeps the model usable', () {
      final deep = '{"a":${List.filled(64, '[').join()}${List.filled(64, ']').join()}}';
      final bundle = prepareLive2DPreview(package(files: {
        'phys/avatar.physics3.json': '[]',
        'pose/avatar.pose3.json': deep,
      }));
      expect(bundle.warnings.map(describe), [
        'physicsSkipped null model/phys/avatar.physics3.json',
        'poseSkipped null model/pose/avatar.pose3.json',
      ]);
      expect(bundle.warnings.first.message, contains('not a JSON object'));
      expect(bundle.warnings.last.message, contains('nesting'));
      expect(bundle.files, isNot(contains('physics.physics3.json')));
      expect(bundle.files, isNot(contains('pose.pose3.json')));
      expect(fileRefsOf(bundle), {
        'Moc': 'model.moc3',
        'Textures': ['texture-0.png'],
      });
    });

    test('applies the physics and pose byte caps without failing the package',
        () {
      final zip = package(files: {
        'phys/avatar.physics3.json': '{"Version":3}',
        'pose/avatar.pose3.json': '{"Version":3}',
      });
      const limits =
          Live2DPackageLimits(maxPhysicsBytes: 8, maxPoseBytes: 8);
      final bundle = prepareLive2DPreview(zip, limits: limits);
      expect(bundle.warnings.map(describe), [
        'physicsSkipped null model/phys/avatar.physics3.json',
        'poseSkipped null model/pose/avatar.pose3.json',
      ]);
      expect(bundle.warnings.first.message, contains('exceeds 8 bytes'));
      expect(fileRefsOf(bundle), {
        'Moc': 'model.moc3',
        'Textures': ['texture-0.png'],
      });
      // Validation sees the same warnings, which are not fatal.
      final result = validateLive2DPackage(zip, limits: limits);
      expect(result.ok, isTrue);
      expect(result.warnings.map(describe), bundle.warnings.map(describe));
    });
  });
}
