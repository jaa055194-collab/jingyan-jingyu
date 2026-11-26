import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';

import '../../platform/native_platform.dart';
import 'live2d_import_panel.dart';
import 'live2d_preview_stage.dart';

const _maxArchiveBytes = 160 * 1024 * 1024;
// A panel can unmount while the picker or preparation worker is still active.
// Keep the in-flight guard independent of the widget's lifetime.
bool _importInProgress = false;

/// Prepares a selected file locally, without activating an avatar or contacting
/// the host. The native picker owns the Android transfer until it returns.
Future<Live2DImportSession?> openLocalLive2DZip({
  NativePlatform? platform,
}) async {
  if (_importInProgress) {
    throw const Live2DImportFailure('已有模型包正在处理，请稍后重试。');
  }
  _importInProgress = true;
  final native = platform ?? NativePlatform();
  Live2DPreviewStage? stage;
  File? temporaryZip;
  try {
    final cache = await native.invoke<String>('getLive2DPreviewDirectory');
    if (cache == null || cache.isEmpty) {
      throw const Live2DImportFailure('本机预览目录不可用。');
    }
    final parent = Directory(cache).absolute;
    final selected = await native.invoke<Map<Object?, Object?>>(
      'pickLive2DZip',
    );
    if (selected == null) return null;
    final path = selected['path'];
    final temporary = selected['temporary'];
    if (path is! String || path.isEmpty || temporary is! bool) {
      throw const Live2DImportFailure('无法读取所选模型包。');
    }
    final file = File(path).absolute;
    if (temporary) {
      // Only remove the exact private file created by the Android picker.
      final name = file.uri.pathSegments.last;
      final expected = File.fromUri(parent.uri.resolve(name));
      if (file.path != expected.path ||
          !name.startsWith('live2d-') ||
          !name.endsWith('.zip')) {
        throw const Live2DImportFailure('无法读取所选模型包。');
      }
      temporaryZip = file;
    }
    stage = await _prepareAndStage(file.path, parent.path);
    if (temporaryZip != null) {
      await temporaryZip.delete();
      temporaryZip = null;
    }
    return Live2DImportSession(
      stage.dispose,
      previewDirectory: stage.directory.path,
    );
  } on Live2DPreviewCleanupFailure catch (failure) {
    await _tryCleanup(failure.retryCleanup);
    throw const Live2DImportFailure('无法暂存模型包。');
  } on PlatformException catch (error) {
    if (error.code == 'live2d_zip_too_large') {
      throw const Live2DImportFailure('模型包不能超过 160 MiB。');
    }
    throw const Live2DImportFailure('无法打开系统文件选择器。');
  } on FormatException {
    throw const Live2DImportFailure('模型包格式有误，或超出本机预览限制。');
  } finally {
    final input = temporaryZip;
    try {
      if (input != null) {
        await _tryCleanup(() async => input.delete());
        if (stage != null) await _tryCleanup(stage.dispose);
      }
    } finally {
      _importInProgress = false;
    }
  }
}

Future<Live2DPreviewStage> _prepareAndStage(String path, String directory) =>
    Isolate.run(() async {
      final file = File(path);
      if (await file.length() > _maxArchiveBytes) {
        throw const Live2DImportFailure('模型包不能超过 160 MiB。');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in file.openRead()) {
        if (chunk.length > _maxArchiveBytes - bytes.length) {
          throw const Live2DImportFailure('模型包不能超过 160 MiB。');
        }
        bytes.add(chunk);
      }
      final bundle = prepareLive2DPreview(bytes.takeBytes());
      return stageLive2DPreview(Directory(directory), bundle);
    });

Future<void> _tryCleanup(Future<void> Function() cleanup) async {
  try {
    await cleanup();
  } catch (_) {
    try {
      await cleanup();
    } catch (_) {}
  }
}
