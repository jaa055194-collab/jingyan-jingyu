import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_street3d_android/jingyu_street3d_android.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  /// Answers the calls Dart makes on one view's channel and records them.
  List<String> mockView(
    int id, [
    Future<Object?> Function(MethodCall call)? answer,
  ]) {
    final calls = <String>[];
    final channel = MethodChannel('jingyu/street3d_view_$id');
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(
        call.arguments == null
            ? call.method
            : '${call.method} ${call.arguments}',
      );
      return answer == null ? null : answer(call);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    return calls;
  }

  /// A call the view (Kotlin) makes to Dart.
  Future<void> fromView(int id, String method, [Object? arguments]) =>
      messenger.handlePlatformMessage(
        'jingyu/street3d_view_$id',
        codec.encodeMethodCall(MethodCall(method, arguments)),
        null,
      );

  test('start, send, pause and resume reach the view in order', () async {
    final calls = mockView(1);
    final controller = Street3DAndroidController(1);
    addTearDown(controller.dispose);

    await controller.start();
    await controller.start(); // Loads once only.
    await controller.send('{"v":1,"type":"layout"}');
    await controller.pause();
    await controller.resume();

    expect(calls, ['start', 'send {"v":1,"type":"layout"}', 'pause', 'resume']);
  });

  test(
    'page messages arrive in order, also those posted before listening',
    () async {
      mockView(2);
      final controller = Street3DAndroidController(2);
      addTearDown(controller.dispose);

      await fromView(2, 'message', '{"type":"hello"}');
      await fromView(2, 'message', '{"type":"ready"}');

      expect(await controller.messages.take(2).toList(), [
        '{"type":"hello"}',
        '{"type":"ready"}',
      ]);
    },
  );

  test('a refused start and the view failures are reported by kind', () async {
    mockView(3, (call) async {
      if (call.method == 'start') {
        throw PlatformException(
          code: 'unsupported',
          message: 'WebView 80 has no WebMessageListener.',
        );
      }
      return null;
    });
    final controller = Street3DAndroidController(3);
    addTearDown(controller.dispose);
    final failures = <Street3DAndroidFailure>[];
    controller.failures.listen(failures.add);

    await controller.start();
    await fromView(3, 'failure', <String, Object?>{
      'kind': 'crashed',
      'detail': 'The renderer crashed.',
    });
    await fromView(3, 'failure', <String, Object?>{
      'kind': 'loadFailed',
      'detail': 'HTTP 404',
    });
    await Future<void>.delayed(Duration.zero);

    expect(failures.map((failure) => failure.kind), [
      Street3DAndroidFailureKind.unsupported,
      Street3DAndroidFailureKind.crashed,
      Street3DAndroidFailureKind.loadFailed,
    ]);
    expect(failures.first.detail, 'WebView 80 has no WebMessageListener.');
  });

  test(
    'starting without a view behind the channel is a load failure',
    () async {
      final controller = Street3DAndroidController(4);
      addTearDown(controller.dispose);
      final failures = <Street3DAndroidFailure>[];
      controller.failures.listen(failures.add);

      await controller.start();
      await Future<void>.delayed(Duration.zero);

      expect(failures.single.kind, Street3DAndroidFailureKind.loadFailed);
    },
  );

  test('a disposed controller sends nothing', () async {
    final calls = mockView(5);
    final controller = Street3DAndroidController(5)..dispose();

    await controller.start();
    await controller.send('{}');
    await controller.pause();

    expect(calls, isEmpty);
  });

  testWidgets(
    'the view is created with the page params, then the page starts',
    (tester) async {
      final events = <String>[];
      Object? params;
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        final arguments = call.arguments;
        if (call.method == 'create' && arguments is Map) {
          events.add('create ${arguments['viewType']}');
          params = const StandardMessageCodec().decodeMessage(
            ByteData.sublistView(arguments['params'] as Uint8List),
          );
          final view = MethodChannel('jingyu/street3d_view_${arguments['id']}');
          messenger.setMockMethodCallHandler(view, (call) async {
            events.add(call.method);
            return null;
          });
          addTearDown(() => messenger.setMockMethodCallHandler(view, null));
          return 0; // The texture id.
        }
        if (call.method == 'resize' && arguments is Map) {
          return <String, Object?>{
            'width': arguments['width'],
            'height': arguments['height'],
          };
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Street3DAndroidView(onCreated: (_) => events.add('onCreated')),
        ),
      );
      await tester.pumpAndSettle();

      expect(events, ['create $street3dViewType', 'onCreated', 'start']);
      expect(params, {
        'entry': 'web/index.html',
        'assetPackage': 'jingyu_street3d_web',
        'bridgeName': 'Street3DBridge',
      });
      await tester.pumpWidget(const SizedBox());
    },
  );
}
