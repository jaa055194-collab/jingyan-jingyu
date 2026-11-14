/// A bounded process boundary around one guarded outbound HTTP request.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';

import 'guarded_http.dart';

/// [executable] and [workerPath] are trusted application configuration, never
/// request data. Both paths must be absolute; deployment supplies the Dart SDK
/// executable and its packaged worker source explicitly.
/// Each child receives secrets only through stdin and is reaped before returning.
final class ProcessHttpTransport {
  ProcessHttpTransport({
    required this.executable,
    required this.workerPath,
    this.timeout = const Duration(seconds: 15),
    this.maxResponseBytes = 4 * 1024 * 1024,
  }) {
    if (!File(executable).isAbsolute || !File(workerPath).isAbsolute) {
      throw ArgumentError('出站进程启动路径必须是受信绝对路径');
    }
    if (timeout <= Duration.zero || maxResponseBytes <= 0) {
      throw ArgumentError('请求时限与响应体限额必须大于零');
    }
  }

  final String executable;
  final String workerPath;
  final Duration timeout;
  final int maxResponseBytes;

  static const _maxChildren = 4;
  static const _maxIpcBytes = 8 * 1024 * 1024;
  static const _maxStderrBytes = 64 * 1024;
  static int _activeChildren = 0;

  Future<Result<GuardedResponse>> request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    if (_activeChildren >= _maxChildren) {
      return err(FailureCode.unavailable, '出站进程容量已满');
    }
    _activeChildren++;
    Process? child;
    StreamSubscription<List<int>>? outSubscription;
    StreamSubscription<List<int>>? errSubscription;
    var exited = false;
    var releaseSlot = true;
    final stopped = Completer<void>();
    final timer = Timer(timeout, () {
      if (!stopped.isCompleted) stopped.complete();
    });
    void stop() {
      if (!stopped.isCompleted) stopped.complete();
    }

    try {
      // Base64 keeps binary bodies lossless. No request material appears in argv,
      // an environment override, exception messages or child diagnostic output.
      if ((body?.length ?? 0) > _maxIpcBytes ~/ 2) {
        return err(FailureCode.unavailable, '请求超过进程通信限额');
      }
      final input = utf8.encode(
        '${jsonEncode({'method': method, 'url': uri.toString(), 'headers': headers, 'body': body == null ? null : base64Encode(body), 'timeout': timeout.inMicroseconds, 'maxResponseBytes': maxResponseBytes})}\n',
      );
      if (input.length > _maxIpcBytes) {
        return err(FailureCode.unavailable, '请求超过进程通信限额');
      }
      child = await Process.start(executable, [workerPath]);
      final process = child;
      final exit = process.exitCode.then((code) {
        exited = true;
        return code;
      });
      final output = <int>[];
      var stderrBytes = 0;
      final outDone = Completer<void>();
      final errDone = Completer<void>();
      outSubscription = process.stdout.listen(
        (chunk) {
          if (chunk.length > _maxIpcBytes - output.length) {
            stop();
          } else if (!stopped.isCompleted) {
            output.addAll(chunk);
          }
        },
        onError: (Object _) {
          stop();
        },
        onDone: () => outDone.complete(),
      );
      errSubscription = process.stderr.listen(
        (chunk) {
          // Discard diagnostics entirely; keep only a bounded byte counter.
          stderrBytes += chunk.length;
          if (stderrBytes > _maxStderrBytes) stop();
        },
        onError: (Object _) {
          stop();
        },
        onDone: () => errDone.complete(),
      );
      unawaited(() async {
        try {
          if (stopped.isCompleted) return;
          process.stdin.add(input);
          await process.stdin.close();
        } catch (_) {
          stop();
        }
      }());
      final finished = () async {
        final code = await exit;
        await Future.wait([outDone.future, errDone.future]);
        return code;
      }();
      final code = await Future.any<int?>([
        finished,
        stopped.future.then<int?>((_) => null),
      ]);
      if (code == null) {
        // Windows requires sigkill here: Dart's default signal did not terminate
        // a child blocked inside a native TLS handshake in the lifecycle test.
        if (!exited) process.kill(ProcessSignal.sigkill);
        try {
          await exit.timeout(const Duration(seconds: 3));
        } catch (_) {
          // Retain capacity until exit is actually observed. Never report that
          // resources were reclaimed merely because kill() was attempted.
          releaseSlot = false;
          unawaited(exit.then((_) => _activeChildren--));
          return err(FailureCode.unavailable, '无法确认出站进程已退出');
        }
        return err(FailureCode.unavailable, '出站进程请求失败或超时');
      }
      if (code != 0) return err(FailureCode.unavailable, '出站进程请求失败');
      return _decode(output);
    } catch (_) {
      if (child != null && !exited) {
        child.kill(ProcessSignal.sigkill);
        try {
          await child.exitCode.timeout(const Duration(seconds: 3));
        } catch (_) {
          releaseSlot = false;
          unawaited(child.exitCode.then((_) => _activeChildren--));
          return err(FailureCode.unavailable, '无法确认出站进程已退出');
        }
      }
      return err(FailureCode.unavailable, '出站进程请求失败');
    } finally {
      timer.cancel();
      await outSubscription?.cancel();
      await errSubscription?.cancel();
      if (child != null) {
        unawaited(
          child.stdin.close().then<void>((_) {}, onError: (Object _) {}),
        );
      }
      if (releaseSlot) _activeChildren--;
    }
  }

  Result<GuardedResponse> _decode(List<int> bytes) {
    try {
      final text = utf8.decode(bytes);
      if (!text.endsWith('\n') || '\n'.allMatches(text).length != 1) {
        throw const FormatException();
      }
      final value = jsonDecode(text);
      if (value is! Map<String, dynamic>) throw const FormatException();
      if (value['ok'] == false &&
          value.length == 2 &&
          (value['code'] == 'forbidden' || value['code'] == 'unavailable')) {
        return err(
          value['code'] == 'forbidden'
              ? FailureCode.forbidden
              : FailureCode.unavailable,
          '出站请求被拒绝或失败',
        );
      }
      if (value.length != 4 ||
          value['ok'] != true ||
          value['statusCode'] is! int ||
          (value['statusCode'] as int) < 100 ||
          (value['statusCode'] as int) > 599 ||
          value['headers'] is! Map<String, dynamic> ||
          value['body'] is! String) {
        throw const FormatException();
      }
      final headers = <String, List<String>>{};
      for (final entry in (value['headers'] as Map<String, dynamic>).entries) {
        if (entry.value is! List ||
            !(entry.value as List).every((v) => v is String)) {
          throw const FormatException();
        }
        headers[entry.key] = List<String>.from(entry.value as List);
      }
      final body = base64Decode(value['body'] as String);
      if (body.length > maxResponseBytes) throw const FormatException();
      return Ok(
        GuardedResponse(
          statusCode: value['statusCode'] as int,
          headers: headers,
          body: body,
        ),
      );
    } catch (_) {
      return err(FailureCode.unavailable, '出站进程协议无效');
    }
  }
}
