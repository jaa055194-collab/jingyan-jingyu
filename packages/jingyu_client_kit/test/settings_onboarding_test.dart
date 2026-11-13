import 'dart:convert';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:test/test.dart';
import 'shell_controller_test.dart' show MemoryPersistence;

class NativeAuth implements NativeLockAuth {
  bool enrolled = false;
  @override
  Future<bool> enrollPin(String pin) async {
    enrolled = pin == '123456';
    return enrolled;
  }

  @override
  Future<bool> verifyPin(String pin) async => enrolled && pin == '123456';
  @override
  Future<bool> authenticateBiometric() async => false;
  @override
  Future<void> removePin() async {
    enrolled = false;
  }
}

class Host implements OnboardingHost {
  final calls = <String>[];
  bool fail = false;
  @override
  Future<Result<OnboardingRegistration>> register(
    Uri host,
    String invitation,
  ) async {
    calls.add('register:$invitation');
    return fail
        ? err(FailureCode.unavailable, 'offline')
        : const Ok(OnboardingRegistration(userId: 'u', isHostMachine: false));
  }

  @override
  Future<Result<String>> createCharacter(String name, String avatar) async {
    calls.add('character:$avatar');
    return const Ok('char');
  }

  @override
  Future<Result<void>> saveRoom(String characterId, RoomLayout layout) async {
    calls.add('room:$characterId');
    return const Ok(null);
  }
}

class Generator implements RoomGenerator {
  @override
  String get id => 'test.room';
  @override
  List<String> get presets => ['sea'];
  @override
  Future<RoomLayout> generate(RoomBrief brief, PluginContext context) async =>
      RoomLayout(style: brief.style, rooms: ['bedroom']);
}

class Context extends PluginContext {
  @override
  String get pluginId => 'test.room';
  @override
  bool has(PluginCapability capability) => false;
  @override
  Map<String, String> get storage => throw StateError('denied');
  @override
  Future<void> sendText(String a, String b) => throw StateError('denied');
}

void main() {
  test(
    'PIN remains in native auth; restart locks and failed auth stays locked',
    () async {
      final store = MemoryPersistence();
      final auth = NativeAuth();
      final lock = AppLockController(persistence: store, auth: auth);
      await lock.initialize();
      expect(await lock.enable('123456'), isTrue);
      await lock.setHideNotificationBody(true);
      lock.lock();
      expect(await lock.unlockWithPin('wrong'), isFalse);
      expect(lock.isLocked, isTrue);
      expect(await lock.unlockWithBiometrics(), isFalse);
      expect(lock.notificationBody('secret'), '新消息');
      expect(jsonEncode(store.data), isNot(contains('123456')));
      final reboot = AppLockController(persistence: store, auth: auth);
      await reboot.initialize();
      expect(reboot.isLocked, isTrue);
      expect(await reboot.unlockWithPin('123456'), isTrue);
      expect(reboot.notificationBody('secret'), 'secret');
      expect(await reboot.disable('wrong'), isFalse);
      expect(reboot.enabled, isTrue);
      expect(await reboot.disable('123456'), isTrue);
      expect(auth.enrolled, isFalse);
    },
  );
  test(
    'onboarding registers then creates selected avatar and generator room, persists completion',
    () async {
      final store = MemoryPersistence();
      final host = Host();
      final onboarding = OnboardingController(persistence: store, host: host);
      await onboarding.initialize();
      final result = await onboarding.complete(
        hostAddress: 'http://localhost:8080',
        invitationCode: 'invite',
        characterName: '鲸',
        avatarId: 'vrm-1',
        brief: const RoomBrief(style: 'sea', palette: 'blue', mood: 'calm'),
        generator: Generator(),
        context: Context(),
      );
      expect(result.isOk, isTrue);
      expect(host.calls, ['register:invite', 'character:vrm-1', 'room:char']);
      expect(onboarding.completed, isTrue);
      final reboot = OnboardingController(persistence: store, host: host);
      await reboot.initialize();
      expect(reboot.completed, isTrue);
      expect(reboot.characterId, 'char');
      expect(jsonEncode(store.data), isNot(contains('invite')));
    },
  );
  test(
    'invalid host and failed registration never create a character',
    () async {
      final store = MemoryPersistence();
      final host = Host()..fail = true;
      final onboarding = OnboardingController(persistence: store, host: host);
      await onboarding.initialize();
      Future<Result<void>> run(String address) => onboarding.complete(
        hostAddress: address,
        invitationCode: 'i',
        characterName: 'n',
        avatarId: 'a',
        brief: const RoomBrief(style: 'sea', palette: 'blue', mood: 'calm'),
        generator: Generator(),
        context: Context(),
      );
      expect(
        (await run('file:///x')).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(
        (await run('https://host.test')).failureOrNull?.code,
        FailureCode.unavailable,
      );
      expect(host.calls, ['register:i']);
      expect(onboarding.completed, isFalse);
    },
  );
}
