import 'package:jingyu_street3d_android/jingyu_street3d_android.dart';
import 'package:material_ui/material_ui.dart';

import 'street3d_screen.dart';

/// The Android view of the 3D street page: the WebView of
/// jingyu_street3d_android, which loads jingyu_street3d_web from the app's
/// assets.
class Street3DAndroidSurface implements Street3DSurface {
  Street3DAndroidSurface(this._view);

  /// A [Street3DSurfaceBuilder] for Android.
  static Widget build(
    BuildContext context,
    ValueChanged<Street3DSurface> onCreated,
  ) => Street3DAndroidView(
    onCreated: (view) => onCreated(Street3DAndroidSurface(view)),
  );

  final Street3DAndroidController _view;

  @override
  Stream<String> get messages => _view.messages;

  @override
  late final Stream<Street3DSurfaceFailure> failures = _view.failures.map(
    (failure) => Street3DSurfaceFailure(switch (failure.kind) {
      Street3DAndroidFailureKind.loadFailed =>
        Street3DSurfaceFailureKind.loadFailed,
      Street3DAndroidFailureKind.crashed => Street3DSurfaceFailureKind.crashed,
      Street3DAndroidFailureKind.unsupported =>
        Street3DSurfaceFailureKind.unsupported,
    }, failure.detail),
  );

  @override
  Future<void> send(String json) => _view.send(json);

  @override
  Future<void> pause() => _view.pause();

  @override
  Future<void> resume() => _view.resume();

  @override
  void dispose() => _view.dispose();
}
