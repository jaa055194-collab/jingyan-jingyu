import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

/// Produces one redacted render input from the real host at this revision.
/// Run from apps/host with an output path in the evidence directory.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError(
      'Usage: dart run test/current_device_capture.dart <output.json>',
    );
  }
  final output = File(args.single);
  final scratch = await Directory('.dart_tool').create(recursive: true);
  final parent = await scratch.resolveSymbolicLinks();
  final data = await scratch.createTemp('current-device-capture-');
  final dataPath = await data.resolveSymbolicLinks();
  try {
    final clock = FakeClock(DateTime.utc(2026, 11, 20, 2, 3, 4));
    final host = await buildHost(
      config: HostConfig(dataDir: data.absolute.path),
      clock: clock,
      onError: (error, _) =>
          stderr.writeln('Fixture host error: ${error.runtimeType}'),
    );
    try {
      final rows = await _capture(host, clock);
      await output.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(rows)}\n',
      );
      stdout.writeln('Wrote two normalized device rows from the loopback host');
    } finally {
      if ((await host.shutdown()).isNotEmpty) {
        throw StateError('Fixture host shutdown failed');
      }
    }
  } finally {
    // Remove only the disposable database directory allocated by this run.
    if (await data.parent.resolveSymbolicLinks() != parent ||
        await data.resolveSymbolicLinks() != dataPath ||
        !dataPath.startsWith(
          '$parent${Platform.pathSeparator}current-device-capture-',
        )) {
      throw StateError('Unexpected fixture database path');
    }
    await data.delete(recursive: true);
  }
}

Future<List<Map<String, Object?>>> _capture(Host host, FakeClock clock) async {
  final random = Random.secure();
  final password = base64Url.encode(
    List.generate(32, (_) => random.nextInt(256)),
  );
  final admin = (await host.auth.bootstrapAdmin(
    displayName: 'Synthetic fixture owner',
    password: password,
  )).value;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final serving = serve(server, host.pipeline);
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..findProxy = (_) => 'DIRECT';
  try {
    Future<Object?> request(
      String method,
      String path, {
      Map<String, Object?>? body,
      String? bearer,
    }) async {
      final req = await client.openUrl(
        method,
        Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: path),
      );
      req.followRedirects = false;
      if (bearer != null) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final reply = await req.close().timeout(const Duration(minutes: 2));
      if (reply.statusCode != 200) {
        throw StateError('Fixture $method $path returned ${reply.statusCode}');
      }
      return jsonDecode(
        await utf8.decoder
            .bind(reply)
            .join()
            .timeout(const Duration(seconds: 10)),
      );
    }

    Future<({String id, String bearer})> login(String name) async {
      final result = await request(
        'POST',
        Routes.authLogin,
        body: {
          'accountId': admin.value,
          'password': password,
          'deviceName': name,
        },
      );
      if (result case {
        'deviceId': final String id,
        'accessToken': final String bearer,
      }) {
        return (id: id, bearer: bearer);
      }
      throw StateError('Unexpected fixture login response');
    }

    const localName = '合成笔记本';
    const peerName = '合成手机';
    final local = await login(localName);
    final peer = await login(peerName);
    final result = await request(
      'GET',
      Routes.authDevices,
      bearer: local.bearer,
    );
    if (result is! List || result.length != 2 || local.id == peer.id) {
      throw StateError('Expected two distinct device rows');
    }
    final byId = <String, Map<String, Object?>>{};
    for (final raw in result) {
      if (raw is! Map<String, Object?>) throw StateError('Invalid device row');
      final now = clock.now().toIso8601String();
      final id = raw['id'];
      final isLocal = id == local.id;
      final hasMarker = raw.containsKey('current');
      if ((!isLocal && id != peer.id) ||
          raw['deviceName'] != (isLocal ? localName : peerName) ||
          raw['lastUsedAt'] != now ||
          raw.length != (hasMarker ? 4 : 3) ||
          (hasMarker && (!isLocal || raw['current'] != true))) {
        throw StateError('Unexpected device metadata');
      }
      final normalizedId = isLocal ? 'fixture-local' : 'fixture-peer';
      if (byId.containsKey(normalizedId)) {
        throw StateError('Duplicate device row');
      }
      // Do not synthesize a marker or persist the login response.
      byId[normalizedId] = {...raw, 'id': normalizedId};
    }
    return [byId['fixture-local']!, byId['fixture-peer']!];
  } finally {
    client.close(force: true);
    await server.close(force: true);
    await serving;
  }
}
