import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'device_service.dart';

class DbAuthenticator {
  DbAuthenticator(this.devices);
  final DefaultDeviceService devices;
  Future<Principal?> call(HostRequest request) async {
    final header = request.headers['authorization'];
    if (header == null || !header.startsWith('Bearer ')) return null;
    return devices.authenticate(header.substring(7).trim());
  }
}
