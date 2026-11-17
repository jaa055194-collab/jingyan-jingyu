import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'app/runtime.dart';
import 'app/shell_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final runtime = ClientRuntime();
  runApp(WhaleChatApp(model: runtime));
  unawaited(runtime.initialize());
}
