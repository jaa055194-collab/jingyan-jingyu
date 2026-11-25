// Private subprocess for the opt-in Flutter dual-chat test. Never serve an
// existing deployment: only a test-owned directory and IPv4 loopback are used.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';

Future<void> main(List<String> args) async {
  final [directory, portText, mode] = args;
  final data = Directory(directory).absolute;
  final port = int.parse(portText);
  final fresh = port == 0;
  if (!const {'normal', 'drop-ack', 'change-retry-id'}.contains(mode)) {
    throw ArgumentError('Unknown test fixture mode');
  }
  final commands = StreamIterator<String>(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  try {
    if (!await commands.moveNext()) throw StateError('Missing fixture setup');
    final password = (jsonDecode(commands.current) as Map)['password'];
    final marker = File('${data.path}/dual-chat-fixture');
    if (fresh) {
      if (password is! String ||
          await FileSystemEntity.type(data.path) !=
              FileSystemEntityType.notFound) {
        throw StateError(
          'First start requires a fresh directory and synthetic password',
        );
      }
      await data.create();
      await marker.create();
    } else if (password != null ||
        !await marker.exists() ||
        !await File('${data.path}/host.sqlite').exists()) {
      throw StateError('Restart requires the same test fixture data');
    }
    final host = await buildHost(config: HostConfig(dataDir: data.path));
    try {
      final owner = fresh
          ? (await host.auth.bootstrapAdmin(
              displayName: 'Synthetic sender',
              password: password as String,
            )).value.value
          : null;
      final listener = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      final adapter = _TestListener(host.pipeline, mode);
      final serving = listener.asyncMap(adapter.handle).drain<void>();
      serving.ignore();
      try {
        stdout.writeln(
          jsonEncode({'event': 'ready', 'port': listener.port, 'owner': owner}),
        );
        await stdout.flush();
        if (await commands.moveNext() && commands.current != 'stop') {
          throw StateError('Unexpected fixture command');
        }
      } finally {
        await listener.close(force: true);
        await serving;
      }
    } finally {
      if ((await host.shutdown()).isNotEmpty) {
        throw StateError('Default host shutdown failed');
      }
    }
  } finally {
    await commands.cancel();
  }
}

/// The usual HTTP-to-pipeline translation, with one test-only response fault.
/// Auth, membership, append, sync and SQLite all stay in the real host.
class _TestListener {
  _TestListener(this._pipeline, this._mode);
  final Pipeline _pipeline;
  final String _mode;
  bool _dropped = false;

  Future<void> handle(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      if (bytes.length + chunk.length > maxJsonBodyBytes) {
        request.response.statusCode = HttpStatus.requestEntityTooLarge;
        await request.response.close();
        return;
      }
      bytes.addAll(chunk);
    }
    var body = bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
    final headers = <String, String>{};
    request.headers.forEach(
      (name, values) => headers[name.toLowerCase()] = values.join(','),
    );
    final path = request.uri.path;
    final isSubmission =
        request.method == 'POST' &&
        RegExp(r'^/api/v1/conversations/[^/]+/messages$').hasMatch(path);
    final sentId = isSubmission && body is Map ? body['clientMsgId'] : null;
    if (isSubmission && _mode == 'change-retry-id' && body is Map) {
      // Deliberate negative control: simulate a retry losing its original ID.
      body = {...body, 'clientMsgId': 'negative-control-new-id'};
    }
    final result = await _pipeline.handle(
      HostRequest(
        method: request.method,
        path: path,
        query: request.uri.queryParameters,
        headers: headers,
        body: body,
        remoteAddress: request.connectionInfo?.remoteAddress.address,
      ),
    );
    final payload = result.json;
    final message = payload is Map ? payload['message'] : null;
    final duplicate = payload is Map ? payload['duplicate'] : null;
    final loseResponse =
        isSubmission &&
        _mode == 'drop-ack' &&
        !_dropped &&
        result.status == 200 &&
        duplicate == false;
    if (isSubmission) {
      // Synthetic IDs and status only: never request bodies or credentials.
      stdout.writeln(
        jsonEncode({
          'event': 'message',
          'path': path,
          'clientMsgId': sentId,
          'messageId': message is Map ? message['messageId'] : null,
          'seq': message is Map ? message['seq'] : null,
          'duplicate': duplicate,
          'status': result.status,
          'lost': loseResponse,
        }),
      );
    }
    final response = request.response;
    if (loseResponse) {
      // The pipeline returned success only after SQLite committed. Drop the
      // socket before writing any response headers, not before handling POST.
      _dropped = true;
      (await response.detachSocket(writeHeaders: false)).destroy();
      return;
    }
    response.statusCode = result.status;
    response.headers.contentType = ContentType.json;
    result.headers.forEach(response.headers.set);
    response.write(result.encodeBody());
    await response.close();
  }
}
