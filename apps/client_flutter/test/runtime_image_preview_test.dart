import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'runtime_auth_test.dart' show Fixture, channel;

/// Minimal image fixture used by the runtime preview tests.
const _pngBytes = <int>[
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
  0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, //
  0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, //
  1, 13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130, //
];

class _ImageFixture {
  _ImageFixture(this.fixture);
  final Fixture fixture;
  final runtime = ClientRuntime();
  int contentRequests = 0;
  Completer<void>? gate;
  int status = 200;

  static Future<_ImageFixture> create() async {
    final fixture = await Fixture.create();
    final f = _ImageFixture(fixture);
    addTearDown(() async {
      f.runtime.dispose();
      await fixture.cleanup();
    });
    fixture.secure = jsonEncode(fixture.session());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'initialize':
              return {'platform': 'android'};
            case 'getDataDirectory':
              return fixture.root.path;
            case 'readSession':
              return fixture.secure;
            case 'hasPin':
              return false;
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
      if (request.uri.path.endsWith('/attachment')) {
        f.contentRequests++;
        final gate = f.gate;
        if (gate != null) await gate.future;
        if (f.status != 200) {
          await fixture.reply(request, {'error': 'not_found'}, status: 404);
          return;
        }
        await fixture.reply(request, {
          'mime': 'image/png',
          'size': _pngBytes.length,
          'sha256': 'placeholder',
          'dataBase64': base64Encode(_pngBytes),
        });
        return;
      }
      if (request.uri.path == Routes.conversations) {
        await fixture.reply(request, {
          'conversations': [
            {'id': 'group', 'name': 'Group'},
          ],
        });
        return;
      }
      if (request.uri.path.contains('/sync')) {
        await fixture.reply(request, {
          'messages': [
            {
              'conversationId': 'group',
              'seq': 1,
              'messageId': 'message-image',
              'senderId': 'alice',
              'kind': 'image',
              'body': {'attachmentId': 'attachment-1', 'name': 'report.png'},
              'sentAt': '2026-11-20T00:00:00.000Z',
            },
          ],
          'hasMore': false,
        });
        return;
      }
      await fixture.reply(request, {'conversations': [], 'messages': []});
    };
    return f;
  }

  Future<void> open() async {
    await runtime.initialize();
    runtime.reconnect?.cancel();
    await runtime.refreshConversations();
    // Image previews do not depend on unread state. Start in an already-read
    // chat so the runtime's background read checkpoint cannot race fixture
    // deletion on Windows after the last preview assertion.
    await runtime.shell.markRead('group', runtime.shell.lastSeqFor('group'));
    await runtime.selectConversation('group');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'canonical image message exposes a ref without fetching bytes',
    () async {
      final f = await _ImageFixture.create();
      await f.open();

      final message = f.runtime.messages.single;
      expect(message.imageAttachment, isTrue);
      expect(message.attachmentId, 'attachment-1');
      expect(message.attachmentName, 'report.png');
      expect(f.contentRequests, 0);
    },
  );

  test(
    'explicit open fetches once and a stale lock discards the result',
    () async {
      final f = await _ImageFixture.create();
      await f.open();
      f.gate = Completer<void>();
      final pending = f.runtime.openImageAttachment('message-image');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await f.runtime.setAppLock(true, '1234');
      await _nativeLock();
      f.gate!.complete();
      expect(await pending, isNull);
      expect(f.contentRequests, 1);
    },
  );

  test('non-image and unavailable content never returns an image', () async {
    final f = await _ImageFixture.create();
    await f.open();
    expect(await f.runtime.openImageAttachment('unknown-message'), isNull);
    expect(f.contentRequests, 0);
    f.status = 404;
    expect(await f.runtime.openImageAttachment('message-image'), isNull);
    expect(f.contentRequests, 1);
  });
}

Future<void> _nativeLock() async {
  const codec = StandardMethodCodec();
  final done = Completer<void>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(const MethodCall('event', {'type': 'lock'})),
        (_) => done.complete(),
      );
  await done.future;
}
