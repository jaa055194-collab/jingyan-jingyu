import 'package:client_flutter/features/world/live2d_store_directory.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(live2dStoreChannelName);
  const storeRoot = '/data/user/0/com.jingyu.client_flutter/no_backup/live2d';

  void answer(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('uses the Live2D-owned channel and method', () {
    expect(live2dStoreChannelName, 'jingyu/live2d_store');
    expect(live2dStoreDirectoryMethod, 'getLive2DStoreDirectory');
  });

  test('returns the absolute path the platform answers', () async {
    final calls = <MethodCall>[];
    answer((call) async {
      calls.add(call);
      return storeRoot;
    });

    expect(await getLive2DStoreDirectory(), storeRoot);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'getLive2DStoreDirectory');
    expect(calls.single.arguments, isNull);
  });

  const badAnswers = <String, Object?>{
    'no value': null,
    'an empty string': '',
    'a relative path': 'no_backup/live2d',
    'a number': 42,
    'a path with a NUL character': '/data/live2d\u0000x',
  };
  for (final entry in badAnswers.entries) {
    test('rejects ${entry.key} as bad_directory', () async {
      answer((call) async => entry.value);

      await expectLater(
        getLive2DStoreDirectory(),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'bad_directory'),
        ),
      );
    });
  }

  test('passes a platform error through', () async {
    answer(
      (call) async => throw PlatformException(
        code: 'store_unavailable',
        message: 'noBackupFilesDir/live2d could not be created',
      ),
    );

    await expectLater(
      getLive2DStoreDirectory(),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'store_unavailable'),
      ),
    );
  });

  test('throws MissingPluginException when no platform side answers',
      () async {
    await expectLater(
      getLive2DStoreDirectory(),
      throwsA(isA<MissingPluginException>()),
    );
  });
}
