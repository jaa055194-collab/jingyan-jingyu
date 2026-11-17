import 'package:flutter_test/flutter_test.dart';
import 'package:client_flutter/app/runtime.dart';

void main() {
  test('runtime exposes loading state before native initialization', () {
    final runtime = ClientRuntime();
    expect(runtime.ready, isFalse);
    expect(runtime.onboarded, isFalse);
    expect(runtime.online, isFalse);
    expect(runtime.messages, isEmpty);
  });
}
