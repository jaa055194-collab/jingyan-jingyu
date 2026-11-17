import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'runtime_auth_test.dart'
    show Fixture, initializeAndSettleRefresh, nativeLogout;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test('confirmed create ID survives list refresh failure and refresh never repeats POST', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    var posts = 0, failedList = true;
    f.serve = (r) async {
      await r.drain<void>();
      if (r.uri.path == Routes.ownAiAccounts) {
        if (r.method == 'POST') {
          posts++;
          return f.reply(r, {'accountId': 'ai-created'});
        }
        if (failedList) {
          return f.reply(r, {'error': 'unavailable'}, status: 503);
        }
        r.response.write(
          '[{"accountId":"ai-created","displayName":"Nora","disabled":false}]',
        );
        await r.response.close();
        return;
      }
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      return f.reply(r, {'conversations': []});
    };
    final runtime = ClientRuntime();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      await (runtime as dynamic).createOwnAi('Nora');
      expect((runtime as dynamic).ownAiNotice, contains('ai-created'));
      expect((runtime as dynamic).ownAiAccounts, isEmpty);
      expect(posts, 1);
      failedList = false;
      await (runtime as dynamic).loadOwnAi();
      expect((runtime as dynamic).ownAiAccounts.single.accountId, 'ai-created');
      expect(posts, 1);
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });
  test('uncertain retry does not inherit a prior create confirmation', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    var posts = 0;
    f.serve = (r) async {
      await r.drain<void>();
      if (r.uri.path == Routes.ownAiAccounts) {
        if (r.method == 'POST') {
          posts++;
          if (posts == 1) return f.reply(r, {'accountId': 'ai-created'});
          return f.reply(r, {'error': 'unavailable'}, status: 503);
        }
        if (posts == 1) {
          return f.reply(r, {'error': 'unavailable'}, status: 503);
        }
        r.response.write('[]');
        await r.response.close();
        return;
      }
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      return f.reply(r, {'conversations': []});
    };
    final runtime = ClientRuntime();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      await runtime.createOwnAi('First');
      expect(runtime.ownAiNotice, contains('ai-created'));
      await runtime.createOwnAi('Retry');
      expect(posts, 2);
      expect(runtime.ownAiNotice, isNull);
      expect(runtime.error, contains('可能已创建'));
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });

  test('definitive forbidden creation is not reported as uncertain', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    f.serve = (r) async {
      await r.drain<void>();
      if (r.uri.path == Routes.ownAiAccounts) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      return f.reply(r, {'conversations': []});
    };
    final runtime = ClientRuntime();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      await runtime.createOwnAi('N');
      expect(runtime.error, isNot(contains('可能已创建')));
      expect(runtime.error, contains('403'));
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });
  test(
    'final unauthorized replay clears own AI metadata and session eligibility',
    () async {
      final f = await Fixture.create();
      f.secure = jsonEncode(f.session());
      var reject = false;
      f.serve = (r) async {
        await r.drain<void>();
        if (r.uri.path == Routes.authRefresh) {
          return f.reply(r, {
            'deviceId': 'phone',
            'accessToken': 'rotated',
            'refreshToken': 'rotated-refresh',
          });
        }
        if (r.uri.path == Routes.ownAiAccounts) {
          if (reject) {
            return f.reply(r, {'error': 'unauthenticated'}, status: 401);
          }
          r.response.write(
            '[{"accountId":"ai","displayName":"N","disabled":false}]',
          );
          await r.response.close();
          return;
        }
        if (r.uri.path == Routes.hostInfo) {
          return f.reply(r, {'error': 'forbidden'}, status: 403);
        }
        return f.reply(r, {'conversations': []});
      };
      final runtime = ClientRuntime();
      try {
        await initializeAndSettleRefresh(runtime);
        runtime.reconnect?.cancel();
        await runtime.loadOwnAi();
        expect(runtime.ownAiAccounts, hasLength(1));
        reject = true;
        await runtime.loadOwnAi();
        expect(runtime.ownAiAccounts, isEmpty);
        expect(runtime.ownAiNotice, isNull);
        expect(runtime.authenticated, isFalse);
      } finally {
        runtime.dispose();
        await f.cleanup();
      }
    },
  );

  test(
    'terminal rejection during lock clears cached owned AI metadata',
    () async {
      final f = await Fixture.create();
      f.secure = jsonEncode(f.session());
      final requestStarted = Completer<void>();
      final releaseRequest = Completer<void>();
      var reject = false;
      f.serve = (r) async {
        await r.drain<void>();
        if (r.uri.path == Routes.authRefresh) {
          if (reject) {
            requestStarted.complete();
            await releaseRequest.future;
          }
          return f.reply(r, {
            'deviceId': 'phone',
            'accessToken': 'rotated',
            'refreshToken': 'rotated-refresh',
          });
        }
        if (r.uri.path == Routes.ownAiAccounts) {
          if (reject) {
            return f.reply(r, {'error': 'unauthenticated'}, status: 401);
          }
          r.response.write(
            '[{"accountId":"ai","displayName":"N","disabled":false}]',
          );
          await r.response.close();
          return;
        }
        if (r.uri.path == Routes.hostInfo) {
          return f.reply(r, {'error': 'forbidden'}, status: 403);
        }
        return f.reply(r, {'conversations': []});
      };
      final runtime = ClientRuntime();
      try {
        await initializeAndSettleRefresh(runtime);
        runtime.reconnect?.cancel();
        await runtime.loadOwnAi();
        expect(runtime.ownAiAccounts, hasLength(1));
        await runtime.setAppLock(true, '1234');
        reject = true;
        final work = runtime.loadOwnAi();
        await requestStarted.future;
        runtime.appLock.lock();
        releaseRequest.complete();
        await work;
        expect(runtime.locked, isTrue);
        expect(runtime.authenticated, isFalse);
        expect(runtime.ownAiAccounts, isEmpty);
        expect(runtime.ownAiNotice, isNull);
      } finally {
        if (!releaseRequest.isCompleted) releaseRequest.complete();
        runtime.dispose();
        await f.cleanup();
      }
    },
  );

  test('confirmed create survives a list 401 with transient renewal failure', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    var ownedGets = 0, posts = 0;
    f.serve = (r) async {
      await r.drain<void>();
      if (r.uri.path == Routes.ownAiAccounts) {
        if (r.method == 'POST') {
          posts++;
          return f.reply(r, {'accountId': 'ai-created'});
        }
        ownedGets++;
        if (ownedGets == 1) {
          r.response.write(
            '[{"accountId":"ai","displayName":"Existing","disabled":false}]',
          );
          await r.response.close();
          return;
        }
        return f.reply(r, {'error': 'unauthenticated'}, status: 401);
      }
      if (r.uri.path == Routes.authRefresh) {
        return f.reply(r, {'error': 'unavailable'}, status: 503);
      }
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      return f.reply(r, {'conversations': []});
    };
    final runtime = ClientRuntime();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      await runtime.loadOwnAi();
      expect(runtime.ownAiAccounts, hasLength(1));
      await runtime.createOwnAi('Created');
      expect(posts, 1);
      expect(runtime.authenticated, isTrue);
      expect(runtime.ownAiNotice, contains('ai-created'));
      expect(runtime.error, isNull);
      expect(runtime.ownAiAccounts, hasLength(1));
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });

  test('failed transient renewal retains auth and owned AI metadata', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    var transient = false;
    f.serve = (r) async {
      await r.drain<void>();
      if (r.uri.path == Routes.ownAiAccounts) {
        if (transient) {
          r.response.statusCode = 401;
          r.response.write('{"error":"unauthenticated"}');
        } else {
          r.response.write(
            '[{"accountId":"ai","displayName":"N","disabled":false}]',
          );
        }
        await r.response.close();
        return;
      }
      if (r.uri.path == Routes.authRefresh) {
        r.response.statusCode = 503;
        r.response.write('{"error":"unavailable"}');
        await r.response.close();
        return;
      }
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      return f.reply(r, {'conversations': []});
    };
    final runtime = ClientRuntime();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      await runtime.loadOwnAi();
      expect(runtime.ownAiAccounts, hasLength(1));
      transient = true;
      await runtime.loadOwnAi();
      expect(runtime.authenticated, isTrue);
      expect(runtime.ownAiAccounts, hasLength(1));
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });

  test('transient renewal failure during lock retains cached owned AI', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    final requestStarted = Completer<void>();
    final releaseRequest = Completer<void>();
    var reject = false;
    f.serve = (r) async {
      await r.drain<void>();
      if (r.uri.path == Routes.authRefresh) {
        requestStarted.complete();
        await releaseRequest.future;
        return f.reply(r, {'error': 'unavailable'}, status: 503);
      }
      if (r.uri.path == Routes.ownAiAccounts) {
        if (reject) {
          return f.reply(r, {'error': 'unauthenticated'}, status: 401);
        }
        r.response.write(
          '[{"accountId":"ai","displayName":"N","disabled":false}]',
        );
        await r.response.close();
        return;
      }
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      return f.reply(r, {'conversations': []});
    };
    final runtime = ClientRuntime();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      await runtime.loadOwnAi();
      expect(runtime.ownAiAccounts, hasLength(1));
      await runtime.setAppLock(true, '1234');
      reject = true;
      final work = runtime.loadOwnAi();
      await requestStarted.future;
      runtime.appLock.lock();
      releaseRequest.complete();
      await work;
      expect(runtime.locked, isTrue);
      expect(runtime.authenticated, isTrue);
      expect(runtime.ownAiAccounts, hasLength(1));
      expect(runtime.ownAiNotice, isNull);
    } finally {
      if (!releaseRequest.isCompleted) releaseRequest.complete();
      runtime.dispose();
      await f.cleanup();
    }
  });

  test('late malformed list error after lock is discarded', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    final started = Completer<void>(), release = Completer<void>();
    f.serve = (r) async {
      await r.drain<void>();
      if (r.uri.path == Routes.ownAiAccounts) {
        started.complete();
        await release.future;
        r.response.write('private-raw-json');
        await r.response.close();
        return;
      }
      if (r.uri.path == Routes.hostInfo) {
        return f.reply(r, {'error': 'forbidden'}, status: 403);
      }
      return f.reply(r, {'conversations': []});
    };
    final runtime = ClientRuntime();
    try {
      await initializeAndSettleRefresh(runtime);
      runtime.reconnect?.cancel();
      await runtime.setAppLock(true, '1234');
      final work = runtime.loadOwnAi();
      await started.future;
      runtime.appLock.lock();
      release.complete();
      await work;
      expect(runtime.error, isNull);
      expect(runtime.ownAiAccounts, isEmpty);
    } finally {
      if (!release.isCompleted) release.complete();
      runtime.dispose();
      await f.cleanup();
    }
  });

  test(
    'late owned list after logout never publishes private metadata',
    () async {
      final f = await Fixture.create();
      f.secure = jsonEncode(f.session());
      final started = Completer<void>(), release = Completer<void>();
      f.serve = (r) async {
        await r.drain<void>();
        if (r.uri.path == Routes.ownAiAccounts) {
          started.complete();
          await release.future;
          try {
            r.response.write(
              '[{"accountId":"private-ai","displayName":"Private","disabled":false}]',
            );
            await r.response.close();
          } catch (_) {}
          return;
        }
        if (r.uri.path == Routes.hostInfo) {
          return f.reply(r, {'error': 'forbidden'}, status: 403);
        }
        return f.reply(r, {'conversations': []});
      };
      final runtime = ClientRuntime();
      try {
        await initializeAndSettleRefresh(runtime);
        runtime.reconnect?.cancel();
        final work = (runtime as dynamic).loadOwnAi() as Future<void>;
        await started.future;
        await nativeLogout();
        release.complete();
        await work;
        expect((runtime as dynamic).ownAiAccounts, isEmpty);
        expect((runtime as dynamic).ownAiNotice, isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        runtime.dispose();
        await f.cleanup();
      }
    },
  );
}
