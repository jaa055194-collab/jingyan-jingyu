import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

void main() {
  test(
    'authentication and route matching retain the trusted peer address',
    () async {
      final router = Router()
        ..get(
          '/devices/{id}',
          (request) async => HostResponse.ok({
            'peer': request.remoteAddress,
            'id': request.pathParams['id'],
          }),
        );
      final pipeline = Pipeline(
        router: router,
        authenticate: (_) async =>
            const Principal(accountId: 'account', deviceId: 'device'),
      );
      final response = await pipeline.handle(
        HostRequest(
          method: 'GET',
          path: '/devices/42',
          remoteAddress: '192.0.2.4',
          headers: {'x-forwarded-for': '203.0.113.8'},
        ),
      );
      expect(response.status, 200);
      expect(response.json, {'peer': '192.0.2.4', 'id': '42'});
    },
  );
}
