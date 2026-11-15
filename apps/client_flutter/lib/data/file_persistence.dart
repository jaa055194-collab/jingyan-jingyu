import 'dart:convert';
import 'dart:io';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';

/// Durable, serialized shell snapshots. A previous committed copy survives a
/// torn write; malformed data is never silently replaced with an empty account.
class FilePersistence implements ClientPersistence {
  FilePersistence(this.file);
  final File file;
  Future<void> _tail = Future.value();
  @override
  Future<Map<String, Object?>> read() async {
    await _tail;
    if (!await file.exists()) {
      final backup = File('${file.path}.bak');
      if (await backup.exists()) return _decode(backup);
      return {};
    }
    try {
      return await _decode(file);
    } on FormatException {
      final backup = File('${file.path}.bak');
      if (await backup.exists()) return _decode(backup);
      rethrow;
    }
  }

  Future<Map<String, Object?>> _decode(File source) async {
    final data = jsonDecode(await source.readAsString());
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Invalid client snapshot');
    }
    return data.cast<String, Object?>();
  }

  @override
  Future<void> write(Map<String, Object?> snapshot) {
    final encoded = jsonEncode(snapshot);
    final operation = _tail.then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      if (await file.exists()) await file.copy('${file.path}.bak');
      await temporary.rename(file.path);
    });
    _tail = operation.then(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }
}
