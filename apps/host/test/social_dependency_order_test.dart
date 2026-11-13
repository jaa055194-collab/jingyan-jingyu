import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'friendship routes mount when social is registered before accounts',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'jingyu-social-dependency-order-',
      );
      final config = HostConfig(dataDir: directory.path);
      const clock = SystemClock();
      final modules = defaultModules(config, clock);
      final social = modules.singleWhere((module) => module.name == 'social');
      modules.remove(social);
      modules.insert(
        modules.indexWhere((module) => module.name == 'accounts'),
        social,
      );
      final host = await buildHost(
        config: config,
        clock: clock,
        modules: modules,
      );
      addTearDown(() async {
        await host.shutdown();
        await directory.delete(recursive: true);
      });

      final response = await host.pipeline.handle(
        HostRequest(
          method: 'GET',
          path: Routes.friendState.replaceFirst('{accountId}', 'target'),
        ),
      );
      expect(
        response.status,
        401,
        reason:
            'Friendship route must exist and require authentication after boot',
      );
      expect(
        (await host.pipeline.handle(
          HostRequest(method: 'GET', path: Routes.directConversations),
        )).status,
        401,
      );
      for (final route in [
        Routes.groupOwner,
        Routes.groupLeave,
        Routes.groupMember,
        Routes.groupAiWithdraw,
        Routes.groupAiSettings,
        Routes.groupAiInterval,
        Routes.groupAiMute,
      ]) {
        expect(
          host.registry.router.describe().any((entry) => entry.contains(route)),
          isTrue,
        );
      }
      expect(
        host.registry.router.describe().any(
          (route) => route.contains(Routes.friendState),
        ),
        isTrue,
      );
    },
  );
}
