import 'package:jingyu_core/jingyu_core.dart';
import 'persistence.dart';
import 'plugin.dart';

class OnboardingRegistration {
  const OnboardingRegistration({
    required this.userId,
    required this.isHostMachine,
  });
  final String userId;
  final bool isHostMachine;
}

/// Host transport owns credentials and authenticated calls. No tokens are
/// returned to plugins or written into this controller's ordinary preferences.
abstract class OnboardingHost {
  Future<Result<OnboardingRegistration>> register(
    Uri host,
    String invitationCode,
  );
  Future<Result<String>> createCharacter(String name, String avatarId);
  Future<Result<void>> saveRoom(String characterId, RoomLayout layout);
}

class OnboardingController {
  OnboardingController({required this.persistence, required this.host});
  final ClientPersistence persistence;
  final OnboardingHost host;
  final _serial = SerialOperations();
  bool _initialized = false;
  bool _completed = false;
  String? _characterId;
  String? _userId;
  String? _hostAddress;
  bool _isHostMachine = false;
  bool get completed => _completed;
  String? get characterId => _characterId;
  String? get userId => _userId;
  String? get hostAddress => _hostAddress;
  bool get isHostMachine => _isHostMachine;
  Future<void> initialize() => _serial.run(() async {
    if (_initialized) return;
    final data = (await persistence.read())?['onboarding'] as Map?;
    _completed = data?['completed'] == true;
    _characterId = data?['characterId'] as String?;
    _userId = data?['userId'] as String?;
    _hostAddress = data?['hostAddress'] as String?;
    _isHostMachine = data?['isHostMachine'] == true;
    _initialized = true;
  });
  Future<Result<void>> complete({
    required String hostAddress,
    required String invitationCode,
    required String characterName,
    required String avatarId,
    required RoomBrief brief,
    required RoomGenerator generator,
    required PluginContext context,
  }) => _serial.run(() async {
    if (!_initialized) throw StateError('Call initialize first');
    if (_completed) return const Ok(null);
    final uri = Uri.tryParse(hostAddress.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        invitationCode.trim().isEmpty ||
        characterName.trim().isEmpty ||
        avatarId.trim().isEmpty) {
      return err(FailureCode.invalidArgument, 'Invalid onboarding input');
    }
    // Checkpoint each successful stage so room-generation retries do not create
    // additional accounts or characters. Host adapters retain auth securely.
    if (_hostAddress != null && _hostAddress != uri.toString()) {
      return err(FailureCode.conflict, 'Onboarding host already selected');
    }
    if (_userId == null) {
      final registered = await host.register(uri, invitationCode);
      if (registered.isErr) return Err(registered.failureOrNull!);
      _userId = registered.value.userId;
      _isHostMachine = registered.value.isHostMachine;
      _hostAddress = uri.toString();
      await _persist();
    }
    if (_characterId == null) {
      final character = await host.createCharacter(characterName, avatarId);
      if (character.isErr) return Err(character.failureOrNull!);
      _characterId = character.value;
      await _persist();
    }
    final layout = await generator.generate(brief, context);
    final saved = await host.saveRoom(_characterId!, layout);
    if (saved.isErr) return saved;
    await writeClientSection(
      persistence,
      'onboarding',
      _snapshot(completed: true),
    );
    _completed = true;
    return const Ok(null);
  });
  Map<String, Object?> _snapshot({bool? completed}) => {
    'completed': completed ?? _completed,
    'characterId': _characterId,
    'userId': _userId,
    'hostAddress': _hostAddress,
    'isHostMachine': _isHostMachine,
  };
  Future<void> _persist() =>
      writeClientSection(persistence, 'onboarding', _snapshot());
}
