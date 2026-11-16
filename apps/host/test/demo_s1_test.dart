import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import '../tool/demo_s1.dart';

void main() {
  test('nonempty host shutdown errors fail verification', () {
    expect(() => checkDemoShutdownErrors(const []), returnsNormally);
    expect(
      () => checkDemoShutdownErrors([StateError('synthetic')]),
      throwsStateError,
    );
  });

  test('ordinary CLI stdout is JSON with no local credential', () async {
    final directory = await Directory.systemTemp.createTemp(
      'jingyu-s1-cli-test-',
    );
    try {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/demo_s1.dart',
        '--port',
        '0',
        '--data-dir',
        directory.path,
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final output = result.stdout.toString();
      final evidence = (jsonDecode(output) as Map).cast<String, Object?>();
      expect(evidence['dataDir'], directory.absolute.path);
      final config =
          (jsonDecode(
                    await File(
                      '${directory.path}/demo_s1.fixture.local.json',
                    ).readAsString(),
                  )
                  as Map)
              .cast<String, Object?>();
      // Boolean matcher prevents a secret being printed on assertion failure.
      expect(output.contains(config['passphrase']! as String), isFalse);
      expect(output.contains('Synthetic login:'), isFalse);
      expect(evidence['messagesAfterRestart'], 2);
    } finally {
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  // Fails if the tool bypasses HTTP, misses canonical S1 dispatch, or loses it
  // on database reopen. This runs the real production host, not a mock server.
  test(
    'HTTP login, group, canonical S1 reply survive database reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'jingyu-s1-test-',
      );
      DemoS1? demo;
      try {
        demo = await DemoS1.open(directory.path);
        final originalPassphrase = demo.passphrase;
        expect(originalPassphrase.length >= 32, isTrue);
        final evidence = await demo.verifyRoundTrip();
        expect(evidence.toString().contains(originalPassphrase), isFalse);
        expect(evidence['loginStatus'], 200);
        expect(evidence['groupVisible'], isTrue);
        expect(evidence['senderId'], 'demo_ai');
        expect(evidence['text'], '你好呀');
        expect(evidence['source'], 's1');
        expect(evidence['messagesBeforeRestart'], 2);
        expect(evidence['messagesAfterRestart'], 2);
        expect(evidence['canonicalIdAfterRestart'], evidence['canonicalId']);
        await demo.close();
        demo = await DemoS1.open(directory.path);
        // Do not put either secret in a matcher failure message.
        expect(demo.passphrase == originalPassphrase, isTrue);
        final reused = await demo.verifyRoundTrip();
        expect(reused['canonicalId'], evidence['canonicalId']);
        expect(reused['messagesAfterRestart'], 2);
        expect(reused.toString().contains(originalPassphrase), isFalse);
      } finally {
        await demo?.close();
        // Explicitly created and owned by this test; no user data directory.
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('refuses an unrelated nonempty data directory', () async {
    final directory = await Directory.systemTemp.createTemp('jingyu-s1-guard-');
    try {
      await File('${directory.path}/unrelated.txt').writeAsString('keep');
      await expectLater(DemoS1.open(directory.path), throwsStateError);
      expect(
        await File('${directory.path}/unrelated.txt').readAsString(),
        'keep',
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
