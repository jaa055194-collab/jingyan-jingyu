import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

const _members = ['host.sqlite', 'host.sqlite.kek'];
const _maxFixtureBytes = 8 * 1024 * 1024;
const _text = 'A synthetic message in the encrypted restore drill.';

void main() {
  test(
    'age restores the same encrypted SQLite message in a fresh directory',
    () async {
      final tools = _Tools.fromEnvironment();
      final parent = await Directory.systemTemp.resolveSymbolicLinks();
      final root = await Directory(parent).createTemp('jingyu-age-drill-');
      final ownedPath = await root.resolveSymbolicLinks();
      addTearDown(() async {
        if (await root.parent.resolveSymbolicLinks() != parent ||
            await root.resolveSymbolicLinks() != ownedPath ||
            !root.uri.pathSegments
                .where((part) => part.isNotEmpty)
                .last
                .startsWith('jingyu-age-drill-')) {
          throw StateError('Unexpected restore fixture cleanup directory');
        }
        await root.delete(recursive: true);
      });
      final source = await Directory('${root.path}/source').create();
      final random = Random.secure();
      final password = base64UrlEncode(
        List.generate(24, (_) => random.nextInt(256)),
      );
      final message = await _seed(source, password);

      // A cold snapshot of exactly two members. The wrapped database key is
      // DPAPI-protected; no raw key or WAL sidecar goes into the archive.
      final original = await _memberDigests(source);
      final tar = await tools.checked(
        tools.tar,
        ['-cf', '-', ..._members],
        'create fixture tar',
        directory: source,
      );
      // Use age's documented stdin identity path. Synthetic private keys stay
      // in memory and are never written to a file or passed as arguments.
      final identity = await tools.identity();
      addTearDown(() => identity.fillRange(0, identity.length, 0));
      final otherIdentity = await tools.identity();
      addTearDown(() => otherIdentity.fillRange(0, otherIdentity.length, 0));
      final recipient = await tools.recipient(identity);
      final encrypted = await tools.checked(
        tools.age,
        ['--encrypt', '--recipient', recipient],
        'encrypt fixture archive',
        input: tar,
      );
      final file = await File(
        '${root.path}/snapshot.tar.age',
      ).writeAsBytes(encrypted, flush: true);
      final expectedDigest = sha256.convert(encrypted).toString();
      final stored = await file.readAsBytes();
      expect(sha256.convert(stored).toString(), expectedDigest);
      final header = utf8.encode('age-encryption.org/v1\n');
      expect(stored.take(header.length), header);
      expect(_contains(stored, utf8.encode('SQLite format 3')), isFalse);
      expect(_contains(stored, utf8.encode(_text)), isFalse);
      expect(_contains(stored, utf8.encode(password)), isFalse);

      await expectLater(
        _unpackLocalSnapshot(tools, file, expectedDigest, identity, source),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Restore fixture requires a new directory',
          ),
        ),
      );
      final destination = Directory('${root.path}/restored');
      await expectLater(
        _unpackLocalSnapshot(
          tools,
          file,
          expectedDigest,
          otherIdentity,
          destination,
        ),
        throwsA(
          isA<_ToolRejected>().having(
            (error) => error.operation,
            'operation',
            'decrypt fixture archive',
          ),
        ),
      );
      expect(await destination.exists(), isFalse);
      final corrupted = Uint8List.fromList(stored);
      corrupted[corrupted.length - 1] ^= 1;
      final corruptFile = await File(
        '${root.path}/corrupt.tar.age',
      ).writeAsBytes(corrupted, flush: true);
      await expectLater(
        _unpackLocalSnapshot(
          tools,
          corruptFile,
          expectedDigest,
          identity,
          destination,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Fixture ciphertext digest mismatch',
          ),
        ),
      );
      expect(await destination.exists(), isFalse);
      // Even if the sidecar digest is recomputed, age must reject an altered
      // payload. Do not persist its partial decrypted stdout.
      await expectLater(
        _unpackLocalSnapshot(
          tools,
          corruptFile,
          sha256.convert(corrupted).toString(),
          identity,
          destination,
        ),
        throwsA(
          isA<_ToolRejected>().having(
            (error) => error.operation,
            'operation',
            'decrypt fixture archive',
          ),
        ),
      );
      expect(await destination.exists(), isFalse);

      await _unpackLocalSnapshot(
        tools,
        file,
        expectedDigest,
        identity,
        destination,
      );
      expect(await _memberDigests(destination), original);
      final host = await buildHost(
        config: HostConfig(dataDir: destination.path),
      );
      try {
        expect(
          await host.registry.services.get<Database>().integrityCheck(),
          'ok',
        );
        final login = await host.auth.login(
          AccountId.parse(message.senderId),
          password,
          deviceName: 'Restored synthetic client',
        );
        expect(login.isOk, isTrue, reason: 'the restored owner can sign in');
        final page = await host.pipeline.handle(
          HostRequest(
            method: 'GET',
            path: Routes.sync.replaceFirst(
              '{conversationId}',
              message.conversationId,
            ),
            headers: {'authorization': 'Bearer ${login.value.accessToken}'},
            query: const {'afterSeq': '0'},
          ),
        );
        expect(page.status, 200);
        expect((page.json as Map)['messages'], [message.toPayload()]);
      } finally {
        expect(await host.shutdown(), isEmpty);
      }
      expect(await _memberDigests(source), original);
    },
    skip:
        Platform.isWindows &&
            Platform.environment['JINGYU_RUN_AGE_RESTORE_DRILL'] == '1'
        ? false
        : 'requires Windows and the opt-in age restore fixture',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<StoredMessage> _seed(Directory directory, String password) async {
  final host = await buildHost(config: HostConfig(dataDir: directory.path));
  try {
    final owner = (await host.auth.bootstrapAdmin(
      displayName: 'Synthetic backup drill owner',
      password: password,
    )).value;
    final token = (await host.auth.login(
      owner,
      password,
      deviceName: 'Drill fixture',
    )).value.accessToken;
    final group = await host.pipeline.handle(
      HostRequest(
        method: 'POST',
        path: Routes.conversations,
        headers: {'authorization': 'Bearer $token'},
        body: const {
          'name': 'Synthetic restore drill',
          'historyVisibility': 'all',
        },
      ),
    );
    expect(group.status, 200);
    final id = (group.json as Map)['id'] as String;
    final store = host.registry.services.get<MessageStore>();
    final append = await store.append(
      conversationId: id,
      senderId: owner.value,
      clientMsgId: 'synthetic-source-message',
      kind: MessageKind.text,
      body: const {'text': _text},
    );
    expect(append.isOk, isTrue);
    final rows = await host.registry.services.get<Database>().query(
      'SELECT body FROM messages WHERE message_id=?',
      [append.value.message.messageId],
    );
    expect(rows.single['body'], startsWith('v1:'));
    expect(rows.single['body'], isNot(contains(_text)));
    return append.value.message;
  } finally {
    expect(await host.shutdown(), isEmpty);
  }
}

Future<List<String>> _memberDigests(Directory directory) async {
  expect(await File('${directory.path}/host.sqlite-wal').exists(), isFalse);
  return [
    for (final member in _members)
      (await sha256.bind(File('${directory.path}/$member').openRead()).single)
          .toString(),
  ];
}

/// Only decodes this test's own archive with a locally held digest. Not an
/// arbitrary restore/import entrypoint. tar only emits stdout, never paths.
Future<void> _unpackLocalSnapshot(
  _Tools tools,
  File ciphertext,
  String expectedDigest,
  Uint8List identity,
  Directory destination,
) async {
  if (await FileSystemEntity.type(destination.path) !=
      FileSystemEntityType.notFound) {
    throw StateError('Restore fixture requires a new directory');
  }
  final digest = await sha256.bind(ciphertext.openRead()).single;
  if (digest.toString() != expectedDigest) {
    throw StateError('Fixture ciphertext digest mismatch');
  }
  final archive = await tools.checked(
    tools.age,
    ['--decrypt', '--identity', '-', ciphertext.path],
    'decrypt fixture archive',
    input: identity,
  );
  final inventory = await tools.checked(
    tools.tar,
    ['-tf', '-'],
    'list fixture archive',
    input: archive,
  );
  expect(const LineSplitter().convert(utf8.decode(inventory)), _members);
  // Keep restored members in bounded memory until both reads succeed. No tar
  // extraction writes to disk, and no caller-supplied path or key is accepted.
  final members = <String, Uint8List>{};
  for (final name in _members) {
    final bytes = await tools.checked(
      tools.tar,
      ['-xOf', '-', '--', name],
      'read fixture archive member',
      input: archive,
    );
    expect(bytes.isNotEmpty, isTrue);
    members[name] = bytes;
  }
  await destination.create();
  for (final member in members.entries) {
    await File(
      '${destination.path}/${member.key}',
    ).writeAsBytes(member.value, flush: true);
  }
}

bool _contains(Uint8List bytes, List<int> needle) {
  for (var offset = 0; offset <= bytes.length - needle.length; offset++) {
    var index = 0;
    while (index < needle.length && bytes[offset + index] == needle[index]) {
      index++;
    }
    if (index == needle.length) return true;
  }
  return false;
}

class _ToolRejected implements Exception {
  const _ToolRejected(this.operation, this.exitCode);
  final String operation;
  final int exitCode;

  @override
  String toString() => '$operation exited with code $exitCode';
}

class _Tools {
  const _Tools(this.age, this.keygen, this.tar);
  final String age;
  final String keygen;
  final String tar;

  factory _Tools.fromEnvironment() {
    String read(String name) {
      final path = Platform.environment[name];
      if (path == null || !File(path).isAbsolute || !File(path).existsSync()) {
        throw StateError('Set $name to an absolute trusted executable path');
      }
      return path;
    }

    return _Tools(
      read('JINGYU_TEST_AGE'),
      read('JINGYU_TEST_AGE_KEYGEN'),
      read('JINGYU_TEST_TAR'),
    );
  }

  Future<Uint8List> identity() =>
      checked(keygen, const [], 'generate fixture identity');

  Future<String> recipient(Uint8List identity) async {
    final output = await checked(
      keygen,
      ['-y'],
      'derive fixture recipient',
      input: identity,
    );
    final recipient = utf8.decode(output).trim();
    if (!RegExp(r'^age1[0-9a-z]{58}$').hasMatch(recipient)) {
      throw StateError('Unexpected fixture recipient format');
    }
    return recipient;
  }

  Future<Uint8List> checked(
    String executable,
    List<String> arguments,
    String label, {
    Uint8List? input,
    Directory? directory,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: directory?.path,
      environment: {'SystemRoot': ?Platform.environment['SystemRoot']},
      includeParentEnvironment: false,
    );
    final output = BytesBuilder(copy: false);
    final finished = process.exitCode;
    final drain = process.stdout.forEach((chunk) {
      if (chunk.length > _maxFixtureBytes - output.length) {
        throw StateError('Fixture process returned too much data');
      }
      output.add(chunk);
    });
    // Both pipes are consumed concurrently, but raw diagnostics and generated
    // key material never reach the test log (even for an expected failure).
    final errors = process.stderr.drain<void>();
    final write = () async {
      if (input != null) process.stdin.add(input);
      try {
        await process.stdin.close();
      } on IOException {
        // A refused key/header can close stdin early. Its exit code below is
        // authoritative; any nonzero result discards the captured output.
      }
    }();
    try {
      await Future.wait<void>([
        drain,
        errors,
        write,
        finished.then((_) {}),
      ], eagerError: true).timeout(const Duration(seconds: 20));
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
      await finished.timeout(const Duration(seconds: 5));
      throw StateError('$label did not finish with valid fixture I/O');
    }
    final status = await finished;
    if (status != 0) throw _ToolRejected(label, status);
    return output.takeBytes();
  }
}
