import 'dart:io';

import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/creative/creative_activity_writer.dart';
import 'package:jingyu_host/src/creative/creative_adapters.dart';
import 'package:jingyu_host/src/creative/reports/reports_service.dart';
import 'package:jingyu_host/src/creative/radio/radio_service.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'default host registers creative services but does not schedule generation',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'jingyu-creative-default-',
      );
      final host = await buildHost(config: HostConfig(dataDir: dir.path));
      try {
        expect(
          host.registry.moduleNames,
          containsAll([
            'creative_authorization',
            'creative_reports',
            'creative_radio',
          ]),
        );
        final services = host.registry.services;
        final authorization = services.get<CreativeAuthorizationPolicy>();
        expect(
          await authorization.scopesFor(
            ownerAccountId: 'owner1',
            aiProfileId: 'profile1',
          ),
          isEmpty,
        );
        expect(
          await authorization.radioEnabledFor(
            ownerAccountId: 'owner1',
            aiProfileId: 'profile1',
          ),
          isFalse,
        );
        expect(services.maybeGet<CreativeActivityWriter>(), isNotNull);
        expect(services.maybeGet<ReportsService>(), isNotNull);
        expect(services.maybeGet<RadioService>(), isNotNull);
        final report = await services.get<ReportsService>().generateAnnual(
          ownerAccountId: 'owner1',
          aiId: 'profile1',
          year: 2026,
          authorizedScopes: const {},
        );
        expect(report.isErr, isTrue);
        final radio = await services.get<RadioService>().generateFor(
          ownerAccountId: 'owner1',
          aiId: 'profile1',
          referenceInstant: DateTime.utc(2026, 11, 16),
          profileVoiceId: 'voice1',
        );
        expect(radio.isErr, isTrue);
        expect(Directory('${dir.path}/creative-radio').existsSync(), isFalse);

        final database = services.get<Database>();
        expect(await database.query('SELECT * FROM creative_reports'), isEmpty);
        expect(
          await database.query('SELECT * FROM creative_radio_episodes'),
          isEmpty,
        );

        final anonymous = await host.pipeline.handle(
          HostRequest(method: 'GET', path: Routes.creativeReports),
        );
        expect(anonymous.status, 401);
      } finally {
        await host.shutdown();
        await dir.delete(recursive: true);
      }
    },
  );
}
