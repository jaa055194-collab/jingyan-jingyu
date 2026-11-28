import 'dart:async';

import 'package:client_flutter/features/world/android_live2d_renderer_host.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';

import 'live2d_native_fake.dart';

Matcher _hostError(String code) =>
    isA<Live2DHostException>().having((error) => error.code, 'code', code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A fresh view id per test: a message sent to a channel without a handler
  // stays buffered and would reach the next test's host.
  var nextViewId = 100;
  late FakeLive2DView native;
  late AndroidLive2DRendererHost host;
  late List<Object?> received;
  late StreamSubscription<Map<String, Object?>> subscription;

  setUp(() {
    final viewId = nextViewId++;
    native = FakeLive2DView(viewId);
    host = AndroidLive2DRendererHost(viewId);
    received = <Object?>[];
    subscription = host.events.listen(received.add, onError: received.add);
  });

  tearDown(() async {
    await subscription.cancel();
    host.dispose();
    native.detach();
  });

  // Lets broadcast events and queued posts arrive.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('queues commands until the page boots, then posts them in order',
      () async {
    await host.send(const {'cmd': 'load', 'modelId': 'm'});
    await host.send(const {'cmd': 'setParam', 'name': 'ParamAngleX'});
    expect(host.isBooted, isFalse);
    expect(native.posted, isEmpty);

    await native.boot();
    await settle();
    expect(host.isBooted, isTrue);
    expect(native.postedCommands, ['load', 'setParam']);
    expect(received, isEmpty, reason: 'the boot event is not forwarded');

    await host.send(const {'cmd': 'dispose'});
    expect(native.postedCommands, ['load', 'setParam', 'dispose']);
  });

  test('forwards decoded page messages as events', () async {
    await native.boot();
    await native.ready(modelId: 'm', profileRev: 3);
    await native.viewerError('WebGL context lost', code: 'webgl_context_lost');
    await settle();
    expect(received, [
      {'event': 'ready', 'modelId': 'm', 'profileRev': 3},
      {
        'event': 'error',
        'code': 'webgl_context_lost',
        'message': 'WebGL context lost',
      },
    ]);
  });

  test('reports page messages that are not JSON objects as host errors',
      () async {
    await native.pageText('not json');
    await native.pageText('[1, 2]');
    await settle();
    expect(received, [_hostError('bad_message'), _hostError('bad_message')]);
    expect(host.isBooted, isTrue);
  });

  test('turns page errors into host errors', () async {
    await native.pageError('net::ERR_FILE_NOT_FOUND');
    await settle();
    expect(received, [_hostError('page_error')]);
    expect(host.isGone, isFalse);
  });

  test('a lost renderer is a host error; later sends report an error event',
      () async {
    await host.send(const {'cmd': 'load', 'modelId': 'm'});
    await native.renderProcessGone(didCrash: false);
    await native.boot();
    await settle();
    expect(host.isGone, isTrue);
    expect(received, [_hostError('render_process_gone')]);

    received.clear();
    await host.send(const {'cmd': 'load', 'modelId': 'm'});
    await host.send(const {'cmd': 'dispose'});
    await settle();
    expect(native.posted, isEmpty, reason: 'queued commands are dropped');
    expect(received, [
      {
        'event': 'error',
        'code': 'renderer_gone',
        'message': 'the Live2D renderer is gone',
      },
    ]);
  });

  test('a post that finds the renderer gone reports an error event', () async {
    await native.boot();
    native.gone = true;
    await host.send(const {'cmd': 'load', 'modelId': 'm'});
    await settle();
    expect(host.isGone, isTrue);
    expect(received, [containsPair('code', 'renderer_gone')]);
  });

  test('requeues a command when the page reloaded before taking it', () async {
    await native.boot();
    native.pageReady = false;
    await host.send(const {'cmd': 'load', 'modelId': 'm'});
    expect(host.isBooted, isFalse);
    expect(native.posted, isEmpty);

    await native.boot();
    await settle();
    expect(native.postedCommands, ['load']);
  });

  test('serve returns the base URL for the stage directory', () async {
    const directory = '/data/cache/live2d-preview/live2d-preview-1';
    expect(await host.serve(directory), native.baseUrl);
    expect(native.calls.single.method, 'serve');
    expect(native.calls.single.arguments, {'directory': directory});

    native.serveError = PlatformException(code: 'bad_directory');
    await expectLater(
      host.serve('/data/elsewhere'),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'bad_directory'),
      ),
    );
  });

  test('dispose ends the events and makes later sends no-ops', () async {
    final done = expectLater(host.events, emitsDone);
    host.dispose();
    await done;
    await host.send(const {'cmd': 'load', 'modelId': 'm'});
    expect(native.calls, isEmpty);
  });

  test('drives a preview controller to ready, then fails it once', () async {
    final controller = Live2DPreviewController(host: host);
    addTearDown(controller.close);
    final states = <Live2DPreviewState>[];
    controller.states.listen(states.add);
    final model3Url = '${native.baseUrl}model.model3.json';
    final load = controller.start(
      modelId: 'm',
      model3Url: model3Url,
      textureUrls: const <String>[],
      profileRev: 1,
    );
    expect(controller.state, Live2DPreviewState.loading);

    await native.boot();
    await settle();
    expect(native.posted.single, containsPair('model3', model3Url));

    await native.ready(modelId: 'm', profileRev: 1);
    await load;
    expect(controller.state, Live2DPreviewState.ready);

    await native.renderProcessGone();
    await native.pageError('late');
    await settle();
    expect(controller.state, Live2DPreviewState.failed);
    expect(controller.failure?.cause, _hostError('render_process_gone'));
    expect(states, [
      Live2DPreviewState.loading,
      Live2DPreviewState.ready,
      Live2DPreviewState.failed,
    ]);
  });
}
