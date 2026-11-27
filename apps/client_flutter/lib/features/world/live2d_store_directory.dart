import 'package:flutter/services.dart';

/// Method channel owned by Live2DViewPlugin.kt (Live2D-owned, not
/// `jingyu/platform`). Only Android registers it, so a call anywhere else
/// fails with [MissingPluginException].
const String live2dStoreChannelName = 'jingyu/live2d_store';

/// The method on [live2dStoreChannelName] that returns the store root.
const String live2dStoreDirectoryMethod = 'getLive2DStoreDirectory';

const MethodChannel _channel = MethodChannel(live2dStoreChannelName);

/// The absolute path of the on-device Live2D store root, Android
/// `noBackupFilesDir/live2d` (b2-plan "Persistent layout": models/,
/// models.json and profiles/ live below it). The platform side creates the
/// directory when it is missing.
///
/// Throws [PlatformException] when the platform cannot resolve or create the
/// directory, or answers with anything but an absolute path, and
/// [MissingPluginException] off Android.
Future<String> getLive2DStoreDirectory() async {
  final Object? path = await _channel.invokeMethod<Object?>(
    live2dStoreDirectoryMethod,
  );
  if (path is String && path.startsWith('/') && !path.contains('\u0000')) {
    return path;
  }
  throw PlatformException(
    code: 'bad_directory',
    message: 'getLive2DStoreDirectory did not return an absolute path',
  );
}
