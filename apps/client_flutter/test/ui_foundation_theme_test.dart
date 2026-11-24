import 'package:client_flutter/app/app_theme.dart';
import 'package:client_flutter/app/status_panel.dart';
import 'package:client_flutter/ui/jy_motion.dart';
import 'package:client_flutter/ui/jy_palette.dart';
import 'package:client_flutter/ui/jy_tokens.dart';
import 'package:client_flutter/ui/jy_typography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// WCAG contrast ratio of two opaque colours.
double _contrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
}

/// An app on [buildAppTheme]; [reduceMotion] stands in for the system
/// setting.
Widget _app(Brightness brightness, Widget home, {bool reduceMotion = false}) {
  return MaterialApp(
    theme: buildAppTheme(brightness),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: home,
  );
}

void main() {
  for (final Brightness brightness in Brightness.values) {
    final JyPalette p = JyPalette.fallback(brightness);

    group('${brightness.name} theme', () {
      test('maps the palette onto the ColorScheme (section 4)', () {
        final ColorScheme s = appColorScheme(brightness);
        expect(s.brightness, brightness);
        expect(s.primary, p.signal);
        expect(s.onPrimary, p.onSignal);
        expect(s.primaryContainer, p.signalSoft);
        expect(s.onPrimaryContainer, p.onSignalSoft);
        expect(s.secondary, p.ember);
        expect(s.onSecondary, p.onEmber);
        expect(s.secondaryContainer, p.emberSoft);
        expect(s.onSecondaryContainer, p.onEmberSoft);
        expect(s.error, p.danger);
        expect(s.onError, p.onDanger);
        expect(s.errorContainer, p.dangerSoft);
        expect(s.onErrorContainer, p.onDangerSoft);
        expect(s.surface, p.slab);
        expect(s.onSurface, p.text1);
        expect(s.onSurfaceVariant, p.text2);
        expect(s.surfaceContainerLowest, p.canvas);
        expect(s.surfaceContainerLow, p.slab);
        expect(s.surfaceContainer, p.raised);
        expect(s.surfaceContainerHigh, p.overlay);
        expect(s.outline, p.outline);
        expect(s.outlineVariant, p.hairline);
        expect(s.surfaceTint.a, 0, reason: 'surfaces are never tinted');
        expect(buildAppTheme(brightness).colorScheme, s);
      });

      test('text is at least 4.5:1 and outlines 3:1 on every surface', () {
        final Map<String, Color> surfaces = <String, Color>{
          'canvas': p.canvas,
          'slab': p.slab,
          'raised': p.raised,
          'overlay': p.overlay,
        };
        final Map<String, Color> texts = <String, Color>{
          'text1': p.text1,
          'text2': p.text2,
          'text3': p.text3,
        };
        for (final MapEntry<String, Color> surface in surfaces.entries) {
          for (final MapEntry<String, Color> text in texts.entries) {
            expect(
              _contrast(text.value, surface.value),
              greaterThanOrEqualTo(4.5),
              reason: '${text.key} on ${surface.key}',
            );
          }
          expect(
            _contrast(p.outline, surface.value),
            greaterThanOrEqualTo(3),
            reason: 'outline on ${surface.key}',
          );
        }
      });

      test('content colours are at least 4.5:1 on their fills', () {
        final Map<String, (Color, Color)> pairs = <String, (Color, Color)>{
          'onSignal on signal': (p.onSignal, p.signal),
          'onSignalSoft on signalSoft': (p.onSignalSoft, p.signalSoft),
          'onEmber on ember': (p.onEmber, p.ember),
          'onEmberSoft on emberSoft': (p.onEmberSoft, p.emberSoft),
          'onDanger on danger': (p.onDanger, p.danger),
          'onDangerSoft on dangerSoft': (p.onDangerSoft, p.dangerSoft),
        };
        for (final MapEntry<String, (Color, Color)> pair in pairs.entries) {
          final (Color ink, Color fill) = pair.value;
          expect(
            _contrast(ink, fill),
            greaterThanOrEqualTo(4.5),
            reason: pair.key,
          );
        }
      });

      test('carries the palette, the canvas and the type scale', () {
        final ThemeData theme = buildAppTheme(brightness);
        expect(theme.useMaterial3, isTrue);
        expect(theme.extension<JyPalette>(), p);
        expect(theme.scaffoldBackgroundColor, p.canvas);
        final TextTheme text = theme.textTheme;
        expect(text.bodyMedium?.fontSize, 15);
        expect(text.bodyMedium?.color, p.text1);
        expect(text.titleLarge?.fontSize, 20);
        expect(text.titleLarge?.fontWeight, FontWeight.w600);
        for (final TextStyle? style in <TextStyle?>[
          text.bodySmall,
          text.labelSmall,
        ]) {
          expect(
            style?.fontSize,
            greaterThanOrEqualTo(JyTypography.minBodySize),
          );
        }
      });

      test('themes components with tokens and without elevation', () {
        final ThemeData t = buildAppTheme(brightness);
        expect(t.appBarTheme.backgroundColor, p.canvas);
        expect(t.appBarTheme.scrolledUnderElevation, 0);
        expect(t.cardTheme.color, p.slab);
        expect(t.cardTheme.elevation, 0);
        expect(t.dialogTheme.backgroundColor, p.overlay);
        expect(t.dialogTheme.elevation, 0);
        expect(t.dialogTheme.shape, JyShapes.dialog);
        expect(t.dialogTheme.barrierColor, p.scrim);
        expect(t.bottomSheetTheme.modalBackgroundColor, p.overlay);
        expect(t.bottomSheetTheme.modalElevation, 0);
        expect(t.bottomSheetTheme.shape, JyShapes.sheet);
        expect(t.bottomSheetTheme.showDragHandle, isTrue);
        expect(t.bottomSheetTheme.modalBarrierColor, p.scrim);
        expect(t.listTileTheme.selectedTileColor, p.signalSoft);
        expect(t.inputDecorationTheme.fillColor, p.raised);
        expect(t.dividerTheme.color, p.hairline);
        expect(t.dividerTheme.thickness, 1);
        expect(t.navigationBarTheme.indicatorColor, p.signalSoft);
        expect(t.navigationBarTheme.elevation, 0);
        expect(t.navigationRailTheme.indicatorColor, p.signalSoft);
        expect(t.progressIndicatorTheme.color, p.signal);
        expect(t.snackBarTheme.backgroundColor, p.overlay);
        expect(t.popupMenuTheme.color, p.overlay);
        expect(t.popupMenuTheme.elevation, 0);
        final Set<WidgetState> idle = <WidgetState>{};
        for (final ButtonStyle? style in <ButtonStyle?>[
          t.filledButtonTheme.style,
          t.outlinedButtonTheme.style,
          t.textButtonTheme.style,
          t.elevatedButtonTheme.style,
        ]) {
          expect(
            style?.minimumSize?.resolve(idle)?.height,
            JySpace.touchTarget,
          );
          expect(style?.shape?.resolve(idle), JyShapes.button);
        }
        expect(t.elevatedButtonTheme.style?.elevation?.resolve(idle), 0);
        for (final TargetPlatform platform in TargetPlatform.values) {
          expect(
            t.pageTransitionsTheme.builders[platform],
            isA<JyPageTransitionsBuilder>(),
          );
        }
      });
    });
  }

  test('the palette interpolates and copies like a theme extension', () {
    expect(JyPalette.dark.lerp(JyPalette.light, 0), JyPalette.dark);
    expect(JyPalette.dark.lerp(JyPalette.light, 1), JyPalette.light);
    expect(JyPalette.light.copyWith(), JyPalette.light);
    expect(
      JyPalette.light.copyWith(signal: JyPalette.dark.signal).signal,
      JyPalette.dark.signal,
    );
  });

  testWidgets('widgets read the attached palette from the theme', (
    tester,
  ) async {
    for (final Brightness brightness in Brightness.values) {
      JyPalette? attached;
      JyPalette? read;
      await tester.pumpWidget(
        _app(
          brightness,
          Builder(
            builder: (BuildContext context) {
              attached = Theme.of(context).extension<JyPalette>();
              read = JyPalette.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(attached, JyPalette.fallback(brightness));
      expect(read, JyPalette.fallback(brightness));
    }
  });

  group('StatusPanel', () {
    Finder entrance() => find.descendant(
      of: find.byType(StatusPanel),
      matching: find.byType(TweenAnimationBuilder<double>),
    );

    testWidgets('draws every tone in both themes with palette colours', (
      tester,
    ) async {
      for (final Brightness brightness in Brightness.values) {
        final JyPalette p = JyPalette.fallback(brightness);
        for (final StatusTone tone in StatusTone.values) {
          await tester.pumpWidget(
            _app(
              brightness,
              Scaffold(
                body: StatusPanel(
                  icon: Icons.inbox_outlined,
                  title: '暂无内容',
                  detail: '新的会话会出现在这里',
                  tone: tone,
                  action: FilledButton(
                    onPressed: () {},
                    child: const Text('刷新'),
                  ),
                  fill: true,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(tester.widget<Text>(find.text('暂无内容')).style?.color, p.text1);
          expect(
            tester.widget<Text>(find.text('新的会话会出现在这里')).style?.color,
            p.text2,
          );
          expect(
            tester.widget<Icon>(find.byIcon(Icons.inbox_outlined)).color,
            switch (tone) {
              StatusTone.empty => p.text2,
              StatusTone.offline => p.warning,
              StatusTone.error => p.danger,
            },
          );
        }
      }
    });

    testWidgets('an error is a live region; the badge is decorative', (
      tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        _app(
          Brightness.dark,
          const Scaffold(
            body: StatusPanel(
              icon: Icons.error_outline,
              title: '没能读取',
              tone: StatusTone.error,
            ),
          ),
        ),
      );
      expect(
        tester.getSemantics(find.text('没能读取')),
        isSemantics(label: '没能读取', isLiveRegion: true),
      );
      await tester.pumpAndSettle();
      semantics.dispose();
    });

    testWidgets('appears at once with reduced motion', (tester) async {
      await tester.pumpWidget(
        _app(
          Brightness.light,
          const Scaffold(
            body: StatusPanel(icon: Icons.inbox_outlined, title: '暂无内容'),
          ),
          reduceMotion: true,
        ),
      );
      expect(entrance(), findsNothing);
      expect(find.text('暂无内容'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('otherwise fades in over fadeDuration and settles', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          Brightness.light,
          const Scaffold(
            body: StatusPanel(icon: Icons.inbox_outlined, title: '暂无内容'),
          ),
        ),
      );
      double opacity() => tester
          .widget<Opacity>(
            find.descendant(of: entrance(), matching: find.byType(Opacity)),
          )
          .opacity;
      expect(
        find.descendant(of: entrance(), matching: find.byType(RepaintBoundary)),
        findsWidgets,
      );
      expect(opacity(), 0);
      await tester.pump(StatusPanel.fadeDuration ~/ 2);
      expect(opacity(), inExclusiveRange(0, 1));
      await tester.pump(StatusPanel.fadeDuration ~/ 2);
      expect(opacity(), 1);
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  testWidgets('themed components render, open, close and navigate', (
    tester,
  ) async {
    for (final Brightness brightness in Brightness.values) {
      for (final bool reduceMotion in <bool>[false, true]) {
        await tester.pumpWidget(
          _app(brightness, const _Gallery(), reduceMotion: reduceMotion),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('对话框'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);

        await tester.tap(find.text('面板'));
        await tester.pumpAndSettle();
        expect(find.text('面板内容'), findsOneWidget);
        await tester.tap(find.text('收起'));
        await tester.pumpAndSettle();
        expect(find.text('面板内容'), findsNothing);

        await tester.tap(find.text('下一页'));
        await tester.pumpAndSettle();
        expect(find.text('第二页'), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('第二页'), findsNothing);

        await tester.tap(find.byType(PopupMenuButton<int>));
        await tester.pumpAndSettle();
        await tester.tap(find.text('菜单项'));
        await tester.pumpAndSettle();
        expect(find.text('菜单项'), findsNothing);

        await tester.tap(find.text('提示'));
        await tester.pumpAndSettle();
        expect(find.text('已保存'), findsOneWidget);
        ScaffoldMessenger.of(tester.element(find.byType(_Gallery)))
            .hideCurrentSnackBar();
        await tester.pumpAndSettle();
        expect(find.text('已保存'), findsNothing);

        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('设置'),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    }
  });
}

/// One of each themed component, with ways to open a dialog, a sheet, a
/// page, a menu and a snack bar.
class _Gallery extends StatefulWidget {
  const _Gallery();

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  bool _on = true;
  double _level = 0.4;
  int _tab = 0;

  void _openDialog() {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('标题'),
        content: const Text('内容'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _openSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext context) => Padding(
        padding: const EdgeInsets.all(JySpace.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('面板内容'),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('收起'),
            ),
          ],
        ),
      ),
    );
  }

  void _openPage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            Scaffold(appBar: AppBar(title: const Text('第二页'))),
      ),
    );
  }

  void _showSnackBar() {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已保存')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('组件'),
        actions: <Widget>[
          IconButton(
            tooltip: '更多',
            onPressed: () {},
            icon: const Icon(Icons.more_horiz),
          ),
        ],
      ),
      body: Row(
        children: <Widget>[
          NavigationRail(
            selectedIndex: _tab,
            onDestinationSelected: (int i) => setState(() => _tab = i),
            labelType: NavigationRailLabelType.all,
            destinations: const <NavigationRailDestination>[
              NavigationRailDestination(
                icon: Icon(Icons.chat_bubble_outline),
                label: Text('会话'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                label: Text('设置'),
              ),
            ],
          ),
          const VerticalDivider(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(JySpace.lg),
              children: <Widget>[
                Wrap(
                  spacing: JySpace.sm,
                  runSpacing: JySpace.sm,
                  children: <Widget>[
                    FilledButton(
                      onPressed: _openDialog,
                      child: const Text('对话框'),
                    ),
                    OutlinedButton(
                      onPressed: _openSheet,
                      child: const Text('面板'),
                    ),
                    TextButton(onPressed: _openPage, child: const Text('下一页')),
                    FilledButton.tonal(
                      onPressed: _showSnackBar,
                      child: const Text('提示'),
                    ),
                    ElevatedButton(onPressed: () {}, child: const Text('凸起')),
                    PopupMenuButton<int>(
                      itemBuilder: (BuildContext context) =>
                          const <PopupMenuEntry<int>>[
                            PopupMenuItem<int>(value: 1, child: Text('菜单项')),
                          ],
                    ),
                  ],
                ),
                const SizedBox(height: JySpace.lg),
                const Card(
                  child: ListTile(title: Text('卡片'), subtitle: Text('说明')),
                ),
                ListTile(
                  selected: true,
                  leading: const Icon(Icons.star_outline),
                  title: const Text('选中的行'),
                  onTap: () {},
                ),
                const Divider(),
                const TextField(
                  decoration: InputDecoration(
                    labelText: '输入',
                    hintText: '提示文字',
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Switch(
                    value: _on,
                    onChanged: (bool on) => setState(() => _on = on),
                  ),
                ),
                Slider(
                  value: _level,
                  onChanged: (double level) => setState(() => _level = level),
                ),
                Wrap(
                  spacing: JySpace.sm,
                  children: <Widget>[
                    const Chip(label: Text('标签')),
                    FilterChip(
                      selected: true,
                      label: const Text('已选'),
                      onSelected: (bool selected) {},
                    ),
                  ],
                ),
                const SizedBox(height: JySpace.lg),
                const LinearProgressIndicator(value: 0.4),
                const SizedBox(height: JySpace.lg),
                const Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: CircularProgressIndicator(value: 0.6),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (int i) => setState(() => _tab = i),
        destinations: const <Widget>[
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            label: '会话',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
