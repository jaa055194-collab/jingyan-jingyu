import 'package:jingyu_core/jingyu_core.dart';

class DeviceTokens {
  const DeviceTokens({
    required this.deviceId,
    required this.accessToken,
    required this.refreshToken,
  });
  final DeviceId deviceId;
  final String accessToken;
  final String refreshToken;
  Map<String, Object?> toJson() => {
    'deviceId': deviceId.value,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
  };
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.deviceName,
    required this.lastUsedAt,
  });
  final DeviceId id;
  final String deviceName;
  final DateTime lastUsedAt;
  Map<String, Object?> toJson() => {
    'id': id.value,
    'deviceName': deviceName,
    'lastUsedAt': lastUsedAt.toUtc().toIso8601String(),
  };
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
