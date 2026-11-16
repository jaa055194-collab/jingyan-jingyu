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
}
