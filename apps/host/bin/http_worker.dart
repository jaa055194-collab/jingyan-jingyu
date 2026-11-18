/// One request per process. stdin is data, never connection-policy configuration.
library;

import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/security/guarded_http.dart';

Future<void> main(List<String> args) async {
  var response = <String, Object?>{'ok': false, 'code': 'unavailable'};
  try {
    // Trusted launch option only; never accept this in request input.
    final decodeGzip = args.length == 1 && args.single == '--decode-gzip';
    if (args.isNotEmpty && !decodeGzip) throw const FormatException();
    const maxInput = 8 * 1024 * 1024;
    final bytes = <int>[];
    await for (final chunk in stdin) {
      if (chunk.length > maxInput - bytes.length) {
        throw const FormatException();
      }
      bytes.addAll(chunk);
    }
    final text = utf8.decode(bytes);
    if (!text.endsWith('\n') || '\n'.allMatches(text).length != 1) {
      throw const FormatException();
    }
    final input = jsonDecode(text);
    if (input is! Map<String, dynamic> ||
        input.length != 6 ||
        !input.keys.toSet().containsAll({
          'method',
          'url',
          'headers',
          'body',
          'timeout',
          'maxResponseBytes',
        }) ||
        input['method'] is! String ||
        input['url'] is! String ||
        input['headers'] is! Map<String, dynamic> ||
        (input['body'] != null && input['body'] is! String) ||
        input['timeout'] is! int ||
        (input['timeout'] as int) <= 0 ||
        input['maxResponseBytes'] is! int ||
        (input['maxResponseBytes'] as int) <= 0) {
      throw const FormatException();
    }
    final headers = <String, String>{};
    for (final entry in (input['headers'] as Map<String, dynamic>).entries) {
      if (entry.value is! String) throw const FormatException();
      headers[entry.key] = entry.value as String;
    }
    // No resolver, connector, trust store or local-address override is accepted.
    final transport = GuardedHttpTransport(
      timeout: Duration(microseconds: input['timeout'] as int),
      maxResponseBytes: input['maxResponseBytes'] as int,
      autoUncompress: decodeGzip,
    );
    final result = await transport.request(
      input['method'] as String,
      Uri.parse(input['url'] as String),
      headers: headers,
      body: input['body'] == null
          ? null
          : base64Decode(input['body'] as String),
    );
    if (result.isOk) {
      final value = result.value;
      response = {
        'ok': true,
        'statusCode': value.statusCode,
        'headers': value.headers,
        'body': base64Encode(value.body),
      };
    } else {
      response = {
        'ok': false,
        'code': result.failureOrNull!.code == FailureCode.forbidden
            ? 'forbidden'
            : 'unavailable',
      };
    }
    final encoded = utf8.encode('${jsonEncode(response)}\n');
    if (encoded.length > maxInput) throw const FormatException();
    stdout.add(encoded);
  } catch (_) {
    // Never propagate exceptions, request data or stderr to the parent protocol.
    stdout.writeln('{"ok":false,"code":"unavailable"}');
  }
  await stdout.flush();
  await stdout.close();
}
