import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'admin_usage_reader.dart';

class AdminUsageModule extends HostModule {
  AdminUsageModule({required this.reader});
  final AdminUsageReader reader;
  @override
  String get name => 'admin_usage';
  @override
  List<String> get dependsOn => const ['storage', 'accounts'];
  @override
  void mount(Router router) {
    router.get(Routes.adminUsage, (request) async {
      if (request.query.isNotEmpty) {
        return HostResponse.failure(
          const Failure(
            FailureCode.invalidArgument,
            'Usage is global recorded aggregate',
          ),
        );
      }
      final principal = request.principal;
      if (principal == null) {
        return HostResponse.failure(
          const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
        );
      }
      final header = request.headers['authorization'] ?? '';
      final bearer = header.startsWith('Bearer ')
          ? header.substring(7).trim()
          : '';
      return HostResponse.fromResult(
        await reader.summary(
          bearer: bearer,
          accountId: principal.accountId,
          deviceId: principal.deviceId,
        ),
      );
    }, access: Access.admin);
  }
}
