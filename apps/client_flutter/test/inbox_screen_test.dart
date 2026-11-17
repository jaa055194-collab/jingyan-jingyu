import 'package:client_flutter/features/inbox/inbox_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('inbox without a host route is an honest unavailable state', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: InboxScreen())),
    );
    // Post PR#101 copy: explicitly lists the current gap and what will appear
    // once the host route is wired.
    expect(find.text('当前缺口：宿主未提供收件箱/通知路由。'), findsOneWidget);
    expect(find.text('接入后此处将显示邀请与通知；数据来自宿主实时读取。'), findsOneWidget);
  });
}
