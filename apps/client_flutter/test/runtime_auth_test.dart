import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/data/account_snapshots.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

const channel = MethodChannel('jingyu/platform');

class Fixture {
  Fixture(this.root, this.server);
  final Directory root;
  final HttpServer server;
  String? secure;
  final events = <String>[];
  Future<void> Function(HttpRequest)? serve;
  Future<void> Function()? beforeStore;
  String get origin => 'http://127.0.0.1:${server.port}';
  Map<String, Object?> session({String access = 'old-access'}) => {
    'host': origin,
    'accountId': 'alice',
    'deviceId': 'phone',
    'accessToken': access,
    'refreshToken': 'old-refresh',
    'onboarded': true,
  };
  static Future<Fixture> create() async {
    final f = Fixture(
      await Directory.systemTemp.createTemp('m11-runtime-auth-'),
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'initialize':
              return <String, Object?>{};
            case 'getDataDirectory':
              return f.root.path;
            case 'readSession':
              return f.secure;
            case 'hasPin':
              return false;
            case 'storeSession':
              await f.beforeStore?.call();
              f.secure = (call.arguments as Map)['json'] as String;
              f.events.add('store');
              return null;
            case 'clearSession':
              f.secure = null;
              f.events.add('clear');
              return null;
            default:
              return null;
          }
        });
    f.server.listen((request) async {
      if (f.serve != null) {
        await f.serve!(request);
        return;
      }
      await request.drain<void>();
      if (request.uri.path.endsWith('/auth/login')) {
        await f.reply(request, {
          'deviceId': 'phone',
          'accessToken': 'access-secret',
          'refreshToken': 'refresh-secret',
        });
      } else if (request.uri.path.endsWith('/host')) {
        await f.reply(request, {'error': 'forbidden'}, status: 403);
      } else {
        await f.reply(request, {'conversations': []});
      }
    });
    return f;
  }

  Future<void> reply(
    HttpRequest r,
    Map<String, Object?> body, {
    int status = 200,
  }) async {
    r.response.statusCode = status;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(body));
    await r.response.close();
  }

  Future<void> cleanup() async {
    await server.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  }
}

Future<void> nativeLogout() async {
  final done = Completer<void>();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        'jingyu/platform',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('event', {'type': 'logout'}),
        ),
        (_) => done.complete(),
      );
  await done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test('existing login stores protected identity and leaves legacy outbox untouched', () async {
    final f = await Fixture.create();
    final legacy = File('${f.root.path}/client.json');
    await legacy.writeAsString('{"legacySecret":"private queued data"}');
    final runtime = ClientRuntime();
    try {
      await runtime.initialize();
      await runtime.connectHost(
        f.origin,
        '',
        accountId: 'alice',
        password: 'password-not-stored',
        deviceName: 'desktop',
      );
      expect(runtime.error, isNull);
      expect(runtime.online, isTrue);
      expect(runtime.queuedCount, 0);
      expect(jsonDecode(f.secure!)['accountId'], 'alice');
      expect(
        await legacy.readAsString(),
        '{"legacySecret":"private queued data"}',
      );
      for (final file in f.root.listSync(recursive: true).whereType<File>()) {
        final body = await file.readAsString();
        expect(body, isNot(contains('password-not-stored')));
        expect(body, isNot(contains('access-secret')));
      }
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });
  test(
    'legacy application lock settings migrate without private messages',
    () async {
      final f = await Fixture.create();
      await File('${f.root.path}/client.json').writeAsString(
        jsonEncode({
          'appLock': {'enabled': true, 'hideNotificationBody': true},
          'shell': {
            'drafts': {'x': 'private'},
          },
        }),
      );
      final runtime = ClientRuntime();
      try {
        await runtime.initialize();
        expect(runtime.locked, isTrue);
        expect(runtime.hideNotificationBody, isTrue);
        expect(runtime.queuedCount, 0);
        expect(
          await File('${f.root.path}/settings.json').readAsString(),
          isNot(contains('private')),
        );
      } finally {
        runtime.dispose();
        await f.cleanup();
      }
    },
  );
  test(
    'logout cancels login response and prevents credentials resurrection',
    () async {
      final f = await Fixture.create();
      final started = Completer<void>();
      final release = Completer<void>();
      f.serve = (r) async {
        await r.drain<void>();
        if (!started.isCompleted) started.complete();
        await release.future;
        await f.reply(r, {
          'deviceId': 'phone',
          'accessToken': 'new-access',
          'refreshToken': 'new-refresh',
        });
      };
      final runtime = ClientRuntime();
      try {
        await runtime.initialize();
        final login = runtime.connectHost(
          f.origin,
          '',
          accountId: 'alice',
          password: 'pw',
          deviceName: 'pc',
        );
        await started.future;
        await nativeLogout();
        release.complete();
        await login;
        expect(f.secure, isNull);
        expect(runtime.connection, isNull);
        expect(runtime.online, isFalse);
      } finally {
        runtime.dispose();
        await f.cleanup();
      }
    },
  );
  test(
    'logout clear is ordered after pending protected-session store',
    () async {
      final f = await Fixture.create();
      final storing = Completer<void>();
      final release = Completer<void>();
      f.beforeStore = () async {
        storing.complete();
        await release.future;
      };
      final runtime = ClientRuntime();
      try {
        await runtime.initialize();
        final login = runtime.connectHost(
          f.origin,
          '',
          accountId: 'alice',
          password: 'pw',
          deviceName: 'pc',
        );
        await storing.future;
        final logout = nativeLogout();
        release.complete();
        await Future.wait([login, logout]);
        expect(f.secure, isNull);
        expect(f.events.last, 'clear');
        expect(runtime.connection, isNull);
      } finally {
        runtime.dispose();
        await f.cleanup();
      }
    },
  );
  test('corrupt destination fails before protected-session mutation', () async {
    final f = await Fixture.create();
    final snapshot = await AccountSnapshots(f.root)
        .open(Uri.parse(f.origin), 'alice', 'phone');
    await snapshot.file.writeAsString('{bad');
    final runtime = ClientRuntime();
    try {
      await runtime.initialize();
      await runtime.connectHost(
        f.origin,
        '',
        accountId: 'alice',
        password: 'pw',
        deviceName: 'pc',
      );
      expect(runtime.error, isNotNull);
      expect(f.secure, isNull);
      expect(f.events, isNot(contains('store')));
      expect(runtime.connection, isNull);
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });
  test('secure storage failure leaves identity inactive and previous protected state unchanged', () async {
    final f = await Fixture.create();
    f.beforeStore = () async {
      throw PlatformException(code: 'store_failed');
    };
    final runtime = ClientRuntime();
    try {
      await runtime.initialize();
      await runtime.connectHost(
        f.origin,
        '',
        accountId: 'alice',
        password: 'pw',
        deviceName: 'pc',
      );
      expect(runtime.error, isNotNull);
      expect(f.secure, isNull);
      expect(runtime.connection, isNull);
      expect(runtime.connectedAccountId, isNull);
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });
  test('transient rotation store failure retries the same pair without refreshing invalidated token', () async {
    final f=await Fixture.create();f.secure=jsonEncode(f.session());final listed=Completer<void>();var refreshes=0,stores=0;final sent=<String>[];
    f.beforeStore=()async{stores++;if(stores==1)throw PlatformException(code:'temporary_store_failure');};
    f.serve=(r)async{final path=r.uri.path;final text=await utf8.decoder.bind(r).join();
      if(path.endsWith('/auth/refresh')){refreshes++;if(refreshes==1){await f.reply(r,{'deviceId':'phone','accessToken':'rotated-access','refreshToken':'rotated-refresh'});}else{await f.reply(r,{'error':'unauthenticated'},status:401);}return;}
      if(path.endsWith('/messages')){
        if(r.headers.value(HttpHeaders.authorizationHeader)=='Bearer rotated-access'){sent.add((jsonDecode(text) as Map)['clientMsgId'] as String);await f.reply(r,{});}else{await f.reply(r,{'error':'unauthenticated'},status:401);}return;
      }
      if(path.endsWith('/host')){await f.reply(r,{'error':'forbidden'},status:403);}else{await f.reply(r,{'conversations':[]});if(path.endsWith('/direct-conversations')&&!listed.isCompleted)listed.complete();}
    };
    final runtime=ClientRuntime();try{await runtime.initialize();await listed.future.timeout(const Duration(seconds:5));final id=await runtime.shell.enqueue('conversation-a',MessageKind.text,{'text':'private'});
      expect((await runtime.shell.flush()).remaining,1);
      expect((await runtime.shell.flush()).remaining,0);
      expect(refreshes,1);expect(stores,2);expect(sent,[id]);expect(f.secure,contains('rotated-refresh'));
    }finally{runtime.dispose();await f.cleanup();}
  });
  test('failed token refresh preserves outbox id instead of dropping private message', () async {
    final f = await Fixture.create();
    f.secure = jsonEncode(f.session());
    final listed = Completer<void>();
    f.serve = (r) async {
      final path = r.uri.path;
      await r.drain<void>();
      if (path.endsWith('/auth/refresh') || path.endsWith('/messages')) {
        await f.reply(r, {'error': 'unauthenticated'}, status: 401);
      } else if (path.endsWith('/host')) {
        await f.reply(r, {'error': 'forbidden'}, status: 403);
      } else {
        await f.reply(r, {'conversations': []});
        if (path.endsWith('/direct-conversations') && !listed.isCompleted) {
          listed.complete();
        }
      }
    };
    final runtime = ClientRuntime();
    try {
      await runtime.initialize();
      await listed.future.timeout(const Duration(seconds: 5));
      final id = await runtime.shell.enqueue(
        'conversation-a',
        MessageKind.text,
        {'text': 'private'},
      );
      final report = await runtime.shell.flush();
      expect(report.remaining, 1);
      expect(runtime.shell.outbox.items.single.clientMsgId, id);
      expect(runtime.shell.dropped, isEmpty);
    } finally {
      runtime.dispose();
      await f.cleanup();
    }
  });
  test(
    'expired access refreshes once on same device and saves before retry',
    () async {
      final f = await Fixture.create();
      f.secure = jsonEncode(f.session());
      final ready = Completer<void>();
      var renewals = 0;
      f.serve = (r) async {
        final path = r.uri.path;
        await r.drain<void>();
        if (path.endsWith('/auth/refresh')) {
          renewals++;
          await f.reply(r, {
            'deviceId': 'phone',
            'accessToken': 'rotated-access',
            'refreshToken': 'rotated-refresh',
          });
          return;
        }
        if (r.headers.value(HttpHeaders.authorizationHeader) ==
            'Bearer old-access') {
          await f.reply(r, {'error': 'unauthenticated'}, status: 401);
          return;
        }
        expect(f.secure, contains('rotated-access'));
        if (path.endsWith('/host')) {
          await f.reply(r, {'error': 'forbidden'}, status: 403);
        } else {
          await f.reply(r, {'conversations': []});
          if (!ready.isCompleted) ready.complete();
        }
      };
      final runtime = ClientRuntime();
      try {
        await runtime.initialize();
        await ready.future.timeout(const Duration(seconds: 5));
        expect(renewals, 1);
        expect(jsonDecode(f.secure!)['deviceId'], 'phone');
      } finally {
        runtime.dispose();
        await f.cleanup();
      }
    },
  );
}
