import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/own_ai_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

void main() {
  late HttpServer server;
  late HostConnection connection;
  late OwnAiApi api;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture',
    );
    api = OwnAiApi(connection);
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });
  test('owned list projects canonical metadata and create sends only explicit name', () async {
    final requests = <Object?>[];
    server.listen((r) async {
      final text = await utf8.decoder.bind(r).join();
      requests.add((
        r.method,
        r.uri.path,
        r.headers[HttpHeaders.authorizationHeader]?.single,
        text.isEmpty ? null : jsonDecode(text),
      ));
      r.response.write(
        r.method == 'GET'
            ? '[{"accountId":"ai","displayName":"Nora","disabled":true,"ignore":"private"}]'
            : '{"accountId":"created"}',
      );
      await r.response.close();
    });
    final rows = await api.list();
    expect(rows.single.accountId, 'ai');
    expect(rows.single.displayName, 'Nora');
    expect(rows.single.disabled, isTrue);
    expect(await api.create(' New AI '), 'created');
    expect(requests, hasLength(2));
    final get = requests.first as (String, String, String?, Object?);
    final post = requests.last as (String, String, String?, Object?);
    expect(
      (get.$1, get.$2, get.$3),
      ('GET', Routes.ownAiAccounts, 'Bearer fixture'),
    );
    expect(get.$4, isNull);
    expect(
      (post.$1, post.$2, post.$3),
      ('POST', Routes.ownAiAccounts, 'Bearer fixture'),
    );
    expect(post.$4, {'displayName': 'New AI'});
  });
  test(
    'invalid list metadata and invalid canonical create responses fail',
    () async {
      final payloads = <Object?>[
        [
          {'accountId': 'bad/id', 'displayName': 'N', 'disabled': false},
        ],
        [
          {'accountId': 'ai', 'displayName': 'N'},
        ],
        [
          {'accountId': 'ai', 'displayName': '', 'disabled': false},
        ],
        {'accounts': []},
        {'accountId': 'bad/id'},
      ];
      var i = 0;
      server.listen((r) async {
        await r.drain<void>();
        r.response.write(jsonEncode(payloads[i++]));
        await r.response.close();
      });
      for (var j = 0; j < 4; j++) {
        await expectLater(api.list(), throwsFormatException);
      }
      await expectLater(api.create('N'), throwsFormatException);
    },
  );
  test(
    'malformed upstream identifiers and JSON never leak response material',
    () async {
      final payloads = [
        '[{"accountId":"private-upstream/id","displayName":"N","disabled":false}]',
        'private-raw-json',
      ];
      var next = 0;
      server.listen((r) async {
        await r.drain<void>();
        r.response.write(payloads[next++]);
        await r.response.close();
      });
      for (var i = 0; i < 2; i++) {
        try {
          await api.list();
          fail('must reject');
        } catch (error) {
          expect(error.toString(), isNot(contains('private-')));
        }
      }
    },
  );

  test('invalid names never POST and exact100 accepted', () async {
    var requests = 0;
    server.listen((r) async {
      requests++;
      await r.drain<void>();
      r.response.write('{"accountId":"created"}');
      await r.response.close();
    });
    for (final name in ['', ' ', 'x' * 101]) {
      await expectLater(api.create(name), throwsFormatException);
    }
    expect(requests, 0);
    expect(await api.create('x' * 100), 'created');
    expect(requests, 1);
  });

  test(
    'remove sends one exact empty DELETE and accepts only exact removed true',
    () async {
      final requests = <(String, String, String?, String?)>[];
      server.listen((r) async {
        final text = await utf8.decoder.bind(r).join();
        requests.add((
          r.method,
          r.uri.toString(),
          r.headers[HttpHeaders.authorizationHeader]?.single,
          text.isEmpty ? null : text,
        ));
        r.response.write('{"removed":true}');
        await r.response.close();
      });
      await api.remove('ai-1');
      expect(requests, [
        ('DELETE', '/api/v1/accounts/me/ai/ai-1', 'Bearer fixture', null),
      ]);
    },
  );

  test(
    'remove treats malformed or uncertain responses as failures without retry',
    () async {
      final payloads = <(int, String)>[
        (200, '{"removed":true,"extra":1}'),
        (200, '{"removed":"true"}'),
        (200, '{"removed":false}'),
        (201, '{"removed":true}'),
        (500, '{"removed":true}'),
        (401, '{"error":"unauthenticated"}'),
        (200, 'not-json'),
      ];
      var next = 0;
      var requests = 0;
      var renewals = 0;
      final oneShot = HostConnection(
        Uri.parse('http://127.0.0.1:${server.port}'),
        'fixture',
        onUnauthorized: () async {
          renewals++;
          return true;
        },
      );
      addTearDown(oneShot.close);
      server.listen((r) async {
        requests++;
        await r.drain<void>();
        final payload = payloads[next++];
        r.response.statusCode = payload.$1;
        r.response.write(payload.$2);
        await r.response.close();
      });
      final removing = OwnAiApi(oneShot);
      for (var i = 0; i < payloads.length; i++) {
        await expectLater(removing.remove('ai-1'), throwsA(anything));
      }
      expect(requests, payloads.length);
      expect(renewals, 0);
      for (final id in ['', 'bad/id', '删除']) {
        await expectLater(removing.remove(id), throwsFormatException);
      }
      expect(requests, payloads.length);
    },
  );
}
