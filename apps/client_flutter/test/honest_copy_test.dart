import 'package:client_flutter/features/contacts/contacts_screen.dart';
import 'package:client_flutter/features/creative/creative_screen.dart';
import 'package:client_flutter/features/inbox/inbox_screen.dart';
import 'package:client_flutter/features/world/world_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

void main() {
  testWidgets('inbox lists the current gap and what appears after wiring', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: InboxScreen())));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inbox-gap')), findsOneWidget);
    expect(find.textContaining('当前缺口：宿主未提供收件箱/通知路由'), findsOneWidget);
    expect(find.byKey(const Key('inbox-after-wiring')), findsOneWidget);
    expect(find.textContaining('接入后此处将显示邀请与通知'), findsOneWidget);
    expect(find.textContaining('数据来自宿主实时读取'), findsOneWidget);
    // Still honest: no fabricated notification/invite rows.
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('contacts page shows the real-time host note', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ContactsScreen())));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('contacts-live-note')), findsOneWidget);
    expect(find.textContaining('数据来自宿主实时读取'), findsOneWidget);
  });

  testWidgets('creative page shows the real-time host note in loaded content', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CreativeScreen(
            loadReports: () async => const [],
            loadRadio: () async => const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('creative-live-note')), findsOneWidget);
    expect(find.textContaining('数据来自宿主实时读取'), findsOneWidget);
    expect(find.textContaining('不触发生成或播放'), findsOneWidget);
  });

  testWidgets('world page shows the real-time host note', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorldScreen(model: TestShellModel(), onOpenSetup: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('world-live-note')), findsOneWidget);
    expect(find.textContaining('数据来自宿主实时读取'), findsOneWidget);
    expect(find.textContaining('不修改世界配置'), findsOneWidget);
  });
}
