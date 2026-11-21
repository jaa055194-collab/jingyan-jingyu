import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/owner_rule_greeting_api.dart';
import 'package:flutter_test/flutter_test.dart';

const _ai = 'profile-a';
const _settingsPath = '/api/v1/ai-profiles/profile-a/owner-rule-greeting';
const _globalPath = '/api/v1/accounts/me/owner-rule-greetings';

Map<String, Object?> payload({
  int revision = 0,
  bool enabled = false,
  int local = 540,
  int? offset,
  int quietStart = 1380,
  int quietEnd = 480,
  bool blocked = false,
  int globalRevision = 0,
  String? level = 'L3',
  int? chatRevision = 1,
  bool budget = true,
  String? lastSentAt,
}) => {
  'revision': revision,
  'enabled': enabled,
  'localMinute': local,
  'offsetMinutes': offset,
  'quietStartMinute': quietStart,
  'quietEndMinute': quietEnd,
  'globalBlocked': blocked,
  'globalRevision': globalRevision,
  'socialLevel': level,
  'chatRevision': chatRevision,
  'budgetReady': budget,
  'lastSentAt': lastSentAt,
};

OwnerRuleGreetingSettings currentSettings({
  int revision = 0,
  bool enabled = false,
  int local = 540,
  int? offset,
  int quietStart = 1380,
  int quietEnd = 480,
  bool blocked = false,
  int globalRevision = 0,
  String? level = 'L3',
  int? chatRevision = 1,
  bool budget = true,
}) => OwnerRuleGreetingSettings.fromJson(
  _ai,
  payload(
    revision: revision,
    enabled: enabled,
    local: local,
    offset: offset,
    quietStart: quietStart,
    quietEnd: quietEnd,
    blocked: blocked,
    globalRevision: globalRevision,
    level: level,
    chatRevision: chatRevision,
    budget: budget,
  ),
);

void main() {
  late HttpServer server;
  late StreamSubscription<HttpRequest> subscription;
  late HostConnection connection;
  late OwnerRuleGreetingApi api;
  Object? response;
  int status = 200;
  final requests = <(String method, String path, String raw)>[];

  setUp(() async {
    requests.clear();
    response = payload();
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'synthetic-token',
      onUnauthorized: () async =>
          fail('greeting mutation must not replay auth'),
    );
    api = OwnerRuleGreetingApi(connection);
    subscription = server.listen((request) async {
      requests.add((
        request.method,
        request.uri.path,
        await utf8.decoder.bind(request).join(),
      ));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
  });
  tearDown(() async {
    await connection.close();
    await subscription.cancel();
    await server.close(force: true);
  });

  test(
    'default schedule and global stop use distinct strict read routes',
    () async {
      final result = await api.readSettings(_ai);
      expect(result, isA<GreetingSettingsLoaded>());
      final state = (result as GreetingSettingsLoaded).state;
      expect(
        (state.revision, state.enabled, state.localMinute, state.offsetMinutes),
        (0, false, 540, null),
      );
      expect(
        (state.quietStartMinute, state.quietEndMinute, state.socialLevel),
        (1380, 480, 'L3'),
      );
      expect(
        (state.globalBlocked, state.globalRevision, state.budgetReady),
        (false, 0, true),
      );
      response = {'revision': 4, 'blocked': true};
      expect(await api.readGlobalStop(), isA<GlobalGreetingStopLoaded>());
      expect(requests.map((row) => row.$2), [_settingsPath, _globalPath]);
    },
  );

  test(
    'malformed schedule, gate and timestamp responses fail closed',
    () async {
      for (final invalid in [
        payload()..remove('budgetReady'),
        payload(revision: -1),
        payload(local: 1440),
        payload(offset: 841),
        payload(quietStart: 500, quietEnd: 500),
        payload(level: 'L9'),
        payload(enabled: true, offset: null),
        payload(enabled: true, offset: 480, blocked: true),
        payload(enabled: true, offset: 480, level: 'L2'),
        payload(enabled: true, offset: 480, chatRevision: null),
        payload(chatRevision: -1),
        payload(lastSentAt: '2026-11-99T12:00:00.000Z'),
        {...payload(), 'unexpected': true},
      ]) {
        response = invalid;
        expect(
          await api.readSettings(_ai),
          isA<GreetingUnavailable>(),
          reason: '$invalid',
        );
      }
      response = {'revision': 0, 'blocked': false, 'unexpected': true};
      expect(await api.readGlobalStop(), isA<GreetingUnavailable>());
    },
  );

  test(
    'enable sends exact settings and separate chat/global CAS revisions',
    () async {
      response = payload(
        revision: 1,
        enabled: true,
        local: 555,
        offset: 0,
        quietStart: 1320,
        quietEnd: 420,
      );
      final current = currentSettings();
      expect(
        await api.writeSettings(
          _ai,
          current: current,
          enabled: true,
          localMinute: 555,
          offsetMinutes: 0,
          quietStartMinute: 1320,
          quietEndMinute: 420,
        ),
        isA<GreetingSettingsWritten>(),
      );
      expect(requests.single.$1, 'PUT');
      expect(requests.single.$2, _settingsPath);
      expect(jsonDecode(requests.single.$3), {
        'expectedRevision': 0,
        'enabled': true,
        'localMinute': 555,
        'offsetMinutes': 0,
        'quietStartMinute': 1320,
        'quietEndMinute': 420,
        'expectedChatRevision': 1,
        'expectedGlobalRevision': 0,
      });
    },
  );

  test(
    'L0-L2, missing pair/budget and global stop refuse enabling preflight',
    () async {
      for (final current in [
        currentSettings(level: 'L0'),
        currentSettings(level: 'L1'),
        currentSettings(level: 'L2'),
        currentSettings(level: null),
        currentSettings(chatRevision: null),
        currentSettings(budget: false),
        currentSettings(blocked: true),
      ]) {
        final refused = await api.writeSettings(
          _ai,
          current: current,
          enabled: true,
          localMinute: 540,
          offsetMinutes: 0,
          quietStartMinute: 1380,
          quietEndMinute: 480,
        );
        expect(refused, isA<GreetingUnavailable>());
        expect(
          (refused as GreetingUnavailable).problem,
          GreetingProblem.refused,
        );
      }
      expect(requests, isEmpty);
    },
  );

  test(
    'daily target within wraparound quiet time is valid on a fixed offset',
    () async {
      response = payload(
        revision: 1,
        enabled: true,
        local: 90,
        offset: -420,
        quietStart: 1320,
        quietEnd: 120,
      );
      expect(
        await api.writeSettings(
          _ai,
          current: currentSettings(offset: 0),
          enabled: true,
          localMinute: 90,
          offsetMinutes: -420,
          quietStartMinute: 1320,
          quietEndMinute: 120,
        ),
        isA<GreetingSettingsWritten>(),
      );
      expect(jsonDecode(requests.single.$3), {
        'expectedRevision': 0,
        'enabled': true,
        'localMinute': 90,
        'offsetMinutes': -420,
        'quietStartMinute': 1320,
        'quietEndMinute': 120,
        'expectedChatRevision': 1,
        'expectedGlobalRevision': 0,
      });
      final count = requests.length;
      for (final (offset, start, end, local) in [
        (null, 1380, 480, 540),
        (841, 1380, 480, 540),
        (-841, 1380, 480, 540),
        (0, 777, 777, 540),
        (0, -1, 480, 540),
        (0, 1380, 1440, 540),
        (0, 1380, 480, 1440),
      ]) {
        expect(
          (await api.writeSettings(
            _ai,
            current: currentSettings(),
            enabled: true,
            localMinute: local,
            offsetMinutes: offset,
            quietStartMinute: start,
            quietEndMinute: end,
          ) as GreetingUnavailable).problem,
          GreetingProblem.refused,
        );
      }
      expect(
        requests.length,
        count,
        reason: 'invalid controls never reach host',
      );
    },
  );

  test(
    'off writes preserve schedule without live level, chat or budget gates',
    () async {
      response = payload(
        revision: 2,
        enabled: false,
        local: 600,
        offset: 480,
        level: null,
        chatRevision: null,
        budget: false,
      );
      expect(
        await api.writeSettings(
          _ai,
          current: currentSettings(
            revision: 1,
            local: 600,
            offset: 480,
            level: 'L2',
            chatRevision: null,
            budget: false,
          ),
          enabled: false,
          localMinute: 600,
          offsetMinutes: 480,
          quietStartMinute: 1380,
          quietEndMinute: 480,
        ),
        isA<GreetingSettingsWritten>(),
      );
      expect(jsonDecode(requests.single.$3), {
        'expectedRevision': 1,
        'enabled': false,
        'localMinute': 600,
        'offsetMinutes': 480,
        'quietStartMinute': 1380,
        'quietEndMinute': 480,
        'expectedChatRevision': null,
        'expectedGlobalRevision': null,
      });
    },
  );

  test(
    'budget outage leaves a readable enabled grant which can be revoked',
    () async {
      response = payload(
        revision: 2,
        enabled: true,
        offset: 480,
        budget: false,
      );
      final loaded = await api.readSettings(_ai);
      expect(loaded, isA<GreetingSettingsLoaded>());
      final current = (loaded as GreetingSettingsLoaded).state;
      expect((current.enabled, current.budgetReady), (true, false));
      response = payload(revision: 3, offset: 480, budget: false);
      expect(
        await api.writeSettings(
          _ai,
          current: current,
          enabled: false,
          localMinute: 540,
          offsetMinutes: 480,
          quietStartMinute: 1380,
          quietEndMinute: 480,
        ),
        isA<GreetingSettingsWritten>(),
      );
      expect(jsonDecode(requests.last.$3), {
        'expectedRevision': 2,
        'enabled': false,
        'localMinute': 540,
        'offsetMinutes': 480,
        'quietStartMinute': 1380,
        'quietEndMinute': 480,
        'expectedChatRevision': null,
        'expectedGlobalRevision': null,
      });
    },
  );

  test('mismatched successful receipts remain unknown', () async {
    final current = currentSettings();
    for (final invalid in [
      payload(revision: 0, enabled: true, offset: 480),
      payload(revision: 2, enabled: true, offset: 480),
      payload(revision: 1, enabled: true, offset: 480, globalRevision: 1),
      payload(revision: 1, enabled: true, offset: 480, chatRevision: 2),
      payload(revision: 1, enabled: true, offset: 480, local: 541),
      payload(revision: 1, offset: 480),
    ]) {
      response = invalid;
      final result = await api.writeSettings(
        _ai,
        current: current,
        enabled: true,
        localMinute: 540,
        offsetMinutes: 480,
        quietStartMinute: 1380,
        quietEndMinute: 480,
      );
      expect(result, isA<GreetingUnavailable>());
      expect((result as GreetingUnavailable).problem, GreetingProblem.unknown);
    }
    response = {'revision': 1, 'blocked': false};
    final result = await api.writeGlobalStop(
      current: const GlobalGreetingStop(revision: 0, blocked: false),
      blocked: true,
    );
    expect((result as GreetingUnavailable).problem, GreetingProblem.unknown);
    expect(requests, hasLength(7));
  });

  test('global stop uses its independent CAS path and exact receipt', () async {
    response = {'revision': 1, 'blocked': true};
    expect(
      await api.writeGlobalStop(
        current: const GlobalGreetingStop(revision: 0, blocked: false),
        blocked: true,
      ),
      isA<GlobalGreetingStopWritten>(),
    );
    expect(requests.single.$2, _globalPath);
    expect(jsonDecode(requests.single.$3), {
      'expectedRevision': 0,
      'blocked': true,
    });
    response = {'revision': 2, 'blocked': false};
    expect(
      await api.writeGlobalStop(
        current: const GlobalGreetingStop(revision: 1, blocked: true),
        blocked: false,
      ),
      isA<GlobalGreetingStopWritten>(),
    );
    expect(requests.length, 2);
  });

  test('HTTP refusal, revision conflict, and ambiguous results are distinct and not replayed', () async {
    for (final (code, expected) in [
      (400, GreetingProblem.refused),
      (401, GreetingProblem.refused),
      (404, GreetingProblem.refused),
      (409, GreetingProblem.conflict),
      (500, GreetingProblem.unknown),
    ]) {
      status = code;
      response = {'error': 'private fixture error'};
      expect(
        (await api.writeSettings(
          _ai,
          current: currentSettings(),
          enabled: false,
          localMinute: 540,
          offsetMinutes: null,
          quietStartMinute: 1380,
          quietEndMinute: 480,
        ) as GreetingUnavailable).problem,
        expected,
      );
    }
    expect(requests.where((request) => request.$1 == 'PUT'), hasLength(5));
  });
}
