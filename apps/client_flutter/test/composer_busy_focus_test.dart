import 'package:client_flutter/app/shell_app.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

Finder get _composer => find.byKey(const Key('composer'));

FocusNode _composerFocus(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(of: _composer, matching: find.byType(EditableText)),
    )
    .focusNode;

VoidCallback? _send(WidgetTester tester) => tester
    .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send))
    .onPressed;

void main() {
  testWidgets('the composer keeps focus and the keyboard while busy', (
    tester,
  ) async {
    final model = TestShellModel();
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.tap(find.text('小鲸'));
    await tester.pumpAndSettle();
    await tester.enterText(_composer, '先打的字');
    await tester.pump();
    expect(_composerFocus(tester).hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(_send(tester), isNotNull);

    // A busy model (a send in flight) only blocks sending, not typing.
    model
      ..busy = true
      ..notifyListeners();
    await tester.pump();
    expect(_composerFocus(tester).hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(_send(tester), isNull);

    await tester.enterText(_composer, '先打的字，忙碌时接着打');
    await tester.pump();
    expect(model.draft, '先打的字，忙碌时接着打');
    expect(_send(tester), isNull);

    // Enter is a newline in this multi-line composer, so it never sends.
    final sent = model.messages.length;
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pump();
    expect(model.messages.length, sent);
    expect(_composerFocus(tester).hasFocus, isTrue);

    model
      ..busy = false
      ..notifyListeners();
    await tester.pump();
    expect(_composerFocus(tester).hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
    expect(_send(tester), isNotNull);
  });
}
