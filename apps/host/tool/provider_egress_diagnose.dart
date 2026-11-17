// Read-only diagnostic: where does the trusted outbound chain fail?
// No credentials are read or used; this only probes DNS / TLS / egress.
import 'dart:convert';
import 'dart:io';

import 'package:jingyu_host/src/security/guarded_http.dart';
import 'package:jingyu_host/src/security/url_guard.dart';

Future<void> _dns(String host) async {
  try {
    final addrs = await InternetAddress.lookup(host);
    final blocked = addrs.where(UrlGuard.isBlocked).length;
    print('DNS host=$host count=${addrs.length} blocked=$blocked');
  } catch (e) {
    print('DNS host=$host error=${e.runtimeType}');
  }
}

Future<void> _guardedGet(String url) async {
  final t = GuardedHttpTransport(timeout: const Duration(seconds: 10));
  final r = await t.request('GET', Uri.parse(url));
  if (r.isOk) {
    print('GUARDED url=$url status=${r.value.statusCode}');
  } else {
    print('GUARDED url=$url error=${r.failureOrNull!.code.name}');
  }
}

Future<void> _rawGet(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    print('RAW url=$url status=${res.statusCode}');
    await res.drain<void>();
  } catch (e) {
    print('RAW url=$url error=${e.runtimeType}');
  } finally {
    client.close(force: true);
  }
}

Future<void> main() async {
  const provider = 'api.hcnsec.cn';
  await _dns(provider);
  await _dns('example.com');

  final guard = UrlGuard();
  final checked = await guard.check('https://$provider/v1');
  print(
    'URLGUARD provider=${checked.isOk ? 'ok' : checked.failureOrNull!.code.name}',
  );

  await _guardedGet('https://$provider/v1');
  await _guardedGet('https://example.com/');
  await _rawGet('https://$provider/v1');
  await _rawGet('https://example.com/');

  // Chat endpoint path/status probe without any real credential.
  await _guardedPost('https://$provider/v1/chat/completions');
  await _guardedPost('https://$provider/chat/completions');
  await _authProbe();
}

/// Optional authenticated probe: only runs when a chat provider is supplied via
/// the same env vars as the live test. Prints ONLY the HTTP status or failure
/// code — never the key, headers or response body.
Future<void> _authProbe() async {
  final env = Platform.environment;
  final base = env['JINGYU_LIVE_BASE_URL']?.trim() ?? '';
  final key = env['JINGYU_LIVE_API_KEY'] ?? '';
  if (base.isEmpty || key.trim().isEmpty) {
    print(
      'AUTH_PROBE skipped (set JINGYU_LIVE_BASE_URL + JINGYU_LIVE_API_KEY)',
    );
    return;
  }
  final model = (env['JINGYU_LIVE_MODEL']?.trim().isNotEmpty ?? false)
      ? env['JINGYU_LIVE_MODEL']!.trim()
      : 'auto';
  final endpoint = Uri.parse(
    '${base.replaceFirst(RegExp(r'/+$'), '')}/chat/completions',
  );
  final t = GuardedHttpTransport(timeout: const Duration(seconds: 20));
  final r = await t.request(
    'POST',
    endpoint,
    headers: {
      'content-type': 'application/json',
      'authorization': 'Bearer ${key.trim()}',
    },
    body: utf8.encode(
      jsonEncode({
        'model': model,
        'messages': [
          {'role': 'user', 'content': 'Reply with the word OK only.'},
        ],
        'stream': false,
        'max_tokens': 8,
      }),
    ),
  );
  print(
    r.isOk
        ? 'AUTH_PROBE status=${r.value.statusCode}'
        : 'AUTH_PROBE error=${r.failureOrNull!.code.name}',
  );
}

Future<void> _guardedPost(String url) async {
  final t = GuardedHttpTransport(timeout: const Duration(seconds: 10));
  final r = await t.request(
    'POST',
    Uri.parse(url),
    headers: const {'content-type': 'application/json'},
    body: utf8.encode(
      '{"model":"auto","messages":[{"role":"user","content":"ping"}],"stream":false,"max_tokens":1}',
    ),
  );
  if (r.isOk) {
    print('GUARDED_POST url=$url status=${r.value.statusCode}');
  } else {
    print('GUARDED_POST url=$url error=${r.failureOrNull!.code.name}');
  }
}
