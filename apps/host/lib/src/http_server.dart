/// dart:io 适配层：HttpRequest ↔ HostRequest/HostResponse。
library;

import 'dart:convert';
import 'dart:io';

import 'package:jingyu_host_kit/jingyu_host_kit.dart';

/// 请求体上限（JSON 接口）。附件走分片上传，不走这里（FR-62）。
const int maxJsonBodyBytes = 1 << 20;

/// 把 [pipeline] 挂到 [server] 上。
Future<void> serve(HttpServer server, Pipeline pipeline) async {
  await for (final request in server) {
    // 不 await：并发处理请求。
    _handle(request, pipeline);
  }
}

Future<void> _handle(HttpRequest request, Pipeline pipeline) async {
  final response = request.response;
  try {
    Object? body;
    if (request.method != 'GET' && request.method != 'HEAD') {
      final bytes = <int>[];
      await for (final chunk in request) {
        bytes.addAll(chunk);
        if (bytes.length > maxJsonBodyBytes) {
          await _write(response, const HostResponse(413, json: {'error': 'invalid_argument'}));
          return;
        }
      }
      if (bytes.isNotEmpty) {
        try {
          body = jsonDecode(utf8.decode(bytes));
        } on FormatException {
          await _write(response, const HostResponse(400, json: {'error': 'invalid_argument'}));
          return;
        }
      }
    }
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(','));
    final result = await pipeline.handle(HostRequest(
      method: request.method,
      path: request.uri.path,
      query: request.uri.queryParameters,
      headers: headers,
      body: body,
      remoteAddress: request.connectionInfo?.remoteAddress.address,
    ));
    await _write(response, result);
  } catch (_) {
    await _write(response, const HostResponse(500, json: {'error': 'internal'}));
  }
}

Future<void> _write(HttpResponse response, HostResponse result) async {
  response.statusCode = result.status;
  response.headers.contentType = ContentType.json;
  result.headers.forEach(response.headers.set);
  response.write(result.encodeBody());
  await response.close();
}
