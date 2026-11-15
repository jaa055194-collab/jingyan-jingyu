import 'dart:io';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

void main() {
  test(
    'default host mounts group name updates behind authentication',
    () async {
      final dir = await Directory.systemTemp.createTemp('name-route-');
      final host = await buildHost(config: HostConfig(dataDir: dir.path));
      try {
        expect(
          (await host.pipeline.handle(
            HostRequest(
              method: 'PUT',
              path: '/api/v1/conversations/group/name',
              body: {'name': 'New'},
            ),
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
