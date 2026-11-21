// Release verification only. Not the production worker. The test driver
// selects a loopback fixture before launch; no request can select a destination.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final http = HttpClient()..findProxy = (_) => 'DIRECT';
  try {
    final fixtureDir = File.fromUri(Platform.script).parent;
    final port = int.parse(
      File('${fixtureDir.path}/fixture.port').readAsStringSync(),
    );
    final input = jsonDecode(await utf8.decoder.bind(stdin).join()) as Map;
    final bytes = base64Decode(input['body'] as String);
    final payload = jsonDecode(utf8.decode(bytes)) as Map;
    final messages = payload['messages'] as List;
    if (args.length != 1 ||
        args.single != '--decode-gzip' ||
        input['method'] != 'POST' ||
        input['url'] != 'https://192.0.2.1/v1/chat/completions' ||
        payload['model'] != 'auto' ||
        payload['stream'] != false ||
        (messages.last as Map)['role'] != 'user' ||
        (messages.last as Map)['content'] != '为什么这样？请解释原因。') {
      throw const FormatException('Unexpected fixture request');
    }
    final authorization = (input['headers'] as Map)['authorization'] as String;
    if (!authorization.startsWith('Bearer fixture-')) {
      throw const FormatException('Only synthetic credentials are accepted');
    }
    final request = await http.post('127.0.0.1', port, '/v1/chat/completions');
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set('authorization', authorization);
    request.add(bytes);
    final response = await request.close();
    final body = await response.expand((chunk) => chunk).take(65536).toList();
    stdout.writeln(
      jsonEncode({
        'ok': true,
        'statusCode': response.statusCode,
        'headers': {
          'content-type': ['application/json'],
        },
        'body': base64Encode(body),
      }),
    );
  } catch (_) {
    stdout.writeln('{"ok":false,"code":"unavailable"}');
  } finally {
    http.close(force: true);
  }
}
