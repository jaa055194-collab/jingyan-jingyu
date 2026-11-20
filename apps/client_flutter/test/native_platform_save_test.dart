import 'dart:convert';

import 'package:client_flutter/platform/native_platform.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jingyu/platform');
  final bytes = utf8.encode('{"ownerAccountId":"owner"}');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('save sends bytes and returns only display metadata', () async {
    var calls = 0;
    String? seenName;
    List<int>? seenBytes;
    int? seenMax;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'saveBackupFile');
          calls++;
          final args = (call.arguments as Map).cast<String, Object?>();
          seenName = args['suggestedName'] as String?;
          seenBytes = args['bytes'] as List<int>?;
          seenMax = args['maxBytes'] as int?;
          return {'name': 'jingyu-backup.json', 'bytes': bytes.length};
        });

    final saved = await NativePlatform().saveBackupFile(
      suggestedName: 'jingyu-backup.json',
      bytes: bytes,
    );

    expect(saved?.name, 'jingyu-backup.json');
    expect(saved?.bytes, bytes.length);
    expect(calls, 1);
    expect(seenName, 'jingyu-backup.json');
    expect(seenBytes, bytes);
    expect(seenMax, NativePlatform.maxBackupFileBytes);
  });

  test('save cancellation returns null and does not retry', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          return null;
        });

    expect(
      await NativePlatform().saveBackupFile(
        suggestedName: 'jingyu-backup.json',
        bytes: bytes,
      ),
      isNull,
    );
    expect(calls, 1);
  });

  test('malformed or lying platform result is a safe format failure', () async {
    final platform = NativePlatform();
    for (final result in <Object?>[
      {'path': r'C:\private\export.json', 'name': '..\\evil', 'bytes': 1},
      {'name': 'export.json', 'bytes': bytes.length + 1},
      {'name': 'good.json'},
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => result);
      await expectLater(
        platform.saveBackupFile(
          suggestedName: 'jingyu-backup.json',
          bytes: bytes,
        ),
        throwsFormatException,
      );
    }
  });

  test('oversize, empty and path-like inputs fail before invoking', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          return {'name': 'jingyu-backup.json', 'bytes': bytes.length};
        });
    final platform = NativePlatform();

    await expectLater(
      platform.saveBackupFile(
        suggestedName: 'jingyu-backup.json',
        bytes: List<int>.filled(NativePlatform.maxBackupFileBytes + 1, 1),
      ),
      throwsArgumentError,
    );
    await expectLater(
      platform.saveBackupFile(
        suggestedName: 'jingyu-backup.json',
        bytes: const [],
      ),
      throwsArgumentError,
    );
    await expectLater(
      platform.saveBackupFile(
        suggestedName: r'..\private\export.json',
        bytes: bytes,
      ),
      throwsArgumentError,
    );
    expect(calls, 0);
  });
}
