import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'runtime_auth_test.dart'
    show Fixture, initializeAndSettleRefresh, nativeLogout;

class _ConsentFixture {
  _ConsentFixture(this.native);
  final Fixture native;
  final calls = <String>[];
  bool disabled = false;
  String mappedOwner = 'alice', mappedAccount = 'ai-account';
  String consentAccount = 'ai-account';
  int revision = 0;
  bool enabled = false;
  int? mutationFailure;
  bool malformedMutation = false;
  bool disconnectMutation = false;
  int? readFailure;
  bool malformedRead = false;
  Completer<void>? mutationStarted, mutationRelease;
  Completer<void>? readStarted, readRelease, readFinished;

  static Future<_ConsentFixture> create() async {
    final fixture = _ConsentFixture(await Fixture.create());
    fixture.native.secure = jsonEncode(fixture.native.session());
    fixture.native.serve = fixture.serve;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('jingyu/platform'), (
          call,
        ) async {
          switch (call.method) {
            case 'initialize':
              return <String, Object?>{};
            case 'getDataDirectory':
              return fixture.native.root.path;
            case 'readSession':
              return fixture.native.secure;
            case 'hasPin':
              return false;
            case 'unlockPin':
              return true;
            case 'storeSession':
              fixture.native.secure = (call.arguments as Map)['json'] as String;
              return null;
            case 'clearSession':
              fixture.native.secure = null;
              return null;
            default:
              return null;
          }
        });
    return fixture;
  }

  Map<String, Object?> state() => {
    'scope': 'ownerTextOnly',
    'aiProfileId': 'profile-distinct',
    'aiAccountId': consentAccount,
    'revision': revision,
    'enabled': enabled,
    'conversationId': revision == 0 ? null : 'direct-conversation',
  };

  Future<void> serve(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    final path = request.uri.path;
    calls.add('${request.method} $path');
    if (path == Routes.ownAiAccounts) {
      request.response.write(
        jsonEncode([
          {
            'accountId': 'ai-account',
            'displayName': 'Synthetic AI',
            'disabled': disabled,
          },
        ]),
      );
      await request.response.close();
      return;
    }
    if (path == Routes.aiProfileRegister) {
      expect(jsonDecode(text), {'accountId': 'ai-account'});
      return native.reply(request, {
        'profileId': 'profile-distinct',
        'accountId': mappedAccount,
        'ownerAccountId': mappedOwner,
      });
    }
    if (path ==
        Routes.ownerAiDirectConsent.replaceFirst(
          '{aiId}',
          'profile-distinct',
        )) {
      if (request.method == 'GET') {
        readStarted?.complete();
        await readRelease?.future;
        if (readFailure != null) {
          return native.reply(request, {
            'error': readFailure == 401 ? 'unauthenticated' : 'unavailable',
          }, status: readFailure!);
        }
        if (malformedRead) {
          return native.reply(request, {'privateRaw': 'must-not-surface'});
        }
        final response = state();
        try {
          await native.reply(request, response);
        } finally {
          if (readFinished != null && !readFinished!.isCompleted) {
            readFinished!.complete();
          }
        }
        return;
      }
      mutationStarted?.complete();
      await mutationRelease?.future;
      expect(jsonDecode(text), {'expectedRevision': revision});
      if (disconnectMutation) {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
      if (mutationFailure != null) {
        if (mutationFailure == 409) {
          revision++;
          enabled = true;
        }
        return native.reply(request, {
          'error': mutationFailure == 409
              ? 'conflict'
              : mutationFailure == 401
              ? 'unauthenticated'
              : 'unavailable',
        }, status: mutationFailure!);
      }
      revision++;
      enabled = request.method == 'POST';
      if (malformedMutation) {
        return native.reply(request, {'privateRaw': 'must-not-surface'});
      }
      return native.reply(request, state());
    }
    if (path == Routes.authLogin) {
      return native.reply(request, {
        'deviceId': 'phone',
        'accessToken': 'new-access',
        'refreshToken': 'new-refresh',
      });
    }
    if (path == Routes.authRefresh) {
      return native.reply(request, {'error': 'unavailable'}, status: 503);
    }
    if (path == Routes.hostInfo) {
      return native.reply(request, {'error': 'forbidden'}, status: 403);
    }
    return native.reply(request, {'conversations': []});
  }

  int get mutations => calls
      .where(
        (c) =>
            (c.startsWith('POST ') || c.startsWith('DELETE ')) &&
            c.endsWith('/direct-conversation'),
      )
      .length;
  int get registrations =>
      calls.where((c) => c == 'POST ${Routes.aiProfileRegister}').length;
  Future<ClientRuntime> runtime() async {
    final runtime = ClientRuntime();
    await initializeAndSettleRefresh(runtime);
    runtime.reconnect?.cancel();
    await runtime.loadOwnAi();
    return runtime;
  }

  Future<void> dispose(ClientRuntime runtime) async {
    if (mutationRelease != null && !mutationRelease!.isCompleted) {
      mutationRelease!.complete();
    }
    if (readRelease != null && !readRelease!.isCompleted) {
      readRelease!.complete();
    }
    // unlock() starts the existing background refresh; settle it before deleting
    // the fixture snapshot directory (Windows forbids unlinking an open file).
    if (runtime.authenticated && !runtime.locked) {
      await runtime.refreshConversations();
    }
    runtime.dispose();
    await native.cleanup();
  }
}

Future<void> _set(
  ClientRuntime runtime, {
  bool enabled = true,
  Object? context,
  int? revision,
  String? profile,
}) => runtime.setOwnAiDirectConsent(
  'ai-account',
  profileId: profile ?? 'profile-distinct',
  expectedRevision:
      revision ?? runtime.ownAiDirectState('ai-account').revision!,
  enabled: enabled,
  interactionContext: context ?? runtime.ownAiDirectContext!,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('owner chat shortcut sync leaves a queued message unsent', () async {
    final f = await _ConsentFixture.create();
    final runtime = await f.runtime();
    const directId = 'direct-conversation';
    final sync = <String?>[];
    final syncStarted = Completer<void>();
    final releaseSync = Completer<void>();
    var posts = 0;
    f.native.serve = (request) async {
      if (request.uri.path == Routes.directConversations) {
        await request.drain<void>();
        return f.native.reply(request, {
          'conversations': [
            {'id': directId, 'kind': 'direct'},
          ],
        });
      }
      if (request.uri.path == '/api/v1/conversations/$directId/sync') {
        await request.drain<void>();
        sync.add(request.uri.queryParameters['afterSeq']);
        if (!syncStarted.isCompleted) {
          syncStarted.complete();
          await releaseSync.future;
        }
        return f.native.reply(request, {'messages': [], 'hasMore': false});
      }
      if (request.uri.path == '/api/v1/conversations/$directId/messages') {
        await request.drain<void>();
        posts++;
        return f.native.reply(request, {});
      }
      return f.serve(request);
    };
    try {
      await runtime.shell.enqueue(directId, MessageKind.text, {
        'text': 'queued',
      });
      final opening = runtime.refreshForOwnAiChat();
      await syncStarted.future.timeout(const Duration(seconds: 5));
      expect(runtime.conversations.single.id, directId);
      expect(sync, ['0']);
      expect(posts, 0);
      expect(runtime.queuedCount, 1);

      // An independently requested ordinary refresh must still flush, even
      // while the shortcut's read-only refresh is in flight.
      final ordinary = runtime.refreshConversations();
      releaseSync.complete();
      expect(await opening, isTrue);
      await ordinary;
      expect(posts, 1);
      expect(runtime.queuedCount, 0);
    } finally {
      if (!releaseSync.isCompleted) releaseSync.complete();
      await f.dispose(runtime);
    }
  });

  test(
    'delayed GET cannot publish after lock and unlock finish before response',
    () async {
      final f = await _ConsentFixture.create();
      final runtime = await f.runtime();
      try {
        await runtime.loadOwnAiDirectConsent('ai-account');
        final confirmation = runtime.ownAiDirectContext!;
        await runtime.setAppLock(true, '1234');
        f.enabled = true;
        f.revision = 1;
        f.readStarted = Completer<void>();
        f.readRelease = Completer<void>();
        f.readFinished = Completer<void>();
        final pending = runtime.loadOwnAiDirectConsent('ai-account');
        await f.readStarted!.future.timeout(const Duration(seconds: 5));
        runtime.appLock.lock();
        expect(runtime.locked, true);
        expect(await runtime.appLock.unlockWithPin('1234'), true);
        expect(runtime.locked, false);
        f.readRelease!.complete();
        await pending.timeout(const Duration(seconds: 5));
        await f.readFinished!.future.timeout(const Duration(seconds: 5));
        final state = runtime.ownAiDirectState('ai-account');
        expect(state.phase, ShellOwnAiDirectPhase.unknown);
        expect(state.enabled, isNull);
        expect(state.revision, isNull);
        await _set(runtime, context: confirmation, revision: 0);
        expect(f.mutations, 0);
      } finally {
        await f.dispose(runtime);
      }
    },
  );

  test(
    'delayed old-owner GET cannot publish into a distinct owner session',
    () async {
      final f = await _ConsentFixture.create();
      final runtime = await f.runtime();
      try {
        await runtime.loadOwnAiDirectConsent('ai-account');
        final confirmation = runtime.ownAiDirectContext!;
        f.enabled = true;
        f.revision = 1;
        f.readStarted = Completer<void>();
        f.readRelease = Completer<void>();
        f.readFinished = Completer<void>();
        final pending = runtime.loadOwnAiDirectConsent('ai-account');
        await f.readStarted!.future.timeout(const Duration(seconds: 5));
        await nativeLogout();
        await pending.timeout(const Duration(seconds: 5));
        await runtime.connectHost(
          f.native.origin,
          '',
          accountId: 'bob',
          password: 'synthetic-only',
          deviceName: 'bob-device',
        );
        expect(runtime.connectedAccountId, 'bob');
        expect(runtime.authenticated, true);
        f.readRelease!.complete();
        await f.readFinished!.future.timeout(const Duration(seconds: 5));
        expect(
          runtime.ownAiDirectState('ai-account').phase,
          ShellOwnAiDirectPhase.unknown,
        );
        expect(runtime.ownAiDirectState('ai-account').enabled, isNull);
        expect(runtime.ownAiAccounts, isEmpty);
        await _set(runtime, context: confirmation, revision: 0);
        expect(f.mutations, 0);
      } finally {
        await f.dispose(runtime);
      }
    },
  );

  test(
    'dispose before delayed GET response never notifies or publishes cache',
    () async {
      final f = await _ConsentFixture.create();
      final runtime = await f.runtime();
      var notifications = 0;
      void listener() {
        notifications++;
      }

      try {
        runtime.addListener(listener);
        f.enabled = true;
        f.revision = 1;
        f.readStarted = Completer<void>();
        f.readRelease = Completer<void>();
        f.readFinished = Completer<void>();
        final pending = runtime.loadOwnAiDirectConsent('ai-account');
        await f.readStarted!.future.timeout(const Duration(seconds: 5));
        runtime.dispose();
        final atDispose = notifications;
        f.readRelease!.complete();
        await pending.timeout(const Duration(seconds: 5));
        await f.readFinished!.future.timeout(const Duration(seconds: 5));
        expect(notifications, atDispose);
        expect(runtime.ownAiDirectContext, isNull);
        expect(
          runtime.ownAiDirectState('ai-account').phase,
          ShellOwnAiDirectPhase.unknown,
        );
        expect(runtime.ownAiDirectState('ai-account').enabled, isNull);
        expect(f.mutations, 0);
      } finally {
        await f.dispose(runtime);
      }
    },
  );

  test('synchronous loading listener lock prevents profile registration before dispatch', () async {
    final f = await _ConsentFixture.create();
    final runtime = await f.runtime();
    void lockOnLoading() {
      if (runtime.ownAiDirectState('ai-account').phase ==
          ShellOwnAiDirectPhase.loading) {
        runtime.appLock.lock();
      }
    }

    try {
      runtime.addListener(lockOnLoading);
      await runtime.loadOwnAiDirectConsent('ai-account');
      expect(f.registrations, 0);
      expect(f.mutations, 0);
      expect(
        runtime.ownAiDirectState('ai-account').phase,
        ShellOwnAiDirectPhase.unknown,
      );
    } finally {
      runtime.removeListener(lockOnLoading);
      await f.dispose(runtime);
    }
  });

  test('synchronous loading listener lock prevents open and revoke before dispatch', () async {
    for (final enable in [true, false]) {
      final f = await _ConsentFixture.create();
      final runtime = await f.runtime();
      void lockOnLoading() {
        if (runtime.ownAiDirectState('ai-account').phase ==
            ShellOwnAiDirectPhase.loading) {
          runtime.appLock.lock();
        }
      }

      try {
        if (!enable) {
          f.enabled = true;
          f.revision = 1;
        }
        await runtime.loadOwnAiDirectConsent('ai-account');
        final context = runtime.ownAiDirectContext!;
        runtime.addListener(lockOnLoading);
        await _set(runtime, enabled: enable, context: context);
        expect(
          f.mutations,
          0,
          reason: enable
              ? 'POST open must not dispatch'
              : 'DELETE revoke must not dispatch',
        );
        expect(
          runtime.ownAiDirectState('ai-account').phase,
          ShellOwnAiDirectPhase.unknown,
        );
      } finally {
        runtime.removeListener(lockOnLoading);
        await f.dispose(runtime);
      }
    }
  });

  test('unknown is not off; explicit load validates canonical identity then GET only; explicit mutation CAS', () async {
    final f = await _ConsentFixture.create();
    final runtime = await f.runtime();
    try {
      expect(
        runtime.ownAiDirectState('ai-account').phase,
        ShellOwnAiDirectPhase.unknown,
      );
      expect(runtime.ownAiDirectState('ai-account').enabled, isNull);
      await runtime.loadOwnAiDirectConsent('ai-account');
      final state = runtime.ownAiDirectState('ai-account');
      expect(state.phase, ShellOwnAiDirectPhase.ready);
      expect(state.profileId, 'profile-distinct');
      expect(state.revision, 0);
      expect(state.enabled, false);
      expect(state.conversationId, isNull);
      expect(f.registrations, 1);
      expect(f.mutations, 0);
      await _set(runtime);
      expect(runtime.ownAiDirectState('ai-account').enabled, true);
      expect(runtime.ownAiDirectState('ai-account').revision, 1);
      expect(
        runtime.ownAiDirectState('ai-account').conversationId,
        'direct-conversation',
      );
      await _set(runtime, enabled: false);
      expect(runtime.ownAiDirectState('ai-account').enabled, false);
      expect(runtime.ownAiDirectState('ai-account').revision, 2);
      expect(f.mutations, 2);
    } finally {
      await f.dispose(runtime);
    }
  });

  for (final mismatch in ['owner', 'account', 'consent account']) {
    test('$mismatch mismatch never becomes ready or writes consent', () async {
      final f = await _ConsentFixture.create();
      final runtime = await f.runtime();
      try {
        if (mismatch == 'owner') f.mappedOwner = 'foreign';
        if (mismatch == 'account') f.mappedAccount = 'foreign-ai';
        if (mismatch == 'consent account') f.consentAccount = 'foreign-ai';
        await runtime.loadOwnAiDirectConsent('ai-account');
        expect(
          runtime.ownAiDirectState('ai-account').phase,
          isNot(ShellOwnAiDirectPhase.ready),
        );
        expect(runtime.ownAiDirectState('ai-account').enabled, isNull);
        expect(f.mutations, 0);
        expect(runtime.error, isNot(contains('must-not-surface')));
      } finally {
        await f.dispose(runtime);
      }
    });
  }

  test('disabled and foreign rows cannot register or mutate; own AI list refresh invalidates old metadata', () async {
    final f = await _ConsentFixture.create();
    final runtime = await f.runtime();
    try {
      await runtime.loadOwnAiDirectConsent('ai-account');
      final oldContext = runtime.ownAiDirectContext!;
      f.disabled = true;
      await runtime.loadOwnAi();
      expect(
        runtime.ownAiDirectState('ai-account').phase,
        ShellOwnAiDirectPhase.unknown,
      );
      await runtime.loadOwnAiDirectConsent('ai-account');
      await runtime.loadOwnAiDirectConsent('foreign');
      await _set(runtime, context: oldContext, revision: 0);
      expect(f.registrations, 1);
      expect(f.mutations, 0);
    } finally {
      await f.dispose(runtime);
    }
  });

  test('captured confirmation requires exact runtime context, profile and ready revision', () async {
    final f = await _ConsentFixture.create();
    final runtime = await f.runtime();
    try {
      await runtime.loadOwnAiDirectConsent('ai-account');
      await _set(runtime, context: Object());
      await _set(runtime, profile: 'ai-account');
      await _set(runtime, revision: 99);
      expect(f.mutations, 0);
      await _set(runtime);
      expect(f.mutations, 1);
    } finally {
      await f.dispose(runtime);
    }
  });

  test('409 performs GET-only reconciliation and consumes old confirmation without mutation replay', () async {
    final f = await _ConsentFixture.create();
    final runtime = await f.runtime();
    try {
      await runtime.loadOwnAiDirectConsent('ai-account');
      final context = runtime.ownAiDirectContext!;
      f.mutationFailure = 409;
      await _set(runtime, context: context);
      final state = runtime.ownAiDirectState('ai-account');
      expect(state.phase, ShellOwnAiDirectPhase.ready);
      expect(state.enabled, true);
      expect(state.revision, 1);
      expect(state.notice, isNotNull);
      expect(f.mutations, 1);
      expect(
        f.registrations,
        1,
        reason: 'conflict reconciliation is GET-only, not profile POST',
      );
      await _set(runtime, context: context, revision: 1, enabled: false);
      expect(f.mutations, 1);
    } finally {
      await f.dispose(runtime);
    }
  });

  for (final failure in ['503', 'malformed', 'socket']) {
    test(
      '$failure mutation is uncertain and prevents writes until fresh GET',
      () async {
        final f = await _ConsentFixture.create();
        final runtime = await f.runtime();
        try {
          await runtime.loadOwnAiDirectConsent('ai-account');
          final oldContext = runtime.ownAiDirectContext!;
          if (failure == '503') {
            f.mutationFailure = 503;
          } else if (failure == 'socket') {
            f.disconnectMutation = true;
          } else {
            f.malformedMutation = true;
          }
          await _set(runtime, context: oldContext);
          final state = runtime.ownAiDirectState('ai-account');
          expect(state.phase, ShellOwnAiDirectPhase.uncertain);
          expect(state.enabled, isNull);
          expect(state.revision, isNull);
          await _set(runtime, revision: 0);
          expect(f.mutations, 1);
          f.mutationFailure = null;
          f.malformedMutation = false;
          f.disconnectMutation = false;
          await runtime.loadOwnAiDirectConsent('ai-account');
          expect(
            runtime.ownAiDirectState('ai-account').phase,
            ShellOwnAiDirectPhase.ready,
          );
          await _set(runtime, enabled: false);
          expect(f.mutations, 2);
        } finally {
          await f.dispose(runtime);
        }
      },
    );
  }

  for (final code in [400, 403, 404, 429]) {
    test(
      'definitive $code invalidates ready state without claiming uncertain mutation',
      () async {
        final f = await _ConsentFixture.create();
        final runtime = await f.runtime();
        try {
          await runtime.loadOwnAiDirectConsent('ai-account');
          f.mutationFailure = code;
          await _set(runtime);
          final state = runtime.ownAiDirectState('ai-account');
          expect(state.phase, ShellOwnAiDirectPhase.unknown);
          expect(state.enabled, isNull);
          expect(state.revision, isNull);
          expect(runtime.error, isNotNull);
          await _set(runtime, revision: 0);
          expect(f.mutations, 1);
        } finally {
          await f.dispose(runtime);
        }
      },
    );
  }

  test('lock and unlock never resurrect an old confirmation context', () async {
    final f = await _ConsentFixture.create();
    final runtime = await f.runtime();
    try {
      await runtime.loadOwnAiDirectConsent('ai-account');
      final context = runtime.ownAiDirectContext!;
      await runtime.setAppLock(true, '1234');
      runtime.appLock.lock();
      expect(runtime.locked, true);
      expect(
        runtime.ownAiDirectState('ai-account').phase,
        ShellOwnAiDirectPhase.unknown,
      );
      expect(identical(runtime.ownAiDirectContext, context), false);
      await runtime.unlock('');
      await runtime.loadOwnAiDirectConsent('ai-account');
      await _set(runtime, context: context);
      expect(f.mutations, 0);
      await _set(runtime);
      expect(f.mutations, 1);
    } finally {
      await f.dispose(runtime);
    }
  });

  test('late mutation after hidden lifecycle cannot publish a grant', () async {
    final f = await _ConsentFixture.create();
    final runtime = await f.runtime();
    try {
      await runtime.loadOwnAiDirectConsent('ai-account');
      f.mutationStarted = Completer<void>();
      f.mutationRelease = Completer<void>();
      final work = _set(runtime);
      await f.mutationStarted!.future;
      runtime.didChangeAppLifecycleState(AppLifecycleState.hidden);
      f.mutationRelease!.complete();
      await work;
      expect(
        runtime.ownAiDirectState('ai-account').phase,
        ShellOwnAiDirectPhase.unknown,
      );
      expect(runtime.ownAiDirectState('ai-account').enabled, isNull);
      expect(f.mutations, 1);
    } finally {
      await f.dispose(runtime);
    }
  });

  test('terminal mutation 401 while locked clears caches and never renews/replays POST', () async {
    final f = await _ConsentFixture.create();
    final runtime = await f.runtime();
    try {
      await runtime.loadOwnAiDirectConsent('ai-account');
      f.mutationFailure = 401;
      f.mutationStarted = Completer<void>();
      f.mutationRelease = Completer<void>();
      final work = _set(runtime);
      await f.mutationStarted!.future;
      runtime.appLock.lock();
      f.mutationRelease!.complete();
      await work;
      expect(runtime.authenticated, false);
      expect(runtime.ownAiAccounts, isEmpty);
      expect(
        runtime.ownAiDirectState('ai-account').phase,
        ShellOwnAiDirectPhase.unknown,
      );
      expect(f.mutations, 1);
      expect(f.calls.where((c) => c.contains(Routes.authRefresh)), isEmpty);
    } finally {
      await f.dispose(runtime);
    }
  });

  test(
    'native lock and session replacement invalidate prior confirmation',
    () async {
      final f = await _ConsentFixture.create();
      final runtime = await f.runtime();
      try {
        await runtime.loadOwnAiDirectConsent('ai-account');
        final oldContext = runtime.ownAiDirectContext!;
        final done = Completer<void>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              'jingyu/platform',
              const StandardMethodCodec().encodeMethodCall(
                const MethodCall('event', {'type': 'lock'}),
              ),
              (_) => done.complete(),
            );
        await done.future;
        expect(
          runtime.ownAiDirectState('ai-account').phase,
          ShellOwnAiDirectPhase.unknown,
        );
        await runtime.loadOwnAiDirectConsent('ai-account');
        await _set(runtime, context: oldContext);
        expect(f.mutations, 0);
        final beforeSwitch = runtime.ownAiDirectContext!;
        await runtime.connectHost(
          f.native.origin,
          '',
          accountId: 'alice',
          password: 'synthetic-only',
          deviceName: 'new-device',
        );
        expect(
          runtime.ownAiDirectState('ai-account').phase,
          ShellOwnAiDirectPhase.unknown,
        );
        await runtime.loadOwnAi();
        await runtime.loadOwnAiDirectConsent('ai-account');
        await _set(runtime, context: beforeSwitch);
        expect(f.mutations, 0);
      } finally {
        await f.dispose(runtime);
      }
    },
  );

  test('logout drops late GET and all per-owner consent metadata', () async {
    final f = await _ConsentFixture.create();
    final runtime = await f.runtime();
    try {
      f.readStarted = Completer<void>();
      f.readRelease = Completer<void>();
      final work = runtime.loadOwnAiDirectConsent('ai-account');
      await f.readStarted!.future;
      await nativeLogout();
      f.readRelease!.complete();
      await work;
      expect(runtime.authenticated, false);
      expect(runtime.ownAiDirectContext, isNull);
      expect(
        runtime.ownAiDirectState('ai-account').phase,
        ShellOwnAiDirectPhase.unknown,
      );
      expect(f.mutations, 0);
    } finally {
      await f.dispose(runtime);
    }
  });

  test('failed transient load renewal preserves session but never reports consent off', () async {
    final f = await _ConsentFixture.create();
    final runtime = await f.runtime();
    try {
      await runtime.loadOwnAiDirectConsent('ai-account');
      f.readFailure = 401;
      await runtime.loadOwnAiDirectConsent('ai-account');
      expect(runtime.authenticated, true);
      expect(runtime.ownAiAccounts, hasLength(1));
      expect(runtime.ownAiDirectState('ai-account').enabled, isNull);
      expect(
        runtime.ownAiDirectState('ai-account').phase,
        isNot(ShellOwnAiDirectPhase.ready),
      );
    } finally {
      await f.dispose(runtime);
    }
  });
}
