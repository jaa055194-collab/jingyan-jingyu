import 'package:client_flutter/app/app_theme.dart';
import 'package:client_flutter/ui/jy_palette.dart';
import 'package:client_flutter/ui/jy_surfaces.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _app(Brightness brightness, Widget child) {
  return MaterialApp(
    theme: buildAppTheme(brightness),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: <Widget>[child]),
      ),
    ),
  );
}

void main() {
  for (final Brightness brightness in Brightness.values) {
    group('${brightness.name}:', () {
      testWidgets('JySlab paints its tone colour without elevation', (
        WidgetTester tester,
      ) async {
        for (final JyTone tone in JyTone.values) {
          await tester.pumpWidget(
            _app(brightness, JySlab(tone: tone, child: const Text('slab'))),
          );
          final JyPalette palette = JyPalette.of(
            tester.element(find.text('slab')),
          );
          final Material material = tester.widget<Material>(
            find
                .descendant(
                  of: find.byType(JySlab),
                  matching: find.byType(Material),
                )
                .first,
          );
          final Color expected = switch (tone) {
            JyTone.slab => palette.slab,
            JyTone.raised => palette.raised,
            JyTone.overlay => palette.overlay,
          };
          expect(material.color, expected);
          expect(material.elevation, 0);
        }
      });

      testWidgets('JySlab calls onTap, and a floating slab casts a shadow', (
        WidgetTester tester,
      ) async {
        int taps = 0;
        await tester.pumpWidget(
          _app(
            brightness,
            JySlab(
              floating: true,
              onTap: () => taps++,
              child: const Text('slab'),
            ),
          ),
        );
        await tester.tap(find.text('slab'));
        await tester.pumpAndSettle();
        expect(taps, 1);
        final DecoratedBox shadow = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(JySlab),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect((shadow.decoration as ShapeDecoration).shadows, isNotEmpty);
      });

      testWidgets('JyGroup draws a hairline between rows', (
        WidgetTester tester,
      ) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        await tester.pumpWidget(
          _app(
            brightness,
            const JyGroup(
              header: '通知',
              footer: '只在本机生效',
              children: <Widget>[Text('a'), Text('b'), Text('c')],
            ),
          ),
        );
        expect(
          find.descendant(
            of: find.byType(JyGroup),
            matching: find.byType(Divider),
          ),
          findsNWidgets(2),
        );
        expect(
          tester.getSemantics(find.text('通知')),
          isSemantics(label: '通知', isHeader: true),
        );
        expect(find.text('只在本机生效'), findsOneWidget);
        handle.dispose();
      });

      testWidgets('JyBadge shows 99+ above 99 and nothing at zero', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(_app(brightness, const JyBadge(count: 120)));
        expect(find.text('99+'), findsOneWidget);
        await tester.pumpWidget(_app(brightness, const JyBadge(count: 7)));
        expect(find.text('7'), findsOneWidget);
        await tester.pumpWidget(_app(brightness, const JyBadge(count: 0)));
        expect(
          find.descendant(
            of: find.byType(JyBadge),
            matching: find.byType(Text),
          ),
          findsNothing,
        );
      });

      testWidgets('JyIconTile is a 36dp tile', (WidgetTester tester) async {
        await tester.pumpWidget(
          _app(brightness, const JyIconTile(icon: Icons.notifications_none)),
        );
        expect(
          tester.getSize(find.byType(JyIconTile)),
          const Size.square(JyIconTile.size),
        );
        expect(find.byIcon(Icons.notifications_none), findsOneWidget);
      });

      testWidgets('JyBanner reads its message as a live region and closes', (
        WidgetTester tester,
      ) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        const Key messageKey = Key('banner-message');
        int closes = 0;
        for (final JyBannerKind kind in JyBannerKind.values) {
          await tester.pumpWidget(
            _app(
              brightness,
              JyBanner(
                message: '连接已断开',
                kind: kind,
                messageKey: messageKey,
                closeTooltip: '关闭连接提示',
                onClose: () => closes++,
              ),
            ),
          );
          expect(tester.widget<Text>(find.byKey(messageKey)).data, '连接已断开');
          expect(
            tester.getSemantics(find.byKey(messageKey)),
            isSemantics(label: '连接已断开', isLiveRegion: true),
          );
          await tester.tap(find.byTooltip('关闭连接提示'));
          await tester.pumpAndSettle();
        }
        expect(closes, JyBannerKind.values.length);
        await tester.pumpWidget(
          _app(brightness, const JyBanner(message: '已保存')),
        );
        expect(find.byType(IconButton), findsNothing);
        handle.dispose();
      });
    });
  }
}
