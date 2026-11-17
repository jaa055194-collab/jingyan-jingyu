import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/lifecycle_api.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _quota() => {
  'usedBytes': 5,
  'quotaBytes': 100,
  'diskFreeBytes': 10,
  'diskTotalBytes': 20,
};
Map<String, Object?> _survey() => {
  'objectCounts': {'conversations': 1},
  'momentsToAnonymize': 0,
  'totalObjects': 1,
};
Map<String, Object?> _bundle() => {
  'ownerAccountId': 'owner',
  'files': {'manifest.json': '{}'},
  'manifest': {
    'formatVersion': 1,
    'counts': {
      'conversations': 1,
      'messages': 0,
      'memories': 1,
      'attachments': 0,
      'persona': 1,
    },
  },
  'sha256sums': 'abc  manifest.json',
};

void main() {
  late HttpServer server;
  late StreamSubscription<HttpRequest> sub;
  late HostConnection connection;
  late LifecycleApi api;
  late List<(String, String, String?)> requests;
  late Object? importBody;
  late int exportStatus;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'token',
    );
    api = LifecycleApi(connection);
    requests = [];
    importBody = null;
    exportStatus = 200;
    sub = server.listen((request) async {
      requests.add((
        request.method,
        request.uri.path,
        request.headers.value(HttpHeaders.authorizationHeader),
      ));
      final body = await utf8.decoder.bind(request).join();
      if (request.uri.path == '/api/v1/lifecycle/quota') {
        request.response.write(jsonEncode(_quota()));
      } else if (request.uri.path == '/api/v1/lifecycle/departure/survey') {
        request.response.write(jsonEncode(_survey()));
      } else if (request.uri.path == '/api/v1/lifecycle/export') {
        request.response.statusCode = exportStatus;
        if (exportStatus == 200) {
          request.response.write(jsonEncode(_bundle()));
        } else {
          request.response.write(
            '{"error":"unavailable","detail":"secret-xyz"}',
          );
        }
      } else if (request.uri.path == '/api/v1/lifecycle/import') {
        importBody = jsonDecode(body);
        final mode = (importBody as Map)['mode'];
        request.response.write(
          jsonEncode({
            'mode': mode,
            'checksumVerified': true,
            'imported': {
              'persona': 1,
              'conversations': 1,
              'messages': 0,
              'memories': 1,
              'attachments': 0,
            },
            'conflicts': [],
          }),
        );
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    await sub.cancel();
    await connection.close();
    await server.close(force: true);
  });

  test('read/export/import use exact merged host method and path', () async {
    expect((await api.readQuota()).quotaBytes, 100);
    expect((await api.readDepartureSurvey()).totalObjects, 1);

    final bundle = await api.exportBundle();
    expect(bundle.ownerAccountId, 'owner');
    expect(bundle.fileCount, 1);
    expect(bundle.hasChecksums, isTrue);
    expect(bundle.counts['conversations'], 1);

    final report = await api.importBundle(
      bundle,
      mode: LifecycleImportMode.personaAndConversations,
    );
    expect(report.checksumVerified, isTrue);
    expect(report.importedConversations, 1);
    expect((importBody as Map)['mode'], 'personaAndConversations');
    expect((importBody as Map)['files'], {'manifest.json': '{}'});

    expect(requests.map((r) => (r.$1, r.$2)), [
      ('GET', '/api/v1/lifecycle/quota'),
      ('GET', '/api/v1/lifecycle/departure/survey'),
      ('POST', '/api/v1/lifecycle/export'),
      ('POST', '/api/v1/lifecycle/import'),
    ]);
    expect(requests.every((r) => r.$3 == 'Bearer token'), isTrue);
  });

  test(
    'export 503 throws a safe unavailable failure without leaking details',
    () async {
      exportStatus = 503;
      await expectLater(
        api.exportBundle(),
        throwsA(
          predicate(
            (e) =>
                e is HostRequestException &&
                !e.toString().contains('secret-xyz'),
          ),
        ),
      );
      expect(
        requests.where((r) => r.$2 == '/api/v1/lifecycle/export').length,
        1,
      );
    },
  );
}
