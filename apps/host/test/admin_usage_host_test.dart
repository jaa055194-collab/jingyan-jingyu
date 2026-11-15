import 'dart:io';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

void main() {
  test(
    'default host administrator usage route requires authentication',
    () async {
      final dir = await Directory.systemTemp.createTemp('admin-usage-host-');
      final host = await buildHost(config: HostConfig(dataDir: dir.path));
      try {
        expect(
          (await host.pipeline.handle(
            HostRequest(method: 'GET', path: '/api/v1/admin/usage'),
          )).status,
          401,
        );
      } finally {
        await host.shutdown();
        await dir.delete(recursive: true);
      }
    },
  );
}
