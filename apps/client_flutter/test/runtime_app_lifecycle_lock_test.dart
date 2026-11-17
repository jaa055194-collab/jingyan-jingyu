import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_flutter/app/runtime.dart';

import 'runtime_auth_test.dart' show Fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  Future<ClientRuntime> lockedRuntime(Fixture f) async {
    await File('${f.root.path}/settings.json').writeAsString(
      jsonEncode({
        'appLock': {'enabled': true},
      }),
    );
    final runtime = ClientRuntime();
    await runtime.initialize();
    return runtime;
  }

  test(
    'inactive locks an enabled app lock (split-screen/app-switcher exposure)',
    () async {
      final f = await Fixture.create();
      final runtime = await lockedRuntime(f);
      try {
        expect(runtime.locked, isTrue, reason: 'restart starts locked');
        runtime.didChangeAppLifecycleState(AppLifecycleState.inactive);
        expect(runtime.locked, isTrue);
      } finally {
        runtime.dispose();
        await f.cleanup();
      }
    },
  );

  test('paused and hidden still lock (existing behavior unchanged)', () async {
    final f = await Fixture.create();
    final runtime = await lockedRuntime(f);
    try {
      runtime.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(runtime.locked, isTrue);
      runtime.didChangeAppLifecycleState(AppLifecycleState.hidden);
      expect(runtime.locked, isTrue);
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });

  test('resumed and detached never unlock an enabled app lock', () async {
    final f = await Fixture.create();
    final runtime = await lockedRuntime(f);
    try {
      expect(runtime.locked, isTrue, reason: 'restart starts locked');
      runtime.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(runtime.locked, isTrue, reason: 'resume must not silently unlock');
      runtime.didChangeAppLifecycleState(AppLifecycleState.detached);
      expect(runtime.locked, isTrue, reason: 'detached must not unlock');
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });

  test('disabled app lock never locks on any lifecycle event', () async {
    final f = await Fixture.create();
    final runtime = ClientRuntime();
    try {
      await runtime.initialize();
      expect(runtime.appLockEnabled, isFalse);
      for (final state in AppLifecycleState.values) {
        runtime.didChangeAppLifecycleState(state);
        expect(runtime.locked, isFalse, reason: state.name);
      }
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });

  test('shouldLockForLifecycle covers inactive/hidden/paused only', () {
    expect(
      ClientRuntime.shouldLockForLifecycle(AppLifecycleState.inactive),
      isTrue,
    );
    expect(
      ClientRuntime.shouldLockForLifecycle(AppLifecycleState.hidden),
      isTrue,
    );
    expect(
      ClientRuntime.shouldLockForLifecycle(AppLifecycleState.paused),
      isTrue,
    );
    expect(
      ClientRuntime.shouldLockForLifecycle(AppLifecycleState.resumed),
      isFalse,
    );
    expect(
      ClientRuntime.shouldLockForLifecycle(AppLifecycleState.detached),
      isFalse,
    );
  });
}
