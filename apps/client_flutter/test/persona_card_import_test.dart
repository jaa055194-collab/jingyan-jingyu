import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/features/ai_config/persona_card_import.dart';
import 'package:client_flutter/features/ai_config/persona_file_picker.dart';
import 'package:client_flutter/platform/native_platform.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _card({
  Map<String, Object?> p0 = const {'name': 'Nora'},
  Map<String, Object?> p1 = const {'style': 'warm'},
  Map<String, Object?> p2 = const {'mood': 'calm'},
  Map<String, Object?> extra = const {},
}) => {'format': personaCardFormat, 'p0': p0, 'p1': p1, 'p2': p2, ...extra};

List<int> _bytes(Object? value) => utf8.encode(jsonEncode(value));

void main() {
  group('persona card parser', () {
    test('accepts the fixed format and keeps per-layer order and counts', () {
      final card = PersonaCard.parseBytes(
        _bytes(
          _card(
            p0: {'name': 'Nora', 'role': 'guide'},
            p1: {'style': 'warm'},
            p2: {'mood': 'calm', 'pace': 'slow'},
          ),
        ),
      );
      expect(card.p0.keys, ['name', 'role']);
      expect(card.p0['role'], 'guide');
      expect(card.p1, {'style': 'warm'});
      expect(card.p2.keys, ['mood', 'pace']);
      expect(card.entries, 5);
      expect(card.summary, 'P0 2 项 · P1 1 项 · P2 2 项');
    });

    test('form text is key=value lines that round-trip to the same maps', () {
      final card = PersonaCard.parseBytes(
        _bytes(
          _card(p0: {'name': 'Nora', 'role': 'guide'}, p2: {'mood': '平静'}),
        ),
      );
      expect(card.formP0, 'name=Nora\nrole=guide');
      expect(card.formP1, 'style=warm');
      expect(card.formP2, 'mood=平静');
    });

    test(
      'rejects a different or missing format and extra top-level fields',
      () {
        for (final value in <Object?>[
          {..._card(), 'format': 'PRIVATE_AI_PERSONA_2'},
          {
            'p0': {'a': 'b'},
            'p1': {'a': 'b'},
            'p2': {'a': 'b'},
          },
          {..._card(), 'version': 1},
          {..._card(), 'memory': []},
        ]) {
          expect(
            () => PersonaCard.parseBytes(_bytes(value)),
            throwsA(isA<FormatException>()),
            reason: '$value',
          );
        }
      },
    );

    test('rejects non-object top level, missing layers and empty layers', () {
      for (final value in <Object?>[
        [],
        'card',
        {
          'format': personaCardFormat,
          'p0': {'a': 'b'},
          'p1': {'a': 'b'},
        },
        _card(p2: const {}),
        _card(p0: const {'': 'b'}),
        _card(p1: const {'a': ''}),
        {
          'format': personaCardFormat,
          'p0': null,
          'p1': {'a': 'b'},
          'p2': {'a': 'b'},
        },
        _card(p0: const {'a': 1}),
        _card(p1: const {'a': true}),
        _card(p2: const {'a': <String, String>{}}),
      ]) {
        expect(
          () => PersonaCard.parseBytes(_bytes(value)),
          throwsA(isA<FormatException>()),
          reason: '$value',
        );
      }
    });

    test('rejects malformed JSON, duplicate keys, BOM and non-UTF8 bytes', () {
      final cases = <List<int>>[
        utf8.encode('{"format":'),
        utf8.encode(
          '{"format":"$personaCardFormat","p0":{"a":"1","a":"2"},'
          '"p1":{"a":"b"},"p2":{"a":"b"}}',
        ),
        utf8.encode(
          '{"format":"$personaCardFormat","p0":{"a":"b"},'
          '"p0":{"c":"d"},"p1":{"a":"b"},"p2":{"a":"b"}}',
        ),
        [0xEF, 0xBB, 0xBF, ...utf8.encode(jsonEncode(_card()))],
        [0xFF, 0xFE],
      ];
      for (final (index, raw) in cases.indexed) {
        expect(
          () => PersonaCard.parseBytes(raw),
          throwsA(isA<FormatException>()),
          reason: 'case $index: $raw',
        );
      }
    });

    test('rejects control characters and enforces key/value length limits', () {
      for (final (key, value) in [
        ('a\u0001', 'b'),
        ('a', 'b\u007f'),
        ('a', 'b\u0085'),
        ('k' * personaCardMaxKeyChars + 'x', 'b'),
        ('a', 'v' * (personaCardMaxValueChars + 1)),
      ]) {
        expect(
          () => PersonaCard.parseBytes(_bytes(_card(p0: {key: value}))),
          throwsA(isA<FormatException>()),
          reason: 'key=$key',
        );
      }
      expect(
        PersonaCard.parseBytes(
          _bytes(
            _card(
              p0: {
                'k' * personaCardMaxKeyChars: 'v' * personaCardMaxValueChars,
              },
            ),
          ),
        ).p0.length,
        1,
      );
    });

    test('rejects more than 32 entries in any layer and accepts 32', () {
      Map<String, String> layer(int count) => {
        for (var i = 0; i < count; i++) 'k$i': 'v$i',
      };
      expect(
        PersonaCard.parseBytes(_bytes(_card(p1: layer(32)))).p1.length,
        32,
      );
      expect(
        () => PersonaCard.parseBytes(_bytes(_card(p2: layer(33)))),
        throwsA(isA<FormatException>()),
      );
    });

    test('enforces the 64 KiB byte limit on the encoded payload', () {
      final valid = utf8.encode(jsonEncode(_card()));
      final padded = [
        ...valid,
        ...List<int>.filled(personaCardMaxBytes - valid.length, 0x20),
      ];
      expect(padded.length, personaCardMaxBytes);
      expect(PersonaCard.parseBytes(padded).p0, {'name': 'Nora'});
      expect(
        () => PersonaCard.parseBytes([...padded, 0x20]),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => PersonaCard.parseBytes(
          List<int>.filled(personaCardMaxBytes + 1, 0x20),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => PersonaCard.parseBytes(const []),
        throwsA(isA<FormatException>()),
      );
    });

    test('refuses cards that the existing key=value form cannot represent', () {
      for (final (key, value) in [
        ('a=b', 'c'),
        (' name', 'c'),
        ('name', ' c'),
        ('name', 'c '),
      ]) {
        final card = PersonaCard.parseBytes(_bytes(_card(p0: {key: value})));
        expect(
          () => card.formP0,
          throwsA(isA<FormatException>()),
          reason: 'key=$key',
        );
      }
    });

    test('never echoes the raw payload in a failure message', () {
      try {
        PersonaCard.parseBytes(_bytes(_card(extra: {'secret-sentinel': 'x'})));
        fail('expected rejection');
      } on FormatException catch (error) {
        expect(error.message, isNot(contains('secret-sentinel')));
      }
    });

    test('pasted text enforces the same byte bound before parsing', () {
      final valid = jsonEncode(_card());
      final padded =
          '$valid${' ' * (personaCardMaxBytes - utf8.encode(valid).length)}';
      expect(PersonaCard.parseText(padded).p0, {'name': 'Nora'});
      expect(
        () => PersonaCard.parseText('$padded '),
        throwsA(isA<FormatException>()),
      );
    });

    test('the documented example card parses', () {
      final example = File('../../docs/examples/persona-sample.json');
      expect(example.existsSync(), isTrue);
      final card = PersonaCard.parseBytes(example.readAsBytesSync());
      expect(card.p0, {'name': '示例角色', 'role': '示例用途'});
      expect(card.p1, {'style': '示例表达风格'});
      expect(card.p2, {'mood': '示例情绪'});
    });
  });

  group('native persona file picker', () {
    late Directory directory;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('persona-import-test-');
    });
    tearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    Future<File> file(String name, List<int> bytes) async {
      final result = File('${directory.path}/$name');
      await result.writeAsBytes(bytes);
      return result;
    }

    test('cancel returns null without reading anything', () async {
      final platform = _FakePlatform(null);
      final import = await NativePersonaFilePicker(platform: platform).pick();
      expect(import, isNull);
      expect(platform.kinds, ['file']);
    });

    test(
      'reads a picked file once and removes only the temporary copy',
      () async {
        final temporary = await file('temp-card.json', _bytes(_card()));
        final selected = await file('user-card.json', _bytes(_card()));
        final platform = _FakePlatform(
          PickedAttachment(
            path: temporary.path,
            name: 'temp-card.json',
            temporary: true,
          ),
        );
        final import = await NativePersonaFilePicker(platform: platform).pick();
        expect(import, isNotNull);
        expect(import!.name, 'temp-card.json');
        expect(import.card.p1, {'style': 'warm'});
        expect(temporary.existsSync(), isFalse);
        expect(selected.existsSync(), isTrue);

        platform.next = PickedAttachment(
          path: selected.path,
          name: 'user-card.json',
        );
        await NativePersonaFilePicker(platform: platform).pick();
        expect(
          selected.existsSync(),
          isTrue,
          reason: 'user-owned files are never deleted',
        );
      },
    );

    test(
      'rejects oversize, invalid and non-UTF8 files without retaining content',
      () async {
        for (final (name, bytes, problem) in [
          (
            'big.json',
            List<int>.filled(personaCardMaxBytes + 1, 0x20),
            PersonaFileProblem.tooLarge,
          ),
          (
            'bad.json',
            utf8.encode('{"format":"nope"}'),
            PersonaFileProblem.invalid,
          ),
          ('bytes.json', [0xFF, 0xFE, 0xFD], PersonaFileProblem.invalid),
        ]) {
          final selected = await file(name, bytes);
          final platform = _FakePlatform(
            PickedAttachment(path: selected.path, name: name, temporary: true),
          );
          await expectLater(
            NativePersonaFilePicker(platform: platform).pick(),
            throwsA(
              isA<PersonaFileImportException>()
                  .having((error) => error.problem, 'problem', problem)
                  .having(
                    (error) => error.toString(),
                    'message',
                    isNot(contains(directory.path)),
                  ),
            ),
          );
          expect(
            selected.existsSync(),
            isFalse,
            reason: 'temporary copy removed on $name',
          );
        }
      },
    );

    test('picker failure is unreadable and never exposes a path', () async {
      final platform = _FakePlatform(null, fail: true);
      await expectLater(
        NativePersonaFilePicker(platform: platform).pick(),
        throwsA(
          isA<PersonaFileImportException>().having(
            (error) => error.problem,
            'problem',
            PersonaFileProblem.unreadable,
          ),
        ),
      );
    });

    test(
      'source name is a basename even if the picker returns a path',
      () async {
        expect(
          PersonaFileImport.safeSourceName(r'C:\Users\private\我的\persona.json'),
          'persona.json',
        );
        expect(
          PersonaFileImport.safeSourceName('/tmp/private/card.json'),
          'card.json',
        );
        expect(PersonaFileImport.safeSourceName(r'C:\Users\private\'), '所选文件');
        expect(PersonaFileImport.safeSourceName('bad\nname.json'), '所选文件');
      },
    );
  });
}

class _FakePlatform extends NativePlatform {
  _FakePlatform(this.next, {this.fail = false});

  PickedAttachment? next;
  final bool fail;
  final List<String> kinds = [];

  @override
  Future<PickedAttachment?> pickAttachment(String kind) async {
    kinds.add(kind);
    if (fail) throw PlatformException(code: 'unavailable');
    return next;
  }
}
