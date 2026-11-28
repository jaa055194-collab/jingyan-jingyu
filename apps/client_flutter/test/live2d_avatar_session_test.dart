// Unit tests for Live2DAvatarSession: it reads the device store's active
// model, serves the model directory and drives a Live2DPreviewController, and
// reports hidden / loading / ready / failed honestly.
import 'dart:async';

import 'package:client_flutter/features/world/live2d_avatar_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';

import 'live2d_fake_store.dart';

/// A controllable renderer whose `serve` result and preview events the test
/// drives directly. It stands in for AndroidLive2DAvatarRenderer so the
/// session runs without platform channels.
final class _FakeRenderer implements Live2DAvatarRenderer {
  _FakeRenderer({this.serveError});

  final _FakeHost host = _FakeHost();
  late final Live2DPreviewController _controller = Live2DPreviewController(
    host: host,
  );
  Object? serveError;
  final List<String> served = <String>[];
  bool disposed = false;

  @override
  Live2DPreviewController get controller => _controller;

  @override
  bool get isGone => false;

  @override
  Future<String> serve(String directory) async {
    served.add(directory);
    final Object? error = serveError;
    if (error != null) throw error;
    return 'https://appassets.androidplatform.net/live2d/model/t1/';
  }

  @override
  void dispose() {
    disposed = true;
    unawaited(_controller.close());
  }
}

final class _FakeHost implements Live2DRendererHost {
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  final List<Map<String, Object?>> commands = <Map<String, Object?>>[];

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> send(Map<String, Object?> command) async {
    commands.add(command);
  }

  void emit(Map<String, Object?> event) => _events.add(event);

  Future<void> close() => _events.close();
}

/// A store whose model lookup works but whose directory is invalid, to model a
/// broken on-device model directory.
final class _BadDirectoryStore implements Live2DFileStore {
  _BadDirectoryStore(this._inner);

  final Live2DFileStore _inner;

  @override
  List<Live2DStoredModel> get models => _inner.models;

  @override
  Live2DStoredModel? model(String modelId) => _inner.model(modelId);

  @override
  Live2DProfile? profile(String modelId) => _inner.profile(modelId);

  @override
  String? get activeModelId => _inner.activeModelId;

  @override
  String modelDirectory(String modelId) =>
      throw const FormatException('bad model directory');

  @override
  Future<Live2DStoredModel> importModel({
    required String modelId,
    required String displayName,
    required String model3,
    required Map<String, List<int>> files,
    bool replace = false,
    DateTime? importedAt,
  }) => _inner.importModel(
    modelId: modelId,
    displayName: displayName,
    model3: model3,
    files: files,
    replace: replace,
    importedAt: importedAt,
  );

  @override
  Future<void> saveProfile(Live2DProfile profile) => _inner.saveProfile(profile);

  @override
  Future<void> setActive(String modelId, Live2DModelInfo info) =>
      _inner.setActive(modelId, info);

  @override
  Future<void> clearActive() => _inner.clearActive();

  @override
  Future<bool> delete(String modelId) => _inner.delete(modelId);

  @override
  String get root => _inner.root;
}

/// Lets stream events and async session work land.
Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late FakeLive2DFileStore store;

  setUp(() {
    store = FakeLive2DFileStore();
  });

  test('no active model hides the card', () async {
    final session = Live2DAvatarSession(openStore: () async => store);
    addTearDown(session.dispose);

    await session.refresh();

    expect(session.status, Live2DAvatarStatus.hidden);
    expect(session.directory, isNull);
  });

  test('an active model resolves the directory and becomes ready', () async {
    store.addModel('m1', displayName: '示例模型', active: true);
    final session = Live2DAvatarSession(openStore: () async => store);
    addTearDown(session.dispose);

    await session.refresh();
    expect(session.status, Live2DAvatarStatus.loading);
    expect(session.displayName, '示例模型');
    expect(session.directory, store.modelDirectory('m1'));
    expect(session.model3File, 'model.model3.json');

    final renderer = _FakeRenderer();
    session.attach(renderer);
    await _flush();
    expect(renderer.served, [store.modelDirectory('m1')]);
    expect(renderer.host.commands.single['cmd'], 'load');

    renderer.host.emit(<String, Object?>{
      'event': 'ready',
      'modelId': 'm1',
      'profileRev': 1,
    });
    await _flush();
    expect(session.status, Live2DAvatarStatus.ready);
  });

  test('an invalid model directory fails honestly', () async {
    store.addModel('m1', active: true);
    final session = Live2DAvatarSession(
      openStore: () async => _BadDirectoryStore(store),
    );
    addTearDown(session.dispose);

    await session.refresh();

    expect(session.status, Live2DAvatarStatus.failed);
    expect(session.errorText, isNotNull);
    expect(session.directory, isNull);
  });

  test('a viewer error becomes a failed state with text', () async {
    store.addModel('m1', active: true);
    final session = Live2DAvatarSession(openStore: () async => store);
    addTearDown(session.dispose);
    await session.refresh();

    final renderer = _FakeRenderer();
    session.attach(renderer);
    await _flush();
    renderer.host.emit(<String, Object?>{
      'event': 'error',
      'code': 'render_failed',
      'message': '模型无法显示',
    });
    await _flush();

    expect(session.status, Live2DAvatarStatus.failed);
    expect(session.errorText, isNotNull);
    await session.retry();
    expect(session.status, Live2DAvatarStatus.loading);
  });

  test('a serve failure becomes a failed state with text', () async {
    store.addModel('m1', active: true);
    final session = Live2DAvatarSession(openStore: () async => store);
    addTearDown(session.dispose);
    await session.refresh();

    final renderer = _FakeRenderer(
      serveError: PlatformException(code: 'bad_directory'),
    );
    session.attach(renderer);
    await _flush();

    expect(session.status, Live2DAvatarStatus.failed);
    expect(session.errorText, isNotNull);
  });

  test('deleting the active model hides the card on the next read', () async {
    store.addModel('m1', active: true);
    final session = Live2DAvatarSession(openStore: () async => store);
    addTearDown(session.dispose);
    await session.refresh();
    expect(session.status, Live2DAvatarStatus.loading);

    await store.delete('m1');
    await session.refresh();

    expect(session.status, Live2DAvatarStatus.hidden);
    expect(session.directory, isNull);
  });

  test('an unsupported platform stays hidden without touching the store',
      () async {
    var opened = 0;
    final session = Live2DAvatarSession(
      openStore: () async {
        opened++;
        return store;
      },
      supported: false,
    );
    addTearDown(session.dispose);

    await session.refresh();

    expect(session.status, Live2DAvatarStatus.hidden);
    expect(opened, 0);
  });
}
