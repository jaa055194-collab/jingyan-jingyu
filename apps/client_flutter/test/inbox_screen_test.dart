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
    expect(find.text('宿主尚未提供收件箱接口；邀请与通知在接入后显示。'), findsOneWidget);
  });
}
