import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

/// 最小 [PluginContext] 假件：房间生成器不依赖任何宿主能力。
class _FakeContext implements PluginContext {
  @override
  String get pluginId => 'jingyu.room.generator';

  @override
  bool has(PluginCapability capability) =>
      capability == PluginCapability.roomScene ||
      capability == PluginCapability.modelInvoke;

  @override
  Map<String, String> get storage => <String, String>{};

  @override
  Future<void> sendText(String conversationId, String text) async {}
}

RoomBrief _brief({
  String style = '现代公寓',
  String palette = '中性灰白',
  String mood = '舒适',
  List<String> rooms = const <String>[],
}) =>
    RoomBrief(style: style, palette: palette, mood: mood, rooms: rooms);

void main() {
  late FeiyuRoomGenerator generator;
  late PluginContext context;

  setUp(() {
    generator = FeiyuRoomGenerator();
    context = _FakeContext();
  });

  group('identity', () {
    test('id is jingyu.room.generator', () {
      expect(generator.id, 'jingyu.room.generator');
    });

    test('presets are exactly the five template directions', () {
      expect(generator.presets, <String>[
        '海边小屋',
        '森林木屋',
        '现代公寓',
        '赛博小屋',
        '中式小院',
      ]);
    });
  });

  group('generate: validation', () {
    test('rejects an empty style', () async {
      await expectLater(
        generator.generate(_brief(style: '   '), context),
        throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
      );
    });

    test('rejects an empty palette', () async {
      await expectLater(
        generator.generate(_brief(palette: ''), context),
        throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
      );
    });

    test('rejects an empty mood', () async {
      await expectLater(
        generator.generate(_brief(mood: '  '), context),
        throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
      );
    });

    test('rejects an unknown style', () async {
      await expectLater(
        generator.generate(_brief(style: '太空站'), context),
        throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
      );
    });

    test('accepts every preset style', () async {
      for (final style in generator.presets) {
        final layout = await generator.generate(_brief(style: style), context);
        expect(layout.style, style);
        expect(layout.rooms, isNotEmpty);
      }
    });
  });

  group('generate: output', () {
    test('is deterministic for the same brief', () async {
      final brief = _brief(style: '森林木屋', palette: '木色', mood: '温暖');
      final first = await generator.generate(brief, context);
      final second = await generator.generate(brief, context);
      expect(first.style, second.style);
      expect(first.rooms, second.rooms);
      expect(first.furniture, second.furniture);
    });

    test('falls back to a non-empty per-style default room set', () async {
      final seaside =
          await generator.generate(_brief(style: '海边小屋'), context);
      final modern = await generator.generate(_brief(style: '现代公寓'), context);
      expect(seaside.rooms, isNotEmpty);
      expect(modern.rooms, isNotEmpty);
      // 默认户型是按风格区分的，不是同一套。
      expect(seaside.rooms, isNot(equals(modern.rooms)));
    });

    test('honors explicit rooms from the brief', () async {
      final layout = await generator.generate(
        _brief(rooms: const <String>['客厅', '书房']),
        context,
      );
      expect(layout.rooms, <String>['客厅', '书房']);
    });

    test('furniture entries expose only schema fields with correct types',
        () async {
      final layout =
          await generator.generate(_brief(style: '现代公寓'), context);
      expect(layout.furniture, isNotEmpty);
      for (final item in layout.furniture) {
        expect(
          item.keys.toSet(),
          <String>{'kind', 'room', 'x', 'y', 'rotation'},
        );
        expect(item['kind'], isA<String>());
        expect((item['kind']! as String), isNotEmpty);
        expect(item['room'], isA<String>());
        expect(layout.rooms, contains(item['room']));
        expect(item['x'], isA<num>());
        expect(item['y'], isA<num>());
        expect(item['rotation'], isA<num>());
      }
    });

    test('contains no downloadable or executable fields', () async {
      const disallowed = <String>{
        'download',
        'downloadUrl',
        'url',
        'uri',
        'code',
        'script',
        'exec',
        'execute',
        'path',
        'file',
        'asset',
        'source',
        'html',
        'js',
      };
      for (final style in generator.presets) {
        final layout = await generator.generate(_brief(style: style), context);
        for (final item in layout.furniture) {
          for (final key in item.keys) {
            expect(disallowed.contains(key), isFalse,
                reason: 'unexpected field "$key"');
          }
          final kind = (item['kind']! as String).toLowerCase();
          expect(kind, isNot(contains('.js')));
          expect(kind, isNot(contains('http')));
        }
      }
    });
  });

  group('briefFromConversation', () {
    test('maps 海边 keyword to 海边小屋', () {
      final brief = generator.briefFromConversation('我想要一个海边的小屋，安静的蓝色调');
      expect(brief.style, '海边小屋');
      expect(brief.palette, isNotEmpty);
      expect(brief.mood, isNotEmpty);
    });

    test('maps the other style keywords', () {
      expect(generator.briefFromConversation('森林里的木屋').style, '森林木屋');
      expect(generator.briefFromConversation('赛博朋克风格').style, '赛博小屋');
      expect(generator.briefFromConversation('中式四合院').style, '中式小院');
      expect(generator.briefFromConversation('现代简约公寓').style, '现代公寓');
    });

    test('defaults to 现代公寓 and a neutral palette when unmatched', () {
      final brief = generator.briefFromConversation('随便什么都行 asdf 123');
      expect(brief.style, '现代公寓');
      expect(brief.palette, isNotEmpty);
      expect(brief.palette, contains('中性'));
      expect(brief.rooms, isEmpty);
    });

    test('never throws on arbitrary text', () {
      for (final prompt in <String>['', '   ', '😀😀😀', '!!!###???', 'a' * 2000]) {
        expect(() => generator.briefFromConversation(prompt), returnsNormally);
      }
    });

    test('trims and bounds notes at 500 code points', () {
      final brief = generator.briefFromConversation('  ${'房' * 1200}  ');
      expect(brief.notes.length, lessThanOrEqualTo(500));
      expect(brief.notes, brief.notes.trim());
    });

    test('detects room names from the prompt', () {
      final brief = generator.briefFromConversation('现代公寓，要有客厅、卧室和书房');
      expect(brief.rooms, containsAll(<String>['客厅', '卧室', '书房']));
    });

    test('produces a brief that generate accepts', () async {
      final brief = generator.briefFromConversation('海边小屋，蓝色，宁静');
      final layout = await generator.generate(brief, context);
      expect(layout.style, '海边小屋');
      expect(layout.rooms, isNotEmpty);
      expect(layout.furniture, isNotEmpty);
    });
  });
}
