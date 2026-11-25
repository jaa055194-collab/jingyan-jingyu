import 'dart:async';

import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/features/search/search_screen.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/search_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

SearchHit _hit({
  String conversationId = 'conv-1',
  String messageId = 'msg-1',
  int seq = 12,
  String senderId = 'acc-2',
  MessageKind kind = MessageKind.text,
  Map<String, Object?> body = const {'text': '项目代号鲸落'},
  DateTime? sentAt,
  SearchHitMode mode = SearchHitMode.blind,
}) => SearchHit(
  conversationId: conversationId,
  messageId: messageId,
  seq: seq,
  senderId: senderId,
  kind: kind,
  body: body,
  sentAt: sentAt ?? DateTime.utc(2026, 11, 14, 9),
  mode: mode,
);

/// Records every call so tests can prove nothing is fetched on load and that an
/// empty query sends no request at all.
class _Recorder {
  final List<String> queries = <String>[];
  SearchOutcome outcome = const SearchLoaded(<SearchHit>[]);
  Future<SearchOutcome>? pending;
  Object? throwThis;

  Future<SearchOutcome> call(
    String query, {
    required int limit,
    String? senderId,
    MessageKind? kind,
    DateTime? from,
    DateTime? to,
  }) async {
    queries.add(query);
    if (throwThis != null) throw throwThis!;
    final response = pending;
    return response == null ? outcome : await response;
  }
}

class _SearchSession extends TestShellModel {
  _SearchSession() {
    connectedAccountId = 'fixture-account';
  }

  Object? epoch = 1;

  @override
  Object? get ownAiSessionContext => epoch;

  void changeLock(bool value) {
    locked = value;
    notifyListeners();
  }

  void changeSession(String? account, Object? context) {
    connectedAccountId = account;
    epoch = context;
    notifyListeners();
  }
}

Future<void> _openSearchRoute(
  WidgetTester tester,
  _Recorder recorder,
  _SearchSession session,
) async {
  await tester.pumpWidget(WhaleChatApp(model: session));
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  navigator.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => SearchScreen(
        search: recorder.call,
        session: session,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  _Recorder recorder, {
  bool bound = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SearchScreen(
        search: bound ? recorder.call : null,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('search-query')), text);
  await tester.tap(find.byKey(const Key('search-submit')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('nothing is fetched on screen load', (tester) async {
    final recorder = _Recorder();
    await _pump(tester, recorder);
    expect(recorder.queries, isEmpty);
    expect(find.byKey(const Key('search-idle')), findsOneWidget);
    expect(find.byKey(const Key('search-empty')), findsNothing);
    expect(find.byKey(const Key('search-results')), findsNothing);
  });

  testWidgets('an empty or whitespace query performs no request', (
    tester,
  ) async {
    final recorder = _Recorder();
    await _pump(tester, recorder);
    await _submit(tester, '   ');
    await _submit(tester, '');
    expect(recorder.queries, isEmpty);
    expect(find.byKey(const Key('search-idle')), findsOneWidget);
    expect(find.byKey(const Key('search-empty')), findsNothing);
  });

  testWidgets('an explicit submit renders conversation, sender, kind, seq and '
      'snippet for each hit', (tester) async {
    final recorder = _Recorder()
      ..outcome = SearchLoaded([
        _hit(),
        _hit(
          conversationId: 'conv-2',
          messageId: 'msg-2',
          seq: 3,
          senderId: 'acc-9',
          kind: MessageKind.image,
          body: const {'attachmentId': 'att-1'},
          mode: SearchHitMode.scan,
        ),
      ]);
    await _pump(tester, recorder);
    await _submit(tester, '  鲸落  ');
    expect(recorder.queries, ['  鲸落  ']);
    expect(find.byKey(const Key('search-results')), findsOneWidget);
    final first = find.byKey(const Key('search-hit-msg-1'));
    expect(first, findsOneWidget);
    expect(
      find.descendant(of: first, matching: find.textContaining('conv-1')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: first, matching: find.textContaining('acc-2')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: first, matching: find.textContaining('text')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: first, matching: find.textContaining('12')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: first, matching: find.textContaining('项目代号鲸落')),
      findsOneWidget,
    );
    final second = find.byKey(const Key('search-hit-msg-2'));
    expect(
      find.descendant(of: second, matching: find.textContaining('image')),
      findsOneWidget,
    );
    // A hit without a text body shows an honest placeholder, not invented text.
    expect(
      find.descendant(of: second, matching: find.textContaining('无文本正文')),
      findsOneWidget,
    );
  });

  testWidgets('tapping a hit opens nothing', (tester) async {
    final recorder = _Recorder()
      ..outcome = SearchLoaded([_hit()]);
    await _pump(tester, recorder);
    await _submit(tester, '鲸落');
    await tester.tap(find.byKey(const Key('search-hit-msg-1')));
    await tester.pumpAndSettle();
    // Still the same screen: no conversation is opened and nothing re-fetched.
    expect(find.byType(SearchScreen), findsOneWidget);
    expect(recorder.queries, hasLength(1));
    expect(find.byKey(const Key('search-hit-msg-1')), findsOneWidget);
  });

  testWidgets('pushed search hides private data after rapid lock and unlock', (
    tester,
  ) async {
    final session = _SearchSession();
    final recorder = _Recorder()..outcome = SearchLoaded([_hit()]);
    await _openSearchRoute(tester, recorder, session);
    await _submit(tester, 'private query');
    expect(find.text('项目代号鲸落'), findsOneWidget);
    final field = find.byKey(const Key('search-query'));
    final submit = find.byKey(const Key('search-submit'));
    final controller = tester.widget<TextField>(field).controller!;
    final staleSubmit = tester.widget<FilledButton>(submit).onPressed!;

    // No frame separates the notifications: checking only during build misses
    // this transition. The old callback is still present until the next frame.
    session.changeLock(true);
    session.changeLock(false);
    staleSubmit();
    await tester.pumpAndSettle();

    expect(find.text('项目代号鲸落'), findsNothing);
    expect(controller.text, isEmpty);
    expect(field, findsNothing);
    expect(submit, findsNothing);
    expect(recorder.queries, ['private query']);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await _openSearchRoute(tester, recorder, session);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(find.text('项目代号鲸落'), findsNothing);
    expect(recorder.queries, ['private query']);
    await _submit(tester, 'new query');
    expect(recorder.queries, ['private query', 'new query']);
  });

  for (final (label, account, epoch) in [
    ('logout', null, null),
    ('account switch', 'different-account', 1),
    ('new session for the same account', 'fixture-account', 2),
  ]) {
    testWidgets('pushed search drops the in-flight result after $label', (
      tester,
    ) async {
      final session = _SearchSession();
      final pending = Completer<SearchOutcome>();
      final recorder = _Recorder()..pending = pending.future;
      await _openSearchRoute(tester, recorder, session);
      final field = find.byKey(const Key('search-query'));
      await tester.enterText(field, 'pending query');
      await tester.tap(find.byKey(const Key('search-submit')));
      await tester.pump();
      expect(recorder.queries, ['pending query']);

      session.changeSession(account, epoch);
      pending.complete(SearchLoaded([_hit()]));
      await tester.pumpAndSettle();

      expect(find.text('项目代号鲸落'), findsNothing);
      expect(field, findsNothing);
      expect(find.byKey(const Key('search-submit')), findsNothing);
      expect(recorder.queries, ['pending query']);
    });
  }

  testWidgets('zero hits is a distinct honest empty state', (tester) async {
    final recorder = _Recorder()
      ..outcome = const SearchLoaded(<SearchHit>[]);
    await _pump(tester, recorder);
    await _submit(tester, 'nothing-matches');
    expect(find.byKey(const Key('search-empty')), findsOneWidget);
    expect(find.byKey(const Key('search-results')), findsNothing);
    expect(find.byKey(const Key('search-idle')), findsNothing);
    // Honest wording: an empty page is not proof of complete coverage.
    expect(find.textContaining('不代表'), findsOneWidget);
  });

  testWidgets('unauthenticated and unavailable and malformed are distinct', (
    tester,
  ) async {
    for (final (outcome, key) in [
      (const SearchUnauthenticated(), 'search-denied'),
      (const SearchUnavailable(), 'search-unavailable'),
      (const SearchMalformed(), 'search-malformed'),
    ]) {
      final recorder = _Recorder()..outcome = outcome;
      await _pump(tester, recorder);
      await _submit(tester, '鲸落');
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
      expect(find.byKey(const Key('search-results')), findsNothing);
      expect(find.byKey(const Key('search-empty')), findsNothing);
    }
  });

  testWidgets('an unbound screen sends nothing and says so', (tester) async {
    await _pump(tester, _Recorder(), bound: false);
    expect(find.byKey(const Key('search-unbound')), findsOneWidget);
    expect(find.byKey(const Key('search-query')), findsNothing);
  });

  testWidgets('a transport throw is not surfaced raw and is not a success', (
    tester,
  ) async {
    final recorder = _Recorder()
      ..throwThis = const HostRequestException(
        Failure(FailureCode.internal, 'secret-transport-detail'),
      );
    await _pump(tester, recorder);
    await _submit(tester, '鲸落');
    expect(find.byKey(const Key('search-unavailable')), findsOneWidget);
    expect(find.textContaining('secret-transport-detail'), findsNothing);
    expect(find.byKey(const Key('search-results')), findsNothing);
  });

  testWidgets('the screen never claims an index, ranking or full coverage', (
    tester,
  ) async {
    final recorder = _Recorder()
      ..outcome = SearchLoaded([_hit()]);
    await _pump(tester, recorder);
    await _submit(tester, '鲸落');
    // Affirmative capability words that would overclaim the host mechanism.
    for (final claim in ['FTS', 'BM25', '相关度', '排名', '打分', '已覆盖全部']) {
      expect(find.textContaining(claim), findsNothing, reason: claim);
    }
    // The honest note names the host mechanism and disclaims coverage instead.
    final note = tester.widget<Text>(
      find.byKey(const Key('search-mechanism-note')),
    );
    expect(note.data, contains('有界解密扫描'));
    expect(note.data, contains('盲索引'));
    expect(note.data, contains('不是客户端全文索引'));
    expect(note.data, contains('不保证覆盖全部历史'));
  });
}
