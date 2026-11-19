import 'package:flutter/services.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';

class NativePlatform implements NativeLockAuth {
  static const channel = MethodChannel('jingyu/platform');
  Future<T?> invoke<T>(String method, [Map<String, Object?>? arguments]) =>
      channel.invokeMethod<T>(method, arguments);
  @override
  Future<bool> enrollPin(String pin) async {
    await invoke<void>('configurePin', {'pin': pin});
    return true;
  }

  @override
  Future<bool> verifyPin(String pin) async =>
      await invoke<bool>('unlockPin', {'pin': pin}) ?? false;
  @override
  Future<bool> authenticateBiometric() async =>
      await invoke<bool>('unlockBiometric') ?? false;
  @override
  Future<void> removePin() async {
    await invoke<void>('removePin');
  }

  /// Opens the platform picker. Returns a local readable path or null when the
  /// user cancels; the caller owns validation and lifetime of the selected file.
  Future<PickedAttachment?> pickAttachment(String kind) async {
    if (kind != 'image' && kind != 'file') {
      throw const FormatException('不支持的附件类型');
    }
    final raw = await invoke<Object?>('pickAttachment', {'kind': kind});
    if (raw == null) return null;
    if (raw is! Map) throw const FormatException('所选文件不可用');
    final path = raw['path'];
    final name = raw['name'];
    if (path is! String ||
        path.trim().isEmpty ||
        name is! String ||
        name.trim().isEmpty) {
      throw const FormatException('所选文件不可用');
    }
    final mime = raw['mime'];
    return PickedAttachment(
      path: path,
      name: name,
      mime: mime is String ? mime : null,
      temporary: raw['temporary'] == true,
    );
  }
}

class PickedAttachment {
  const PickedAttachment({
    required this.path,
    required this.name,
    this.mime,
    this.temporary = false,
  });
  final String path;
  final String name;
  final String? mime;

  /// True for a picker-owned cache copy that the app must delete after use.
  final bool temporary;
}
