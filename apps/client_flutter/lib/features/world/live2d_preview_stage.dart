import 'dart:io';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';

/// A completed, device-local staging session for a static Live2D preview.
final class Live2DPreviewStage {
  Live2DPreviewStage._(this.directory, this.model3File);

  final Directory directory;
  final File model3File;
  Future<void>? _disposal;

  /// Removes only this session's directory. Failed I/O can be retried.
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    try {
      await _removeDirectory(directory);
    } catch (_) {
      _disposal = null;
      rethrow;
    }
  }
}

/// Both staging and rollback failed. The caller can retry deleting only the
/// owned temporary directory; no partially written stage is exposed.
final class Live2DPreviewCleanupFailure implements Exception {
  Live2DPreviewCleanupFailure._(this.writeError, this.cleanupError, this._stage);

  final Object writeError;
  final Object cleanupError;
  final Live2DPreviewStage _stage;

  Future<void> retryCleanup() => _stage.dispose();
}

/// Stages [bundle] under an existing, trusted [parent] in the app's private
/// temporary storage. The caller must keep it out of shared and backed-up storage.
///
/// The stage is returned only after all writes succeed. A caller that cancels
/// or abandons the preview should await this future and dispose of its result.
Future<Live2DPreviewStage> stageLive2DPreview(
  Directory parent,
  Live2DPreviewBundle bundle,
) async {
  const model3Name = 'model.model3.json';
  final files = bundle.files;
  final names = [
    model3Name,
    'model.moc3',
    for (var i = 0; i < files.length - 2; i++) 'texture-$i.png',
  ];
  if (bundle.model3Name != model3Name ||
      files.length < 3 ||
      !names.every(files.containsKey)) {
    throw const FormatException('Unexpected Live2D preview filenames');
  }

  final directory = await parent.absolute.createTemp('live2d-preview-');
  final uri = directory.uri;
  final stage = Live2DPreviewStage._(
    directory,
    File.fromUri(uri.resolve(model3Name)),
  );
  try {
    for (final name in names) {
      await File.fromUri(uri.resolve(name)).writeAsBytes(files[name]!);
    }
    return stage;
  } catch (writeError, stack) {
    try {
      await stage.dispose();
    } catch (cleanupError) {
      Error.throwWithStackTrace(
        Live2DPreviewCleanupFailure._(writeError, cleanupError, stage),
        stack,
      );
    }
    rethrow;
  }
}

Future<void> _removeDirectory(Directory directory) async {
  try {
    await directory.delete(recursive: true);
  } on PathNotFoundException {
    // Missing files inside a partially removed tree are not a success.
    if (await directory.exists()) rethrow;
  }
}
