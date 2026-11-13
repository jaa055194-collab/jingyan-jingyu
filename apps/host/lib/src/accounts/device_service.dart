import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'accounts_store.dart';
import 'password_hasher.dart';

class DeviceTokens {
  const DeviceTokens({
    required this.deviceId,
    required this.accessToken,
    required this.refreshToken,
  });
  final DeviceId deviceId;
  final String accessToken;
  final String refreshToken;
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.deviceName,
    required this.createdAt,
    required this.lastUsedAt,
  });
  final DeviceId id;
  final String deviceName;
  final DateTime createdAt;
  final DateTime lastUsedAt;
}

abstract class DeviceService {
  Future<Result<DeviceTokens>> register(
    AccountId account, {
    required String deviceName,
  });
  Future<Result<DeviceTokens>> refresh(String refreshToken);
  Future<List<DeviceInfo>> list(AccountId account);
  Future<Result<void>> revoke(AccountId account, DeviceId device);
}

class DefaultDeviceService implements DeviceService {
  DefaultDeviceService({required this.store, required this.clock});
  final AccountsStore store;
  final Clock clock;

  DeviceTokens _rotate(DeviceRecord device) {
    final access = randomSecret(32);
    final refresh = randomSecret(32);
    device.accessHash = secretHash(access);
    device.refreshHash = secretHash(refresh);
    device.lastUsedAt = clock.now();
    return DeviceTokens(
      deviceId: device.id,
      accessToken: access,
      refreshToken: refresh,
    );
  }

  @override
  Future<Result<DeviceTokens>> register(
    AccountId account, {
    required String deviceName,
  }) => store.serialized((s) {
    if (s.accounts[account.value]?.enabled != true) {
      return err(FailureCode.unauthenticated, 'account unavailable');
    }
    if (deviceName.trim().isEmpty) {
      return err(FailureCode.invalidArgument, 'invalid device');
    }
    final online =
        s.devices.values
            .where((d) => d.account == account && d.revokedAt == null)
            .toList()
          ..sort((a, b) => a.lastUsedAt.compareTo(b.lastUsedAt));
    while (online.length >= 2) {
      online.removeAt(0).revokedAt = clock.now();
    }
    final now = clock.now();
    final device = DeviceRecord(
      id: DeviceId.parse(s.nextId('d')),
      account: account,
      deviceName: deviceName,
      accessHash: '',
      refreshHash: '',
      createdAt: now,
      lastUsedAt: now,
    );
    final tokens = _rotate(device);
    s.devices[device.id.value] = device;
    return Ok(tokens);
  });

  @override
  Future<Result<DeviceTokens>> refresh(String refreshToken) =>
      store.serialized((s) {
        final hash = secretHash(refreshToken);
        final matches = s.devices.values.where(
          (d) =>
              d.refreshHash == hash &&
              d.revokedAt == null &&
              s.accounts[d.account.value]?.enabled == true,
        );
        if (matches.isEmpty) {
          return err(FailureCode.unauthenticated, 'invalid refresh token');
        }
        return Ok(_rotate(matches.first));
      });

  Future<Principal?> authenticate(String accessToken) => store.serialized((s) {
    final hash = secretHash(accessToken);
    final matches = s.devices.values.where(
      (d) =>
          d.accessHash == hash &&
          d.revokedAt == null &&
          s.accounts[d.account.value]?.enabled == true,
    );
    if (matches.isEmpty) return null;
    final device = matches.first;
    device.lastUsedAt = clock.now();
    final account = s.accounts[device.account.value]!;
    return Principal(
      accountId: account.id.value,
      deviceId: device.id.value,
      isAdmin: account.isAdmin,
    );
  });

  @override
  Future<List<DeviceInfo>> list(AccountId account) => store.serialized(
    (s) => s.devices.values
        .where((d) => d.account == account && d.revokedAt == null)
        .map(
          (d) => DeviceInfo(
            id: d.id,
            deviceName: d.deviceName,
            createdAt: d.createdAt,
            lastUsedAt: d.lastUsedAt,
          ),
        )
        .toList(),
  );

  @override
  Future<Result<void>> revoke(AccountId account, DeviceId device) =>
      store.serialized((s) {
        final row = s.devices[device.value];
        if (row == null || row.account != account) {
          return err(FailureCode.notFound, 'device unavailable');
        }
        row.revokedAt ??= clock.now();
        return const Ok(null);
      });
}
