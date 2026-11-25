import 'dart:convert';

import '../../net/lifecycle_api.dart';
import '../../platform/native_platform.dart';

/// A file the user explicitly chose to write. Only display metadata is kept.
class SavedBackupFile {
  const SavedBackupFile({required this.name, required this.bytes});
  final String name;
  final int bytes;
}

/// Explicit local save boundary for an already-fetched export bundle.
///
/// Implementations must return null when the user cancels and must never
/// expose an absolute path or the written content to the caller.
abstract interface class BackupFileStore {
  Future<SavedBackupFile?> save(LifecycleExportBundle bundle);
}

/// Local bridge implementation; the platform shows its own destination dialog.
class NativeBackupFileStore implements BackupFileStore {
  NativeBackupFileStore(this.platform);
  final NativePlatform platform;

  @override
  Future<SavedBackupFile?> save(LifecycleExportBundle bundle) async {
    final content = bundle.exportFileContents();
    final bytes = utf8.encode(content);
    final saved = await platform.saveBackupFile(
      suggestedName: suggestedBackupFileName(bundle),
      bytes: bytes,
    );
    return saved == null
        ? null
        : SavedBackupFile(name: saved.name, bytes: saved.bytes);
  }
}

/// Deterministic, path-free display name for the local save dialog.
String suggestedBackupFileName(LifecycleExportBundle bundle) {
  final generated = bundle.manifest['generatedAt'];
  final day = generated is String && generated.length >= 10
      ? generated.substring(0, 10)
      : 'export';
  return 'jingyu-backup-$day.json';
}
