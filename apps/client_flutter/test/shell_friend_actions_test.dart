import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Connection extends HostConnection {
  _Connection() : super(Uri.parse('http://fixture.invalid'), 'fixture-token');

  final pending = {'fixture-alice', 'fixture-bob'};
  final writes = <String>[];

  @override
  Future<List<Object?>> requestList(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
  }) async {
    expect(method, 'GET');
    expect(path, '/api/v1/friends');
    return [
      for (final id in pending)
        {
          'accountId': id,
          'displayName': id == 'fixture-alice'
              ? 'Fixture Alice'
              : 'Fixture Bob',
          'state': 'incomingPending',
        },
    ];
  }

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    expect(method, 'POST');
    expect(body, isNull);
    expect(allowEmptySuccess, isTrue);
    writes.add(path);
    final id = path.split('/')[4];
    pending.remove(id);
    return {};
  }
}

class _Runtime extends ClientRuntime {
  _Runtime(HostConnection live) {
    connection = live;
  }
  @override
  bool get ready => true;
  @override
  bool get onboarded => true;
  @override
  bool get chatEntered => true;
  @override
  bool get online => true;
  @override
  String? get connectedAccountId => 'fixture-recipient';
}

void main() {
  testWidgets(
    'production contacts tab submits only explicitly tapped invitations',
    (tester) async {
      final connection = _Connection();
      addTearDown(connection.close);
      await tester.pumpWidget(WhaleChatApp(model: _Runtime(connection)));
      await tester.tap(find.text('联系人'));
      await tester.pumpAndSettle();
      expect(connection.writes, isEmpty);
      final accept = find.byKey(const Key('friend-accept-fixture-alice'));
      expect(tester.widget<TextButton>(accept).onPressed, isNotNull);
      await tester.tap(accept);
      await tester.pumpAndSettle();
      expect(connection.writes, ['/api/v1/friends/fixture-alice/accept']);
      expect(accept, findsNothing);
      final deny = find.byKey(const Key('friend-deny-fixture-bob'));
      expect(tester.widget<TextButton>(deny).onPressed, isNotNull);
      await tester.tap(deny);
      await tester.pumpAndSettle();
      expect(connection.writes, [
        '/api/v1/friends/fixture-alice/accept',
        '/api/v1/friends/fixture-bob/deny',
      ]);
      expect(deny, findsNothing);
    },
  );
}
