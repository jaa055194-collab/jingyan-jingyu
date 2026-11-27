// Helpers for Live2D models kept on this device (Android only): the store
// root comes from live2d_store_directory.dart, the store itself from the kit.
import 'dart:math';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';

import 'live2d_store_directory.dart';

Future<Live2DFileStore>? _deviceStore;

/// Opens this device's model store once per app run, so that its operations
/// stay one at a time; later calls get the same store. A failed open is
/// tried again on the next call.
Future<Live2DFileStore> openDeviceLive2DStore() {
  return _deviceStore ??= () async {
    try {
      return await Live2DFileStore.open(await getLive2DStoreDirectory());
    } catch (_) {
      _deviceStore = null;
      rethrow;
    }
  }();
}

final Random _random = Random.secure();

/// A new model ID that passes [Live2DProfile.isValidModelId] and differs,
/// ignoring case, from every model in [store].
String newLive2DModelId(
  Live2DFileStore store, {
  DateTime? now,
  Random? random,
}) {
  final taken = {for (final model in store.models) model.id.toLowerCase()};
  final time = (now ?? DateTime.now())
      .toUtc()
      .millisecondsSinceEpoch
      .toRadixString(36);
  final source = random ?? _random;
  while (true) {
    final suffix = source.nextInt(0x7fffffff).toRadixString(36);
    final id = 'live2d-$time-$suffix';
    if (!taken.contains(id) && Live2DProfile.isValidModelId(id)) return id;
  }
}

/// The display name of a model kept from the picked file [fileName]: the
/// name without its extension, cut to [Live2DStoredModel.maxDisplayNameLength]
/// UTF-16 code units, or 未命名模型 when nothing is left.
String live2dDisplayName(String? fileName) {
  var name = (fileName ?? '').trim();
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot).trimRight();
  const max = Live2DStoredModel.maxDisplayNameLength;
  if (name.length > max) {
    var end = max;
    final last = name.codeUnitAt(end - 1);
    // Never keep half of a surrogate pair.
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    name = name.substring(0, end).trimRight();
  }
  return name.isEmpty ? '未命名模型' : name;
}
