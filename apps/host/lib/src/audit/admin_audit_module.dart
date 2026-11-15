import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'admin_audit_reader.dart';

class AdminAuditModule extends HostModule {
  AdminAuditModule({required this.reader});
  final AdminAuditReader reader;
  static final _cursor = RegExp(r'^(0|[1-9][0-9]*)$');
  static final _positive = RegExp(r'^[1-9][0-9]*$');

  @override
  String get name => 'admin_audit';
  @override
  List<String> get dependsOn => const ['storage', 'accounts'];

  @override
  void mount(Router router) {
    router.get(Routes.adminAudit, (request) async {
      final after = request.query['afterId'] ?? '0';
      final count = request.query['limit'] ?? '50';
      final afterId = after.length <= 19 && _cursor.hasMatch(after)
          ? int.tryParse(after)
          : null;
      final limit = count.length <= 3 && _positive.hasMatch(count)
          ? int.tryParse(count)
          : null;
      if (request.query.keys.any((key) => key != 'afterId' && key != 'limit') ||
          afterId == null ||
          afterId < 0 ||
          limit == null ||
          limit < 1 ||
          limit > 100) {
        return HostResponse.failure(
          const Failure(FailureCode.invalidArgument, 'Invalid audit page'),
        );
      }
      final header = request.headers['authorization'] ?? '';
      final bearer = header.startsWith('Bearer ')
          ? header.substring(7).trim()
          : '';
      final principal = request.principal;
      if (principal == null) {
        return HostResponse.failure(
          const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
        );
      }
      return HostResponse.fromResult(
        await reader.page(
          bearer: bearer,
          accountId: principal.accountId,
          deviceId: principal.deviceId,
          afterId: afterId,
          limit: limit,
        ),
      );
    }, access: Access.admin);
  }
}
