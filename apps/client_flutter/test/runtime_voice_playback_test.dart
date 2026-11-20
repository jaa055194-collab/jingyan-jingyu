import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/chat/chat_pane.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'runtime_auth_test.dart' show Fixture, channel, nativeLogout;
import 'voice_message_api_test.dart' show voiceResponse, voiceSilence;

class _ObservedRuntime extends ClientRuntime {
  Future<void>? lastPlay;

  @override
  Future<void> playVoiceMessage(
    String messageId, {
    required bool Function() viewIsCurrent,
    Future<void> Function()? waitForView,
  }) => lastPlay = super.playVoiceMessage(
    messageId,
    viewIsCurrent: viewIsCurrent,
    waitForView: waitForView,
  );
}

class _Fixture {
  _Fixture(this.host);

  final Fixture host;
  final mediaArrived = Completer<void>();
  final mediaAnswered = Completer<void>();
  final runtime = _ObservedRuntime();
  final mediaRequests = <String>[];
  final nativeCalls = <MethodCall>[];
  int renewals = 0;
  int status = 200;
  Completer<void>? mediaGate;
  Completer<bool>? nativeStart;
  final startArrived = Completer<void>();
  final readReceipt = Completer<void>();
  Map<String, Object?> response = voiceResponse();
  int historyFloor = 1;
  bool _disposed = false;

  static Future<_Fixture> open({String platform = 'android'}) async {
    final host = await Fixture.create();
    final f = _Fixture(host);
    addTearDown(() async {
      f.dispose();
      await host.cleanup();
    });
    host.secure = jsonEncode(host.session());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'initialize':
              return {
                'platform': platform,
                'voicePlaybackEpoch': 7,
                'voicePlaybackResumed': true,
              };
            case 'getDataDirectory':
              return host.root.path;
            case 'readSession':
              return host.secure;
            case 'hasPin':
              return false;
            case 'configurePin':
            case 'unlockPin':
              return true;
            case 'clearSession':
              host.secure = null;
              return null;
            case 'playVoiceMessage':
              f.nativeCalls.add(call);
              if (!f.startArrived.isCompleted) f.startArrived.complete();
              return f.nativeStart == null ? true : await f.nativeStart!.future;
            case 'stopVoiceMessage':
              f.nativeCalls.add(call);
              return null;
            default:
              return null;
          }
        });
    host.serve = f.respond;
    await f.runtime.initialize();
    f.runtime.reconnect?.cancel();
    f.runtime.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await f.runtime.refreshConversations();
    await f.runtime.selectConversation('group');
    // Selection intentionally returns before the durable read checkpoint.
    await f.readReceipt.future.timeout(const Duration(seconds: 5));
    expect(f.runtime.authenticated, isTrue);
    expect(f.runtime.online, isTrue);
    return f;
  }

  Future<void> respond(HttpRequest request) async {
    await request.drain<void>();
    final path = request.uri.path;
    if (path.endsWith('/voice-attachment')) {
      mediaRequests.add(path);
      if (!mediaArrived.isCompleted) mediaArrived.complete();
      await mediaGate?.future;
      try {
        await host.reply(
          request,
          status == 200
              ? response
              : {'error': status == 401 ? 'unauthenticated' : 'not_found'},
          status: status,
        );
      } on HttpException {
        // Navigation/lock can close the read before the fixture replies.
      } on SocketException {
        // Same as above.
      } finally {
        if (!mediaAnswered.isCompleted) mediaAnswered.complete();
      }
    } else if (path.endsWith('/auth/refresh')) {
      renewals++;
      await host.reply(request, {'error': 'unauthenticated'}, status: 401);
    } else if (path == '/api/v1/conversations/group/ack') {
      await host.reply(request, {'acknowledgedSeq': 5});
      if (!readReceipt.isCompleted) readReceipt.complete();
    } else if (path == Routes.conversations) {
      await host.reply(request, {
        'conversations': [
          {'id': 'group', 'name': 'Voice fixture'},
          {'id': 'other', 'name': 'Other conversation'},
        ],
      });
    } else if (path.endsWith('/group/sync')) {
      final after = int.parse(request.uri.queryParameters['afterSeq']!);
      final rows = [
        (1, 'voice-one', 'audio', {'attachmentId': 'voice-asset'}),
        (
          2,
          'recalled',
          'audio',
          {'attachmentId': 'recalled-asset', 'recalled': true},
        ),
        (3, 'no-asset', 'audio', <String, Object?>{}),
        (4, 'file', 'file', {'attachmentId': 'file-asset'}),
        (5, 'voice-two', 'audio', {'attachmentId': 'voice-asset-two'}),
      ];
      await host.reply(request, {
        'firstVisibleSeq': historyFloor,
        'messages': [
          for (final (seq, id, kind, body) in rows)
            if (seq > after && seq >= historyFloor)
              {
                'conversationId': 'group',
                'seq': seq,
                'messageId': id,
                'senderId': 'member',
                'kind': kind,
                'body': body,
                'sentAt': '2026-11-20T00:00:00.000Z',
              },
        ],
        'hasMore': false,
      });
    } else {
      await host.reply(request, {
        'conversations': [],
        'messages': [],
        'hasMore': false,
      });
    }
  }

  List<String> get methods => nativeCalls.map((call) => call.method).toList();
  Map<Object?, Object?> get lastArgs =>
      nativeCalls.last.arguments as Map<Object?, Object?>;

  Future<void> play([String id = 'voice-one']) =>
      runtime.playVoiceMessage(id, viewIsCurrent: () => true);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    runtime.dispose();
    if (mediaGate case final gate? when !gate.isCompleted) gate.complete();
    if (nativeStart case final gate? when !gate.isCompleted) {
      gate.complete(false);
    }
  }
}

Future<void> _native(MethodCall call) async {
  final done = Completer<void>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(call),
        (_) => done.complete(),
      );
  await done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('only canonical synced visible audio offers playback, without reading bytes', () async {
    final f = await _Fixture.open();
    final messages = f.runtime.messages;
    expect(messages.where((m) => m.voiceAttachment).map((m) => m.id), [
      'voice-one',
      'voice-two',
    ]);
    final queued = await f.runtime.shell.enqueue('group', MessageKind.audio, {
      'attachmentId': 'unsent-asset',
    });
    for (final id in ['recalled', 'no-asset', 'file', 'unknown', queued]) {
      await f.play(id);
    }
    expect(f.mediaRequests, isEmpty);
    expect(f.nativeCalls, isEmpty);
  });

  test('Windows cannot fetch or call the Android player', () async {
    final f = await _Fixture.open(platform: 'windows');
    expect(f.runtime.supportsVoicePlayback, isFalse);
    await f.play();
    expect(f.mediaRequests, isEmpty);
    expect(f.nativeCalls, isEmpty);
  });

  test(
    'explicit play first validates one read, then starts one native player',
    () async {
      final f = await _Fixture.open();
      f.mediaGate = Completer<void>();
      final started = f.play();
      await f.mediaArrived.future.timeout(const Duration(seconds: 5));
      expect(f.runtime.voicePlayback?.phase, ShellVoicePhase.loading);
      await f.play('voice-two');
      expect(f.mediaRequests, hasLength(1));
      expect(
        f.nativeCalls,
        isEmpty,
        reason: 'native start is after verified fetch',
      );
      f.mediaGate!.complete();
      await started;
      expect(f.methods, ['playVoiceMessage']);
      expect(
        f.mediaRequests.single,
        '/api/v1/conversations/group/messages/voice-one/voice-attachment',
      );
      final args = f.lastArgs;
      expect(args.keys, unorderedEquals(['requestId', 'epoch', 'bytes']));
      expect(args['epoch'], 7);
      expect(args['bytes'], orderedEquals(voiceSilence()));
      expect(f.runtime.voicePlayback?.phase, ShellVoicePhase.playing);
      f.runtime.stopVoicePlayback();
      expect(f.runtime.voicePlayback, isNull);
      expect(f.methods, ['playVoiceMessage', 'stopVoiceMessage']);
      expect(f.lastArgs, {'requestId': args['requestId']});
    },
  );

  for (final (status, phase) in [
    (401, ShellVoicePhase.denied),
    (403, ShellVoicePhase.denied),
    (404, ShellVoicePhase.denied),
    (503, ShellVoicePhase.unavailable),
    (200, ShellVoicePhase.unavailable),
  ]) {
    test(
      'HTTP $status or damaged bytes never invoke native playback',
      () async {
        final f = await _Fixture.open();
        f.status = status;
        f.response['sha256'] = '0' * 64;
        await f.play();
        expect(f.runtime.voicePlayback?.phase, phase);
        expect(f.mediaRequests, hasLength(1));
        expect(f.nativeCalls, isEmpty);
        expect(f.renewals, 0);
      },
    );
  }

  for (final interrupt in [
    'stop',
    'lock',
    'switch',
    'logout',
    'background',
    'dispose',
  ]) {
    test(
      '$interrupt cancels the fetching attempt without a native command',
      () async {
        final f = await _Fixture.open();
        if (interrupt == 'lock') await f.runtime.setAppLock(true, '1234');
        f.mediaGate = Completer<void>();
        final playing = f.play();
        await f.mediaArrived.future.timeout(const Duration(seconds: 5));
        switch (interrupt) {
          case 'stop':
            f.runtime.stopVoicePlayback();
          case 'lock':
            await _native(const MethodCall('event', {'type': 'lock'}));
            await f.runtime.unlock('1234');
          case 'switch':
            await f.runtime.selectConversation('other');
            await f.runtime.selectConversation('group');
          case 'logout':
            await nativeLogout();
          case 'background':
            f.runtime.didChangeAppLifecycleState(AppLifecycleState.inactive);
            f.runtime.didChangeAppLifecycleState(AppLifecycleState.resumed);
          case 'dispose':
            f.dispose();
        }
        // A suspended HTTP response must not keep the cancelled attempt alive.
        await playing.timeout(const Duration(seconds: 5));
        if (!f.mediaGate!.isCompleted) f.mediaGate!.complete();
        expect(f.runtime.voicePlayback, isNull);
        expect(f.nativeCalls, isEmpty);
        expect(f.renewals, 0);
      },
    );
  }

  test(
    'a background epoch invalidates late native prepare and old completion',
    () async {
      final f = await _Fixture.open();
      f.nativeStart = Completer<bool>();
      final pending = f.play();
      await f.startArrived.future.timeout(const Duration(seconds: 5));
      final firstId = f.lastArgs['requestId'];
      await _native(
        const MethodCall('voicePlaybackForeground', {
          'epoch': 8,
          'resumed': false,
        }),
      );
      expect(f.methods, ['playVoiceMessage', 'stopVoiceMessage']);
      expect(f.lastArgs, {'requestId': firstId});
      expect(f.runtime.voicePlayback, isNull);
      await _native(
        const MethodCall('voicePlaybackForeground', {
          'epoch': 9,
          'resumed': true,
        }),
      );
      f.nativeStart!.complete(true);
      await pending;
      expect(f.runtime.voicePlayback, isNull);
      await f.play('voice-two');
      final secondId = f.lastArgs['requestId'];
      expect(secondId, isNot(firstId));
      expect(f.lastArgs['epoch'], 9);
      await _native(
        MethodCall('voicePlaybackFinished', {
          'requestId': firstId,
          'failed': true,
        }),
      );
      expect(f.runtime.voicePlayback?.messageId, 'voice-two');
      expect(f.runtime.voicePlayback?.phase, ShellVoicePhase.playing);
      await _native(
        MethodCall('voicePlaybackFinished', {
          'requestId': secondId,
          'failed': false,
        }),
      );
      expect(f.runtime.voicePlayback, isNull);
    },
  );

  testWidgets(
    'leaving a real chat cancels its pending read before native play',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = (await tester.runAsync(_Fixture.open))!;
      await tester.pumpWidget(WhaleChatApp(model: f.runtime));
      await tester.tap(find.byKey(const ValueKey('group')));
      await tester.pumpAndSettle();

      final didFetch = await tester.runAsync(() async {
        // This gate is awaited by the real HTTP server, outside fake async.
        f.mediaGate = Completer<void>();
        await tester.tap(find.byKey(const Key('play-voice-voice-one')));
        await f.mediaArrived.future.timeout(const Duration(seconds: 5));
        return true;
      });
      expect(didFetch, isTrue, reason: 'the request reached the fixture');
      await tester.pumpAndSettle();
      expect(find.text('正在加载语音…'), findsOneWidget);
      expect(f.nativeCalls, isEmpty);

      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatPane), findsNothing);
      expect(f.runtime.voicePlayback, isNull);
      await tester.runAsync(() async {
        // Cancellation must complete without waiting for a host response.
        await f.runtime.lastPlay!.timeout(const Duration(seconds: 5));
        f.mediaGate!.complete();
        await f.mediaAnswered.future.timeout(const Duration(seconds: 5));
      });
      await tester.pumpAndSettle();

      expect(f.nativeCalls, isEmpty);
      expect(f.mediaRequests, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('host history floor removes eligibility and stops playing', () async {
    final f = await _Fixture.open();
    await f.play();
    expect(f.runtime.voicePlayback?.phase, ShellVoicePhase.playing);
    f.historyFloor = 2;
    await f.runtime.refreshConversations();
    expect(f.runtime.voicePlayback, isNull);
    expect(f.methods, ['playVoiceMessage', 'stopVoiceMessage']);
    await f.play();
    expect(f.mediaRequests, hasLength(1));
  });
}
