import 'persistence.dart';

/// The native adapter owns salted PIN verification in protected storage and
/// platform biometric prompts. Raw PINs must never be logged or persisted here.
abstract class NativeLockAuth {
  Future<bool> enrollPin(String pin);
  Future<bool> verifyPin(String pin);
  Future<bool> authenticateBiometric();
  Future<void> removePin();
}

class AppLockController {
  AppLockController({required this.persistence, required this.auth});
  final ClientPersistence persistence;
  final NativeLockAuth auth;
  final _serial = SerialOperations();
  bool _initialized = false;
  bool _enabled = false;
  bool _locked = false;
  bool _hide = false;
  int _lockGeneration = 0;
  bool get enabled => _enabled;
  bool get isLocked => _locked;
  bool get hideNotificationBody => _hide;
  Future<void> initialize() => _serial.run(() async {
    if (_initialized) return;
    final data = (await persistence.read())?['appLock'] as Map?;
    _enabled = data?['enabled'] == true;
    _hide = data?['hideNotificationBody'] == true;
    _locked = _enabled;
    _initialized = true;
  });
  void _require() {
    if (!_initialized) throw StateError('Call initialize first');
  }

  Future<bool> enable(String pin) => _serial.run(() async {
    _require();
    if (_enabled) throw StateError('Already enabled');
    if (!RegExp(r'^\d{4,12}$').hasMatch(pin)) return false;
    if (!await auth.enrollPin(pin)) return false;
    await _persist(enabled: true, hide: _hide);
    _enabled = true;
    _locked = false;
    return true;
  });
  Future<bool> disable(String pin) => _serial.run(() async {
    _require();
    if (!_enabled) return true;
    if (!await auth.verifyPin(pin)) return false;
    // Persist first: a failed settings write cannot silently disable the lock.
    await _persist(enabled: false, hide: _hide);
    _enabled = false;
    _locked = false;
    await auth.removePin();
    return true;
  });
  void lock() {
    _require();
    _lockGeneration++;
    if (_enabled) _locked = true;
  }

  Future<bool> unlockWithPin(String pin) => _unlock(() => auth.verifyPin(pin));
  Future<bool> unlockWithBiometrics() => _unlock(auth.authenticateBiometric);
  Future<bool> _unlock(Future<bool> Function() verify) => _serial.run(() async {
    _require();
    if (!_enabled) return true;
    final generation = _lockGeneration;
    final success = await verify();
    if (success && generation == _lockGeneration) _locked = false;
    return success && !_locked;
  });
  Future<void> setHideNotificationBody(bool value) => _serial.run(() async {
    _require();
    await _persist(enabled: _enabled, hide: value);
    _hide = value;
  });
  String notificationBody(String body) => _locked && _hide ? '新消息' : body;
  Future<void> _persist({required bool enabled, required bool hide}) =>
      writeClientSection(persistence, 'appLock', {
        'enabled': enabled,
        'hideNotificationBody': hide,
      });
}
