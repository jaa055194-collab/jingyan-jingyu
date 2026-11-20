import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'runtime_auth_test.dart' show Fixture, channel;

Future<void> _native(String method, Object? payload) async {
  const codec = StandardMethodCodec();
  final done = Completer<void>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(MethodCall(method, payload)),
        (reply) {
          try {
            if (reply != null) codec.decodeEnvelope(reply);
            done.complete();
          } catch (error, stack) {
            done.completeError(error, stack);
          }
        },
      );
  await done.future;
}

class _ShareFixture {
  _ShareFixture(this.fixture);
  final Fixture fixture;
  final runtime = ClientRuntime();
  Object? coldShare;
  Future<void> Function()? duringInitialize;
  Future<void> Function()? duringReadSession;
  int submissions = 0;
  bool visible = true;

  static Future<_ShareFixture> create({bool authenticated = true}) async {
    final fixture = await Fixture.create();
    final f = _ShareFixture(fixture);
    addTearDown(() async {
      f.runtime.dispose();
      await fixture.cleanup();
    });
    if (authenticated) fixture.secure = jsonEncode(fixture.session());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'initialize':
              await f.duringInitialize?.call();
              return {
                'platform': 'android',
                'notificationPermission': true,
                'biometricAvailable': false,
                'pendingShare': f.coldShare,
              };
            case 'getDataDirectory':
              return fixture.root.path;
            case 'readSession':
              await f.duringReadSession?.call();
              return fixture.secure;
            case 'configurePin':
            case 'unlockPin':
              return true;
            case 'storeSession':
              fixture.secure =
                  (call.arguments as Map<Object?, Object?>)['json'] as String;
              return null;
            case 'clearSession':
              fixture.secure = null;
              return null;
            default:
              return null;
          }
        });
    fixture.serve = (request) async {
      await request.drain<void>();
      if (request.method == 'POST' && request.uri.path.endsWith('/messages')) {
        f.submissions++;
      }
      await fixture.reply(request, switch (request.uri.path) {
        Routes.conversations => {
          'conversations': [
            {'id': 'current', 'name': 'Current'},
            if (f.visible) {'id': 'target', 'name': 'Target'},
          ],
        },
        Routes.authLogin => {
          'deviceId': 'phone',
          'accessToken': 'other-access',
          'refreshToken': 'other-refresh',
        },
        _ => {'conversations': [], 'messages': [], 'hasMore': false},
      });
    };
    return f;
  }

  Future<void> open() async {
    await runtime.initialize();
    await runtime.refreshConversations();
  }

  Future<void> share(Object? payload) => _native('shareReceived', payload);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'cold share can be explicitly placed in an empty different chat',
    () async {
      final f = await _ShareFixture.create();
      f.coldShare = {
        'text': '  cold share\n',
        'mimeType': 'text/plain',
        'uris': [],
      };
      await f.open();
      final runtime = f.runtime;
      await runtime.selectConversation('current');
      runtime.updateDraft('keep my current draft');

      expect(runtime.incomingSharedText?.text, '  cold share\n');
      final token = runtime.shareInteractionContext!;
      expect(
        await runtime.useSharedTextInDraft(
          'current',
          interactionContext: token,
        ),
        isFalse,
      );
      expect(runtime.incomingSharedText?.text, '  cold share\n');
      expect(
        await runtime.useSharedTextInDraft('target', interactionContext: token),
        isTrue,
      );
      expect(runtime.incomingSharedText, isNull);
      expect(runtime.selectedConversationId, 'target');
      expect(runtime.draft, '  cold share\n');
      expect(runtime.shell.draftFor('current'), 'keep my current draft');
      expect(runtime.shell.draftFor('target'), '  cold share\n');
      expect(runtime.queuedCount, 0);
      expect(f.submissions, 0);
    },
  );

  test('warm event while initialize awaits wins over later delivery', () async {
    final f = await _ShareFixture.create();
    f.coldShare = {'text': 'later delivery'};
    f.duringInitialize = () => f.share({'text': 'first delivery'});
    await f.open();
    expect(f.runtime.incomingSharedText?.text, 'first delivery');
    final before = f.runtime.shareInteractionContext;
    await f.share({'text': 'third delivery'});
    expect(f.runtime.incomingSharedText?.text, 'first delivery');
    expect(f.runtime.shareInteractionContext, same(before));
    expect(f.runtime.incomingShareNotice, isNotNull);
    expect(f.runtime.draft, isEmpty);
    expect(
      jsonEncode(await f.runtime.storage.read()),
      isNot(contains('first delivery')),
    );
  });

  test(
    'invalid content leaves the draft unchanged and exposes only a notice',
    () async {
      final f = await _ShareFixture.create();
      await f.open();
      final runtime = f.runtime;
      await runtime.shell.saveDraft('current', 'original');
      await runtime.selectConversation('current');
      final before = await runtime.storage.read();
      for (final payload in <Object?>[
        ['not a map'],
        {'text': 123},
        {'text': ' ', 'subject': 'secret subject'},
        {'mimeType': 'text/html', 'text': 'private payload'},
        {
          'uris': ['content://private'],
          'text': 'private payload',
        },
        {'uris': '[]', 'text': 'private payload'},
        {'text': '你' * 21846},
      ]) {
        await f.share(payload);
        expect(runtime.incomingSharedText, isNull);
        expect(runtime.shareInteractionContext, isNull);
        expect(runtime.incomingShareNotice, isNotNull);
        expect(runtime.incomingShareNotice, isNot(contains('private')));
      }
      expect(runtime.draft, 'original');
      expect(await runtime.storage.read(), before);
    },
  );

  test('a stale confirmation cannot assign a replacement share', () async {
    final f = await _ShareFixture.create();
    await f.open();
    final runtime = f.runtime;
    await f.share({'text': 'old'});
    final stale = runtime.shareInteractionContext!;
    await runtime.discardSharedText();
    await f.share({'text': 'new'});
    expect(
      await runtime.useSharedTextInDraft('target', interactionContext: stale),
      isFalse,
    );
    expect(runtime.incomingSharedText?.text, 'new');
    expect(runtime.shell.draftFor('target'), isEmpty);
  });

  test('startup guest share does not cross a later login', () async {
    final f = await _ShareFixture.create(authenticated: false);
    f.coldShare = {'text': 'guest share'};
    await f.open();
    expect(f.runtime.incomingSharedText, isNull);
    await f.share({'text': 'another guest share'});
    await f.runtime.connectHost(
      f.fixture.origin,
      '',
      accountId: 'bob',
      password: 'synthetic',
      deviceName: 'phone',
    );
    expect(f.runtime.connectedAccountId, 'bob');
    expect(f.runtime.incomingSharedText, isNull);
    expect(f.runtime.incomingShareNotice, isNull);
  });

  test(
    'logout while session restore is suspended cannot publish old account',
    () async {
      final f = await _ShareFixture.create();
      final readStarted = Completer<void>();
      final releaseRead = Completer<void>();
      f.duringReadSession = () async {
        readStarted.complete();
        await releaseRead.future;
      };
      final opening = f.open();
      await readStarted.future;
      await f.share({'text': 'untrusted startup share'});
      await _native('event', {'type': 'logout'});
      releaseRead.complete();
      await opening;

      expect(f.runtime.authenticated, isFalse);
      expect(f.runtime.connectedAccountId, isNull);
      expect(f.runtime.incomingSharedText, isNull);
      expect(f.fixture.secure, isNull);
      expect(
        f.runtime.storage,
        isNotNull,
        reason: 'guest shell is safe to publish',
      );
    },
  );

  test(
    'draft edit after a share confirmation context invalidates that context',
    () async {
      final f = await _ShareFixture.create();
      await f.open();
      await f.runtime.selectConversation('target');
      await f.share({'text': 'pending text'});
      final token = f.runtime.shareInteractionContext!;
      f.runtime.updateDraft('typed while deciding');
      await f.runtime.shell.saveDraft('target', 'typed while deciding');
      final before = await f.runtime.storage.read();

      expect(
        await f.runtime.useSharedTextInDraft(
          'target',
          interactionContext: token,
        ),
        isFalse,
      );
      expect(f.runtime.incomingSharedText?.text, 'pending text');
      expect(f.runtime.draft, 'typed while deciding');
      expect(await f.runtime.storage.read(), before);
    },
  );

  test(
    'lock invalidates an old share confirmation and hides its preview',
    () async {
      final f = await _ShareFixture.create();
      await f.open();
      await f.runtime.setAppLock(true, '1234');
      await f.share({'text': 'hidden while locked'});
      final token = f.runtime.shareInteractionContext!;

      await _native('event', {'type': 'lock'});

      expect(f.runtime.locked, isTrue);
      expect(f.runtime.incomingSharedText, isNull);
      expect(f.runtime.shareInteractionContext, isNull);
      expect(
        await f.runtime.useSharedTextInDraft(
          'target',
          interactionContext: token,
        ),
        isFalse,
      );
      expect(f.runtime.shell.draftFor('target'), isEmpty);
      expect(f.submissions, 0);
    },
  );

  test('warm share leaves the selected draft and snapshot untouched', () async {
    final f = await _ShareFixture.create();
    await f.open();
    await f.runtime.shell.saveDraft('current', 'original unsent draft');
    await f.runtime.selectConversation('current');
    final before = await f.runtime.storage.read();

    await f.share({'text': 'incoming synthetic share'});

    expect(f.runtime.draft, 'original unsent draft');
    expect(await f.runtime.storage.read(), before);
    expect(f.runtime.queuedCount, 0);
    expect(f.submissions, 0);
  });
}
