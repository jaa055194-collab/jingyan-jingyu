import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/platform/native_platform.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'runtime_auth_test.dart' show Fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'picks one file, uploads all chunks, and sends one attachment message',
    () async {
      final host = await _AttachmentHost.start();
      final file = await host.makeFile('report.pdf', utf8.encode('0123456789'));
      await host.usePicker(file.path, name: 'report.pdf', temporary: true);
      final runtime = await host.open();
      await runtime.selectConversation('group');
      await runtime.setAiConsent(true);

      await runtime.attachFile('file');
      expect(runtime.selectedAttachmentName, 'report.pdf');
      expect(host.uploads, isEmpty);
      expect(host.messagePosts, 0);
      await runtime.sendSelectedAttachment();

      expect(runtime.error, isNull);
      expect(runtime.selectedAttachmentName, isNull);
      expect(host.uploads.single, {
        'mime': 'application/octet-stream',
        'size': 10,
        'kind': 'file',
        'conversationId': 'group',
      });
      expect(host.chunks, [
        utf8.encode('0123'),
        utf8.encode('4567'),
        utf8.encode('89'),
      ]);
      expect(host.submitted, {
        'clientMsgId': isA<String>(),
        'kind': 'file',
        'body': {'attachmentId': 'attachment-1', 'name': 'report.pdf'},
      });
      expect(host.messagePosts, 1);
      expect(host.allRequestBody, isNot(contains(file.path)));
      await runtime.refreshConversations();
      expect(runtime.messages.single.text, 'report.pdf');
      expect(
        await file.exists(),
        isFalse,
        reason: 'picker cache copy is deleted',
      );
    },
  );

  test('cancelled picker performs no upload or message write', () async {
    final host = await _AttachmentHost.start();
    await host.usePicker(null);
    final runtime = await host.open();
    await runtime.selectConversation('group');
    await runtime.setAiConsent(true);

    await runtime.attachFile('file');

    expect(runtime.error, isNull);
    expect(host.uploads, isEmpty);
    expect(host.messagePosts, 0);
    expect(runtime.queuedCount, 0);
  });

  test(
    'discarding a selected attachment releases its cache copy without upload',
    () async {
      final host = await _AttachmentHost.start();
      final file = await host.makeFile('report.pdf', [1, 2, 3]);
      await host.usePicker(file.path, name: 'report.pdf', temporary: true);
      final runtime = await host.open();
      await runtime.selectConversation('group');
      await runtime.setAiConsent(true);
      await runtime.attachFile('file');
      expect(runtime.selectedAttachmentName, 'report.pdf');
      expect(await file.exists(), isTrue);
      await runtime.discardSelectedAttachment();
      await runtime.sendSelectedAttachment();
      expect(runtime.selectedAttachmentName, isNull);
      expect(await file.exists(), isFalse);
      expect(host.uploads, isEmpty);
      expect(host.messagePosts, 0);
    },
  );

  test('unsupported image extension is rejected before HTTP', () async {
    final host = await _AttachmentHost.start();
    final file = await host.makeFile('not-an-image.txt', [1, 2, 3]);
    await host.usePicker(file.path, name: 'not-an-image.txt');
    final runtime = await host.open();
    await runtime.selectConversation('group');
    await runtime.setAiConsent(true);

    await runtime.attachFile('image');
    await runtime.sendSelectedAttachment();

    expect(runtime.error, contains('仅支持'));
    expect(host.uploads, isEmpty);
    expect(host.messagePosts, 0);
  });

  test('conversation change while picker is open sends nothing', () async {
    final host = await _AttachmentHost.start();
    final file = await host.makeFile('report.pdf', [1, 2, 3]);
    final picked = Completer<void>();
    final release = Completer<void>();
    await host.usePicker(
      file.path,
      name: 'report.pdf',
      beforeReturn: () async {
        picked.complete();
        await release.future;
      },
    );
    final runtime = await host.open();
    await runtime.selectConversation('group');
    await runtime.setAiConsent(true);

    final attaching = runtime.attachFile('file');
    await picked.future.timeout(const Duration(seconds: 5));
    await runtime.selectConversation('other');
    release.complete();
    await attaching;

    expect(host.uploads, isEmpty);
    expect(host.messagePosts, 0);
  });

  test(
    'upload failure aborts the pending upload and sends no message',
    () async {
      final host = await _AttachmentHost.start(failChunk: true);
      final file = await host.makeFile('report.pdf', [1, 2, 3, 4, 5]);
      await host.usePicker(file.path, name: 'report.pdf');
      final runtime = await host.open();
      await runtime.selectConversation('group');
      await runtime.setAiConsent(true);

      await runtime.attachFile('file');
      await runtime.sendSelectedAttachment();

      expect(runtime.error, contains('附件上传失败'));
      expect(host.abortedUploads, ['upload-1']);
      expect(host.messagePosts, 0);
      expect(runtime.queuedCount, 0);
    },
  );

  test(
    'switching chats during a chunk stops the upload before another write',
    () async {
      final host = await _AttachmentHost.start();
      final started = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      host.beforeChunkAck = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      final file = await host.makeFile('report.pdf', [1, 2, 3, 4, 5, 6]);
      await host.usePicker(file.path, name: 'report.pdf');
      final runtime = await host.open();
      await runtime.selectConversation('group');
      await runtime.setAiConsent(true);
      await runtime.attachFile('file');
      final sending = runtime.sendSelectedAttachment();
      await started.future.timeout(const Duration(seconds: 5));
      await runtime.selectConversation('other');
      await runtime.selectConversation('group');
      release.complete();
      await sending;
      expect(host.chunks, [
        [1, 2, 3, 4],
      ]);
      expect(host.completeCalls, 0);
      expect(host.abortedUploads, ['upload-1']);
      expect(host.messagePosts, 0);
      expect(runtime.selectedAttachmentName, isNull);
      expect(runtime.error, isNull);
    },
  );

  test('enqueue checkpoint failure deletes the completed attachment', () async {
    final host = await _AttachmentHost.start();
    final file = await host.makeFile('report.pdf', [1, 2, 3]);
    await host.usePicker(file.path, name: 'report.pdf');
    final runtime = await host.open();
    await runtime.selectConversation('group');
    await runtime.setAiConsent(true);
    final storage = _FailAfterInitializePersistence(runtime.storage);
    final shell = ClientShellController(
      persistence: storage,
      submit: (item) => runtime.connection!.submit(
        OutboxSubmission(item.conversationId, {
          'clientMsgId': item.clientMsgId,
          'kind': item.kind.wire,
          'body': item.body,
        }),
      ),
      requestSync: (_) async {},
    );
    await shell.initialize();
    storage.fail = true;
    runtime.shell = shell;

    await runtime.attachFile('file');
    await runtime.sendSelectedAttachment();

    expect(runtime.error, contains('附件消息保存失败'));
    expect(host.deletedAttachments, ['attachment-1']);
    expect(host.messagePosts, 0);
    expect(shell.outbox.items, isEmpty);
    expect(runtime.queuedCount, 0);
  });
}

class _AttachmentHost {
  _AttachmentHost(this.fixture, {this.failChunk = false});
  final Fixture fixture;
  final bool failChunk;
  final uploads = <Map<String, Object?>>[];
  final chunks = <List<int>>[];
  final submitted = <String, Object?>{};
  final abortedUploads = <String>[];
  final deletedAttachments = <String>[];
  final allRequests = <String>[];
  var messagePosts = 0;
  var completeCalls = 0;
  Future<void> Function()? beforeChunkAck;
  File? _picked;
  String _pickedName = '';
  bool _pickedTemporary = false;
  Future<void> Function()? _beforePick;

  String get allRequestBody => allRequests.join('\n');

  static Future<_AttachmentHost> start({bool failChunk = false}) async {
    final fixture = await Fixture.create();
    addTearDown(fixture.cleanup);
    fixture.secure = jsonEncode(fixture.session());
    final host = _AttachmentHost(fixture, failChunk: failChunk);
    fixture.serve = host.serve;
    return host;
  }

  Future<File> makeFile(String name, List<int> bytes) async {
    final file = File('${fixture.root.path}/$name');
    await file.writeAsBytes(bytes);
    _picked = file;
    _pickedName = name;
    return file;
  }

  Future<void> usePicker(
    String? path, {
    String name = '',
    bool temporary = false,
    Future<void> Function()? beforeReturn,
  }) async {
    _picked = path == null ? null : File(path);
    _pickedName = name;
    _pickedTemporary = temporary;
    _beforePick = beforeReturn;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(NativePlatform.channel, (call) async {
      if (call.method == 'pickAttachment') {
        await _beforePick?.call();
        final picked = _picked;
        if (picked == null) return null;
        return {
          'path': picked.path,
          'name': _pickedName,
          'temporary': _pickedTemporary,
        };
      }
      return switch (call.method) {
        'initialize' => <String, Object?>{},
        'getDataDirectory' => fixture.root.path,
        'readSession' => fixture.secure,
        'hasPin' => false,
        'storeSession' => null,
        'clearSession' => null,
        _ => null,
      };
    });
  }

  Future<ClientRuntime> open() async {
    final runtime = ClientRuntime();
    addTearDown(runtime.dispose);
    await runtime.initialize();
    runtime.reconnect?.cancel();
    await runtime.refreshConversations();
    expect(runtime.authenticated, isTrue);
    return runtime;
  }

  Future<void> serve(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    if (raw.isNotEmpty) allRequests.add(raw);
    if (request.method != 'GET' && request.method != 'HEAD') {
      // The synthetic attacker would need a real path; ensure no local path.
      expect(raw, isNot(contains(fixture.root.path)));
    }
    final path = request.uri.path;
    if (request.method == 'GET' && path == Routes.hostInfo) {
      return _reply(request, {'error': 'forbidden'}, 403);
    }
    if (request.method == 'GET' && path == Routes.conversations) {
      return _reply(request, {
        'conversations': [
          {'id': 'group', 'name': 'Group', 'ownerAccountId': 'alice'},
          {'id': 'other', 'name': 'Other', 'ownerAccountId': 'alice'},
        ],
      });
    }
    if (request.method == 'GET' && path == Routes.directConversations) {
      return _reply(request, {'conversations': []});
    }
    if (request.method == 'GET' && path.endsWith('/sync')) {
      return _reply(request, {
        'messages': messagePosts == 0
            ? []
            : [
                {
                  'conversationId': 'group',
                  'messageId': 'server-message',
                  'seq': 1,
                  'senderId': 'alice',
                  'kind': submitted['kind'],
                  'body': submitted['body'],
                  'sentAt': '2026-11-19T00:00:00Z',
                },
              ],
        'hasMore': false,
      });
    }
    if (request.method == 'POST' && path == Routes.attachmentUploads) {
      final body = jsonDecode(raw) as Map;
      uploads.add(body.cast<String, Object?>());
      return _reply(request, {'uploadId': 'upload-1', 'chunkSize': 4});
    }
    if (request.method == 'PUT' &&
        path.contains('/attachments/uploads/upload-1/chunks/')) {
      final index = int.parse(request.uri.pathSegments.last);
      final decoded = base64Decode(
        (jsonDecode(raw) as Map)['dataBase64'] as String,
      );
      if (failChunk) {
        return _reply(request, {'error': 'unavailable'}, 503);
      }
      chunks.add(decoded);
      await beforeChunkAck?.call();
      final total = chunks.fold<int>(0, (sum, chunk) => sum + chunk.length);
      return _reply(request, {'received': total, 'nextChunk': index + 1});
    }
    if (request.method == 'POST' && path.endsWith('/complete')) {
      completeCalls++;
      final bytes = chunks.fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      return _reply(request, {
        'id': 'attachment-1',
        'size': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
        'extractionStatus': 'unsupported',
      });
    }
    if (request.method == 'DELETE' &&
        path == Routes.attachmentUpload.replaceAll('{uploadId}', 'upload-1')) {
      abortedUploads.add('upload-1');
      return _reply(request, {'aborted': true});
    }
    if (request.method == 'DELETE' &&
        path ==
            Routes.attachment.replaceAll('{attachmentId}', 'attachment-1')) {
      deletedAttachments.add('attachment-1');
      return _reply(request, {'removed': true});
    }
    if (request.method == 'POST' &&
        path == '/api/v1/conversations/group/messages') {
      messagePosts++;
      submitted.addAll((jsonDecode(raw) as Map).cast<String, Object?>());
      return _reply(request, {
        'duplicate': false,
        'message': {
          'conversationId': 'group',
          'messageId': 'server-message',
          'seq': 1,
          'senderId': 'alice',
          'kind': submitted['kind'],
          'body': submitted['body'],
          'sentAt': '2026-11-19T00:00:00Z',
        },
      });
    }
    return _reply(request, {'error': 'not_found'}, 404);
  }

  Future<void> _reply(
    HttpRequest request,
    Map<String, Object?> body, [
    int status = 200,
  ]) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

class _FailAfterInitializePersistence implements ClientPersistence {
  _FailAfterInitializePersistence(this.delegate);
  final ClientPersistence delegate;
  bool fail = false;
  @override
  Future<Map<String, Object?>?> read() => delegate.read();
  @override
  Future<void> write(Map<String, Object?> snapshot) async {
    if (fail) throw StateError('injected checkpoint failure');
    await delegate.write(snapshot);
  }
}
