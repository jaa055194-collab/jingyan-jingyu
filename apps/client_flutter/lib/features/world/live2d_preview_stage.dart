import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:jingyu_client_kit/jingyu_client_kit.dart';

/// A completed, device-local staging session for a static Live2D preview.
final class Live2DPreviewStage {
  Live2DPreviewStage._(this.directory, this.model3File, this.names);

  final Directory directory;
  final File model3File;

  /// The names this stage wrote, in [stagedLive2DPreviewNames] order.
  final List<String> names;
  Future<void>? _disposal;

  /// Reads back the files this stage wrote, and only those, keyed by name.
  Future<Map<String, List<int>>> readFiles() async => {
    for (final name in names)
      name: await File.fromUri(directory.uri.resolve(name)).readAsBytes(),
  };

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
/// Only the names [stagedLive2DPreviewNames] allows are written.
///
/// The stage is returned only after all writes succeed. A caller that cancels
/// or abandons the preview should await this future and dispose of its result.
Future<Live2DPreviewStage> stageLive2DPreview(
  Directory parent,
  Live2DPreviewBundle bundle,
) async {
  const model3Name = 'model.model3.json';
  final files = bundle.files;
  final names = bundle.model3Name == model3Name
      ? stagedLive2DPreviewNames(files.keys)
      : null;
  if (names == null) {
    throw const FormatException('Unexpected Live2D preview filenames');
  }

  final directory = await parent.absolute.createTemp('live2d-preview-');
  final uri = directory.uri;
  final stage = Live2DPreviewStage._(
    directory,
    File.fromUri(uri.resolve(model3Name)),
    List.unmodifiable(names),
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

/// The staged-name allowlist, in write order: `model.model3.json`,
/// `model.moc3`, at least one `texture-N.png`, then optionally
/// `physics.physics3.json`, `pose.pose3.json`, any
/// `expression-N.exp3.json` and `motion-N.motion3.json`, each N counting
/// from 0 without gaps, as [prepareLive2DPreview] names them. Null for any
/// other set of [names], so a stage never holds another file.
@visibleForTesting
List<String>? stagedLive2DPreviewNames(Iterable<String> names) {
  final given = names.toSet();
  int count(String prefix, String suffix) {
    var n = 0;
    while (given.contains('$prefix$n$suffix')) {
      n++;
    }
    return n;
  }

  final textures = count('texture-', '.png');
  final expressions = count('expression-', '.exp3.json');
  final motions = count('motion-', '.motion3.json');
  final staged = [
    'model.model3.json',
    'model.moc3',
    for (var i = 0; i < textures; i++) 'texture-$i.png',
    if (given.contains('physics.physics3.json')) 'physics.physics3.json',
    if (given.contains('pose.pose3.json')) 'pose.pose3.json',
    for (var i = 0; i < expressions; i++) 'expression-$i.exp3.json',
    for (var i = 0; i < motions; i++) 'motion-$i.motion3.json',
  ];
  // The staged names are distinct and all given, so the same count means no
  // other name is given.
  if (textures == 0 ||
      staged.length != given.length ||
      !staged.every(given.contains)) {
    return null;
  }
  return staged;
}

Future<void> _removeDirectory(Directory directory) async {
  try {
    await directory.delete(recursive: true);
  } on PathNotFoundException {
    // Missing files inside a partially removed tree are not a success.
    if (await directory.exists()) rethrow;
  }
}
