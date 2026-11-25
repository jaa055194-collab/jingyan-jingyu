import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

enum AndroidPrivateModelFailure {
  invalidInput,
  closed,
  timeout,
  rejected,
  invalidResponse,
  unavailable,
}

/// A safe failure category; never includes the endpoint, credential or body.
class AndroidPrivateModelException implements Exception {
  const AndroidPrivateModelException(this.kind);

  final AndroidPrivateModelFailure kind;

  @override
  String toString() => 'AndroidPrivateModelException(${kind.name})';
}

/// One explicit, non-streaming provider request. Does not use the host client,
/// host credentials, an ambient proxy, redirects, retries, or fallback models.
class AndroidPrivateModelApi {
  AndroidPrivateModelApi({this.timeout = const Duration(seconds: 30)});

  static const _maxBytes = 1024 * 1024;
  static const _maxContentUnits = 256 * 1024;
  static const _maxTurns = 64;
  static const _invalidInput = AndroidPrivateModelException(
    AndroidPrivateModelFailure.invalidInput,
  );
  static const _invalidResponse = AndroidPrivateModelException(
    AndroidPrivateModelFailure.invalidResponse,
  );
  static const _closedError = AndroidPrivateModelException(
    AndroidPrivateModelFailure.closed,
  );
  static const _timeoutError = AndroidPrivateModelException(
    AndroidPrivateModelFailure.timeout,
  );
  static const _unavailable = AndroidPrivateModelException(
    AndroidPrivateModelFailure.unavailable,
  );

  final Duration timeout;
  final _active = <_ProviderCall>{};
  bool _closed = false;

  /// Require an exact canonical HTTPS URL, not a base URL to be resolved later.
  /// Encoded path components, dot segments and ambiguous authority syntax are
  /// deliberately not accepted. Invalid input is not attached to the exception.
  static Uri parseEndpoint(String value) {
    const invalid = FormatException('Invalid private model endpoint');
    const prefix = 'https://';
    if (value.length > 2048 ||
        !value.startsWith(prefix) ||
        value.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e) ||
        value.contains(r'\') ||
        value.contains('%') ||
        value.contains('?') ||
        value.contains('#')) {
      throw invalid;
    }
    final slash = value.indexOf('/', prefix.length);
    if (slash <= prefix.length) throw invalid;
    final authority = value.substring(prefix.length, slash);
    final rawPath = value.substring(slash);
    if (authority.contains('@') ||
        !rawPath.endsWith('/chat/completions') ||
        rawPath
            .split('/')
            .skip(1)
            .any(
              (segment) => segment.isEmpty || segment == '.' || segment == '..',
            )) {
      throw invalid;
    }
    try {
      final uri = Uri.parse(value);
      if (uri.host.isEmpty ||
          uri.port < 1 ||
          uri.port > 65535 ||
          uri.toString() != value) {
        throw invalid;
      }
      return uri;
    } on FormatException {
      throw invalid;
    }
  }

  Future<String> reply({
    required String endpoint,
    required String model,
    required String apiKey,
    required String persona,
    required String text,
    List<({String user, String assistant})> history = const [],
  }) async {
    if (_closed) throw _closedError;
    final Uri uri;
    try {
      uri = parseEndpoint(endpoint);
    } on FormatException {
      throw _invalidInput;
    }
    if (apiKey.isEmpty ||
        apiKey.length > 4096 ||
        apiKey.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e) ||
        model.length > 256 ||
        model.trim().isEmpty ||
        model.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f) ||
        endpoint.contains(apiKey) ||
        model.contains(apiKey) ||
        history.length > _maxTurns) {
      throw _invalidInput;
    }

    var remainingContentUnits = _maxContentUnits;
    void checkText(String value, {bool allowEmpty = false}) {
      remainingContentUnits -= value.length;
      if (remainingContentUnits < 0 ||
          (!allowEmpty && value.trim().isEmpty) ||
          value.contains(apiKey)) {
        throw _invalidInput;
      }
    }

    checkText(persona, allowEmpty: true);
    checkText(text);
    for (final turn in history) {
      checkText(turn.user);
      checkText(turn.assistant);
    }
    final body = utf8.encode(
      jsonEncode({
        'model': model,
        'stream': false,
        'messages': [
          if (persona.trim().isNotEmpty) {'role': 'system', 'content': persona},
          for (final turn in history) ...[
            {'role': 'user', 'content': turn.user},
            {'role': 'assistant', 'content': turn.assistant},
          ],
          {'role': 'user', 'content': text},
        ],
      }),
    );
    if (body.length > _maxBytes) throw _invalidInput;

    // dart:io's debug HTTP profiler records headers and bodies. Fail closed
    // when it is enabled rather than changing app-wide profiling state.
    if (HttpClient.enableTimelineLogging) throw _unavailable;

    _ProviderCall? call;
    try {
      final active = _ProviderCall(HttpClient());
      call = active;
      _active.add(active);
      active.client
        ..findProxy = null
        ..autoUncompress = false;
      final result = await Future.any<Object>([
        _send(active, uri, apiKey, body),
        active.closed.future,
      ]).timeout(timeout, onTimeout: () => throw _timeoutError);
      if (active.closed.isCompleted) throw _closedError;
      return result as String;
    } on AndroidPrivateModelException {
      rethrow;
    } on Object {
      // Transport/parser errors can include request URLs, headers and bodies.
      throw _unavailable;
    } finally {
      if (call != null) {
        _active.remove(call);
        call.dispose();
      }
    }
  }

  Future<String> _send(
    _ProviderCall call,
    Uri endpoint,
    String apiKey,
    List<int> body,
  ) async {
    final request = await call.client.postUrl(endpoint);
    if (call.disposed) {
      request.abort(_closedError);
      // A connection finishing after cancellation must never carry a key.
      throw _closedError;
    }
    request
      ..followRedirects = false
      ..maxRedirects = 0
      ..persistentConnection = false
      ..contentLength = body.length;
    request.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.acceptHeader, 'application/json')
      ..set(HttpHeaders.acceptEncodingHeader, 'identity')
      ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    request.add(body);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw const AndroidPrivateModelException(
        AndroidPrivateModelFailure.rejected,
      );
    }
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    if ((encoding != null && encoding.toLowerCase() != 'identity') ||
        response.contentLength > _maxBytes) {
      throw _invalidResponse;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (bytes.length + chunk.length > _maxBytes) throw _invalidResponse;
      bytes.add(chunk);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    } on FormatException {
      throw _invalidResponse;
    }
    final choices = decoded is Map<String, Object?> ? decoded['choices'] : null;
    if (choices is! List<Object?> || choices.isEmpty) throw _invalidResponse;
    final choice = choices.first;
    final message = choice is Map<String, Object?> ? choice['message'] : null;
    if (message is! Map<String, Object?> ||
        (message['role'] != null && message['role'] != 'assistant') ||
        message['function_call'] != null ||
        message['tool_calls'] != null) {
      throw _invalidResponse;
    }
    final content = message['content'];
    if (content is! String ||
        content.trim().isEmpty ||
        content.contains(apiKey)) {
      throw _invalidResponse;
    }
    return content;
  }

  /// Aborts local transport; a provider may already have processed a POST.
  void close() {
    if (_closed) return;
    _closed = true;
    for (final call in _active) {
      call.closed.complete(_closedError);
      call.dispose();
    }
  }
}

class _ProviderCall {
  _ProviderCall(this.client);

  final HttpClient client;
  final closed = Completer<AndroidPrivateModelException>();
  bool disposed = false;

  void dispose() {
    if (disposed) return;
    disposed = true;
    client.close(force: true);
  }
}
