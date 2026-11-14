import 'dart:async';
import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/models/openai_chat_adapter.dart';
import 'package:jingyu_host/src/security/guarded_http.dart';
import 'package:test/test.dart';

const secret = 'sk-private-provider-key';
const turns = [ChatTurn(role: 'user', content: 'Hello')];

Map<String, Object?> completion({
  Object? usage = const {
    'prompt_tokens': 3,
    'completion_tokens': 2,
    'total_tokens': 5,
  },
}) => {
  'id': 'provider-private-id',
  'choices': [
    {
      'message': {'role': 'assistant', 'content': 'Hello back'},
    },
  ],
  'usage': ?usage,
};

GuardedResponse response(Object? payload, {int status = 200}) =>
    GuardedResponse(
      statusCode: status,
      headers: {},
      body: utf8.encode(jsonEncode(payload)),
    );

class Requests {
  int count = 0;
  String? method;
  Uri? uri;
  Map<String, String>? headers;
  Object? body;
  late Future<Result<GuardedResponse>> Function() reply;

  Future<Result<GuardedResponse>> request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    count++;
    this.method = method;
    this.uri = uri;
    this.headers = headers;
    this.body = body == null ? null : jsonDecode(utf8.decode(body));
    return reply();
  }
}

void main() {
  late Requests requests;
  late OpenAiCompatibleChatAdapter adapter;
  setUp(() {
    requests = Requests()..reply = (() async => Ok(response(completion())));
    adapter = OpenAiCompatibleChatAdapter.withRequest(requests.request);
  });

  Future<Result<ChatCompletion>> chat({
    String base = 'https://api.example/v1',
    String model = 'chat-model',
    List<ChatTurn> messages = turns,
    int? maxTokens,
    String apiKey = secret,
  }) => adapter.chat(
    baseUrl: Uri.parse(base),
    apiKey: apiKey,
    model: model,
    messages: messages,
    maxTokens: maxTokens,
  );

  void safe(Result<ChatCompletion> result, FailureCode code) {
    expect(result.isErr, isTrue);
    final failure = result.failureOrNull!;
    expect(failure.code, code);
    expect(failure.details, isEmpty);
    expect('$result $failure ${failure.message}', isNot(contains(secret)));
    expect('$result $failure', isNot(contains('provider-private-id')));
  }

  test(
    'sends one non-streaming POST preserving base path and parses usage',
    () async {
      final result = await chat(
        messages: const [
          ChatTurn(role: 'system', content: 'Be helpful'),
          ChatTurn(role: 'user', content: 'Hello'),
          ChatTurn(role: 'assistant', content: 'Earlier'),
        ],
      );
      expect(requests.count, 1);
      expect(requests.method, 'POST');
      expect(
        requests.uri.toString(),
        'https://api.example/v1/chat/completions',
      );
      expect(requests.headers, {
        'content-type': 'application/json',
        'authorization': 'Bearer $secret',
      });
      expect(requests.body, {
        'model': 'chat-model',
        'stream': false,
        'messages': [
          {'role': 'system', 'content': 'Be helpful'},
          {'role': 'user', 'content': 'Hello'},
          {'role': 'assistant', 'content': 'Earlier'},
        ],
      });
      expect(result.isOk, isTrue);
      expect(result.value.text, 'Hello back');
      expect(result.value.inputTokens, 3);
      expect(result.value.outputTokens, 2);
      expect(result.value.totalTokens, 5);
      expect('$result ${result.value}', isNot(contains('provider-private-id')));
    },
  );

  test(
    'appends endpoint to trailing slash base and honors explicit maxTokens',
    () async {
      await chat(base: 'https://api.example/custom/v1/', maxTokens: 17);
      expect(
        requests.uri.toString(),
        'https://api.example/custom/v1/chat/completions',
      );
      expect((requests.body as Map)['max_tokens'], 17);
    },
  );

  test('rejects invalid input before any request', () async {
    for (final model in ['', '  ', 'bad\nmodel']) {
      safe(await chat(model: model), FailureCode.invalidArgument);
    }
    for (final messages in <List<ChatTurn>>[
      [],
      [const ChatTurn(role: 'tool', content: 'text')],
      [const ChatTurn(role: 'User', content: 'text')],
      [const ChatTurn(role: 'user', content: '  ')],
    ]) {
      safe(await chat(messages: messages), FailureCode.invalidArgument);
    }
    for (final max in [0, -1]) {
      safe(await chat(maxTokens: max), FailureCode.invalidArgument);
    }
    for (final key in ['', 'bad\r\nkey']) {
      safe(await chat(apiKey: key), FailureCode.invalidArgument);
    }
    for (final base in [
      'https://api.example/v1?key=$secret',
      'https://$secret@api.example/v1',
      'https://api.example/v1#fragment',
      'file:///v1',
    ]) {
      safe(await chat(base: base), FailureCode.invalidArgument);
    }
    expect(requests.count, 0);
  });

  test('missing or malformed usage never becomes zero usage', () async {
    for (final usage in [
      null,
      {},
      [],
      {'prompt_tokens': -1, 'completion_tokens': 2, 'total_tokens': 1},
      {'prompt_tokens': 3.0, 'completion_tokens': 2, 'total_tokens': 5},
      {'prompt_tokens': 3, 'completion_tokens': '2', 'total_tokens': 5},
      {'prompt_tokens': 3, 'completion_tokens': 2, 'total_tokens': 6},
      {'prompt_tokens': 3, 'completion_tokens': -2, 'total_tokens': 1},
      {'prompt_tokens': 3, 'completion_tokens': 2, 'total_tokens': -5},
    ]) {
      requests.reply = () async => Ok(response(completion(usage: usage)));
      safe(await chat(), FailureCode.modelUnavailable);
    }
    expect(requests.count, 9);
  });

  test(
    'production constructor retains guarded transport URL restrictions',
    () async {
      final guarded = OpenAiCompatibleChatAdapter(GuardedHttpTransport());
      final result = await guarded.chat(
        baseUrl: Uri.parse('https://localhost/v1'),
        apiKey: secret,
        model: 'chat-model',
        messages: turns,
      );
      safe(result, FailureCode.forbidden);
    },
  );

  test('token totals remain exact at native integer boundary', () async {
    requests.reply = () async => Ok(
      response(
        completion(
          usage: {
            'prompt_tokens': 9223372036854775806,
            'completion_tokens': 1,
            'total_tokens': 9223372036854775807,
          },
        ),
      ),
    );
    expect((await chat()).value.totalTokens, 9223372036854775807);
    requests.reply = () async => Ok(
      response(
        completion(
          usage: {
            'prompt_tokens': 9223372036854775807,
            'completion_tokens': 1,
            'total_tokens': 0,
          },
        ),
      ),
    );
    safe(await chat(), FailureCode.modelUnavailable);
  });

  test('accepts genuine reported zero tokens', () async {
    requests.reply = () async => Ok(
      response(
        completion(
          usage: {
            'prompt_tokens': 0,
            'completion_tokens': 0,
            'total_tokens': 0,
          },
        ),
      ),
    );
    expect((await chat()).value.totalTokens, 0);
  });

  test('malformed choices and JSON return safe failure', () async {
    for (final choices in [
      null,
      [],
      {},
      [null],
      [{}],
      [
        {
          'message': {'role': 'user', 'content': 'text'},
        },
      ],
      [
        {
          'message': {'role': 'assistant', 'content': null},
        },
      ],
      [
        {
          'message': {'role': 'assistant', 'content': []},
        },
      ],
      [
        {
          'message': {'role': 'assistant', 'content': ''},
        },
      ],
    ]) {
      requests.reply = () async =>
          Ok(response({...completion(), 'choices': choices}));
      safe(await chat(), FailureCode.modelUnavailable);
    }
    for (final body in [
      utf8.encode(secret),
      [255],
      utf8.encode('[]'),
    ]) {
      requests.reply = () async =>
          Ok(GuardedResponse(statusCode: 200, headers: {}, body: body));
      safe(await chat(), FailureCode.modelUnavailable);
    }
    expect(requests.count, 12);
  });

  test('HTTP failures ignore raw payload and do not retry', () async {
    for (final status in [401, 403, 429, 500, 503, 302, 400]) {
      requests.reply = () async =>
          Ok(response({'error': secret}, status: status));
      final before = requests.count;
      safe(
        await chat(),
        status == 401 || status == 403
            ? FailureCode.forbidden
            : status == 429
            ? FailureCode.rateLimited
            : FailureCode.modelUnavailable,
      );
      expect(requests.count, before + 1);
    }
  });

  test('transport errors and exceptions cannot leak credentials', () async {
    for (final code in [FailureCode.forbidden, FailureCode.unavailable]) {
      requests.reply = () async => err(code, secret, {'raw': secret});
      safe(
        await chat(),
        code == FailureCode.forbidden
            ? FailureCode.forbidden
            : FailureCode.modelUnavailable,
      );
    }
    for (final error in [TimeoutException(secret), StateError(secret)]) {
      requests.reply = () async => throw error;
      safe(await chat(), FailureCode.modelUnavailable);
    }
    expect(requests.count, 4);
  });
}
