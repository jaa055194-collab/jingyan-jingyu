/// The [Live2DFileStore] fallback for platforms without `dart:io`.
library;

import 'live2d_store.dart';

/// Always fails: there is no file system for a [Live2DFileStore] here.
Future<Live2DFileStore> openLive2DFileStore(String root) async =>
    throw UnsupportedError('Live2DFileStore needs dart:io');
