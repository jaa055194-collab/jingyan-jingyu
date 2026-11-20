import 'dart:async';

import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/ai_config/model_diagnostics_screen.dart';
import 'package:client_flutter/net/model_diagnostics_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

class _Session extends TestShellModel {
  _Session() {
    connectedAccountId = 'owner-one';
  }

  Object epoch = Object();
  bool sessionAuthenticated = true;

  @override
  bool get authenticated => sessionAuthenticated;

  @override
  Object? get ownAiSessionContext => epoch;

  void lock() {
    locked = true;
    notifyListeners();
  }

  void unlockForTest() {
    locked = false;
    notifyListeners();
  }

  void logout() {
    sessionAuthenticated = false;
    notifyListeners();
  }

  void switchAccount() {
    connectedAccountId = 'owner-two';
    notifyListeners();
  }

  void renewSession() {
    epoch = Object();
    notifyListeners();
  }

  void notifyUnchanged() => notifyListeners();
}

Widget _sessionScreen(
  _Loaders loaders,
  ShellViewModel session, {
  List<String> providers = const ['provider-one'],
  List<String> profiles = const ['profile-one'],
}) => MaterialApp(
  home: ModelDiagnosticsScreen(
    session: session,
    readCatalog: loaders.catalog,
    readTodayUsage: loaders.usage,
    readRolling7Trend: loaders.trend,
    readBudget: loaders.budget,
    knownProviderIds: providers,
    knownProfileIds: profiles,
  ),
);

ModelCatalog _catalog() => ModelCatalog(const ['model-a', 'model-b']);

TodayUsage _usage({bool unknownFast = true}) => TodayUsage(
  budgetDay: '2026-11-20',
  offsetMinutes: 480,
  recordedTokens: BigInt.from(15),
  byLayer: {
    'b0Life': BigInt.zero,
    'b1FastBrain': BigInt.zero,
    'b2DeepChat': BigInt.from(15),
    'b3Proactive': BigInt.zero,
    'b4Maintenance': BigInt.zero,
  },
  byCapability: {
    'chat': BigInt.from(10),
    'chatFast': BigInt.zero,
    'vision': BigInt.from(5),
    'imageGen': BigInt.zero,
    'tts': BigInt.zero,
    'asr': BigInt.zero,
    'embedding': BigInt.zero,
  },
  sourceUsageUnknown: {
    'chat': false,
    'chatFast': unknownFast,
    'vision': false,
    'imageGen': false,
    'tts': false,
    'asr': false,
    'embedding': false,
  },
);

Rolling7Trend _trend() => Rolling7Trend(
  window: 'rolling7',
  basis: 'recordedBudgetDay',
  offsetMinutes: 480,
  startDay: '2026-11-14',
  endDay: '2026-11-20',
  days: [
    for (var index = 0; index < 7; index++)
      TrendDay(
        day: '2026-11-${14 + index}',
        recordedTokens: BigInt.from(index * 5),
        byLayer: {
          'b0Life': BigInt.zero,
          'b1FastBrain': BigInt.zero,
          'b2DeepChat': BigInt.from(index * 5),
          'b3Proactive': BigInt.zero,
          'b4Maintenance': BigInt.zero,
        },
        sourceUsageUnknown: false,
      ),
  ],
  hasUnknown: true,
);

BudgetLimits _budget() => BudgetLimits(
  dailyTokens: 100,
  layerLimits: const {
    'b0Life': 10,
    'b1FastBrain': 10,
    'b2DeepChat': 40,
    'b3Proactive': 20,
    'b4Maintenance': 20,
  },
  capabilityLimits: const {
    'chat': 60,
    'chatFast': 10,
    'vision': 10,
    'imageGen': 5,
    'tts': 5,
    'asr': 5,
    'embedding': 5,
  },
  offsetMinutes: 480,
);

class _Loaders {
  _Loaders({this.catalog, this.usage, this.trend, this.budget});

  final Future<DiagnosticsRead<ModelCatalog>> Function(String providerId)?
  catalog;
  final Future<DiagnosticsRead<TodayUsage>> Function(String profileId)? usage;
  final Future<DiagnosticsRead<Rolling7Trend>> Function(String profileId)? trend;
  final Future<DiagnosticsRead<BudgetLimits>> Function(String profileId)? budget;
}

Widget _screen(
  _Loaders loaders, {
  List<String> providers = const <String>[],
  List<String> profiles = const <String>[],
}) => MaterialApp(
  home: ModelDiagnosticsScreen(
    readCatalog: loaders.catalog,
    readTodayUsage: loaders.usage,
    readRolling7Trend: loaders.trend,
    readBudget: loaders.budget,
    knownProviderIds: providers,
    knownProfileIds: profiles,
  ),
);

/// The screen is a long ListView; later sections may only exist in the cache
/// extent, so a found widget can still be off-screen and untappable.
///
/// The outer ListView's Scrollable is targeted explicitly: identity `TextField`s
/// carry their own inner Scrollable, so the default single-Scrollable finder is
/// ambiguous here.
Future<void> _reveal(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

/// Type the explicit identity the screen requires before any read.
Future<void> _enter(WidgetTester tester, String key, String value) async {
  await _reveal(tester, key);
  await tester.enterText(find.byKey(Key(key)), value);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await _reveal(tester, key);
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

void main() {
  group('route session invalidation', () {
    for (final change in ['lock', 'logout', 'account', 'epoch']) {
      testWidgets('$change clears loaded metadata and blocks saved callbacks', (
        tester,
      ) async {
        final session = _Session();
        addTearDown(session.dispose);
        var calls = 0;
        await tester.pumpWidget(
          _sessionScreen(
            _Loaders(
              catalog: (_) async {
                calls++;
                return DiagnosticsRead.loaded(_catalog());
              },
              usage: (_) async {
                calls++;
                return DiagnosticsRead.loaded(_usage());
              },
              trend: (_) async {
                calls++;
                return DiagnosticsRead.loaded(_trend());
              },
              budget: (_) async {
                calls++;
                return DiagnosticsRead.loaded(_budget());
              },
            ),
            session,
          ),
        );
        await tester.pumpAndSettle();
        final callbacks = <VoidCallback>[];
        for (final section in ['catalog', 'usage', 'trend', 'budget']) {
          final key = 'diagnostics-$section-load';
          await _tap(tester, key);
          callbacks.add(
            tester.widget<TextButton>(find.byKey(Key(key))).onPressed!,
          );
          expect(
            find.byKey(Key('diagnostics-$section-loaded')),
            findsOneWidget,
          );
        }
        expect(calls, 4);

        switch (change) {
          case 'lock':
            // Both notifications happen before a frame, so current-state-only
            // checks would miss the lock and re-enable the captured connection.
            session.lock();
            session.unlockForTest();
          case 'logout':
            session.logout();
          case 'account':
            session.switchAccount();
          case 'epoch':
            session.renewSession();
        }
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('model-diagnostics-session-invalid')),
          findsOneWidget,
        );
        expect(find.textContaining('model-a'), findsNothing);
        expect(find.textContaining('provider-one'), findsNothing);
        expect(find.textContaining('profile-one'), findsNothing);
        for (final section in ['catalog', 'usage', 'trend', 'budget']) {
          expect(find.byKey(Key('diagnostics-$section-loaded')), findsNothing);
          expect(find.byKey(Key('diagnostics-$section-load')), findsNothing);
        }

        // A retained onPressed closure must also refuse the old route.
        for (final callback in callbacks) {
          callback();
        }
        await tester.pumpAndSettle();
        expect(calls, 4);
      });
    }

    testWidgets('late reads stay discarded after lock then unlock', (
      tester,
    ) async {
      final session = _Session();
      addTearDown(session.dispose);
      final catalog = Completer<DiagnosticsRead<ModelCatalog>>();
      final usage = Completer<DiagnosticsRead<TodayUsage>>();
      final trend = Completer<DiagnosticsRead<Rolling7Trend>>();
      final budget = Completer<DiagnosticsRead<BudgetLimits>>();
      var calls = 0;
      await tester.pumpWidget(
        _sessionScreen(
          _Loaders(
            catalog: (_) {
              calls++;
              return catalog.future;
            },
            usage: (_) {
              calls++;
              return usage.future;
            },
            trend: (_) {
              calls++;
              return trend.future;
            },
            budget: (_) {
              calls++;
              return budget.future;
            },
          ),
          session,
        ),
      );
      await tester.pumpAndSettle();
      for (final section in ['catalog', 'usage', 'trend', 'budget']) {
        await _tap(tester, 'diagnostics-$section-load');
        expect(find.byKey(Key('diagnostics-$section-loading')), findsOneWidget);
      }
      expect(calls, 4);
      session.lock();
      session.unlockForTest();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('model-diagnostics-session-invalid')),
        findsOneWidget,
      );

      catalog.complete(DiagnosticsRead.loaded(_catalog()));
      usage.complete(DiagnosticsRead.loaded(_usage()));
      trend.complete(DiagnosticsRead.loaded(_trend()));
      budget.complete(DiagnosticsRead.loaded(_budget()));
      await tester.pumpAndSettle();
      for (final section in ['catalog', 'usage', 'trend', 'budget']) {
        expect(find.byKey(Key('diagnostics-$section-loaded')), findsNothing);
      }
      expect(find.textContaining('model-a'), findsNothing);
      expect(calls, 4);
    });

    testWidgets(
      'unrelated session notifications keep the unlocked route usable',
      (tester) async {
        final session = _Session();
        addTearDown(session.dispose);
        var calls = 0;
        await tester.pumpWidget(
          _sessionScreen(
            _Loaders(
              catalog: (_) async {
                calls++;
                return DiagnosticsRead.loaded(_catalog());
              },
            ),
            session,
          ),
        );
        await tester.pumpAndSettle();
        session.notifyUnchanged();
        await tester.pumpAndSettle();
        await _tap(tester, 'diagnostics-catalog-load');
        expect(calls, 1);
        expect(find.textContaining('model-a'), findsOneWidget);
        expect(
          find.byKey(const Key('model-diagnostics-session-invalid')),
          findsNothing,
        );
      },
    );

    testWidgets('replacing the session model invalidates the existing route', (
      tester,
    ) async {
      final first = _Session();
      final replacement = _Session()..epoch = first.epoch;
      addTearDown(first.dispose);
      addTearDown(replacement.dispose);
      var calls = 0;
      final loaders = _Loaders(
        catalog: (_) async {
          calls++;
          return DiagnosticsRead.loaded(_catalog());
        },
      );
      await tester.pumpWidget(_sessionScreen(loaders, first));
      await tester.pumpAndSettle();
      await _tap(tester, 'diagnostics-catalog-load');
      await tester.pumpWidget(_sessionScreen(loaders, replacement));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('model-diagnostics-session-invalid')),
        findsOneWidget,
      );
      expect(find.textContaining('model-a'), findsNothing);
      expect(calls, 1);
    });
  });

  testWidgets('no loader at all stays unbound and never fabricates numbers', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ModelDiagnosticsScreen()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('model-diagnostics-unbound')), findsOneWidget);
    expect(find.textContaining('未连接宿主'), findsOneWidget);
    expect(find.textContaining('不会自动重试'), findsOneWidget);
    // No section at all is rendered when unbound: nothing can be read.
    expect(find.byKey(const Key('diagnostics-catalog-section')), findsNothing);
    expect(find.byKey(const Key('diagnostics-usage-section')), findsNothing);
    expect(find.byKey(const Key('diagnostics-trend-section')), findsNothing);
    expect(find.byKey(const Key('diagnostics-budget-section')), findsNothing);
  });

  testWidgets('no read happens until the user explicitly requests one', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      _screen(
        _Loaders(
          catalog: (_) async {
            calls++;
            return DiagnosticsRead.loaded(_catalog());
          },
        ),
        providers: const ['provider-one'],
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(
      find.byKey(const Key('diagnostics-catalog-not-requested')),
      findsOneWidget,
    );

    await _tap(tester, 'diagnostics-catalog-load');
    expect(calls, 1);
    expect(find.textContaining('model-a'), findsOneWidget);
    expect(find.textContaining('model-b'), findsOneWidget);
  });

  testWidgets('unconfigured, unavailable and unknown read states stay distinct', (
    tester,
  ) async {
    await tester.pumpWidget(
      _screen(
        _Loaders(
          catalog: (_) async => const DiagnosticsRead.unconfigured(),
          usage: (_) async => const DiagnosticsRead.unavailable(),
          trend: (_) async => const DiagnosticsRead.unknown(),
          budget: (_) async => const DiagnosticsRead.unconfigured(),
        ),
        providers: const ['provider-one'],
        profiles: const ['profile-one'],
      ),
    );
    await tester.pumpAndSettle();

    await _tap(tester, 'diagnostics-catalog-load');
    expect(
      find.byKey(const Key('diagnostics-catalog-unconfigured')),
      findsOneWidget,
    );

    await _tap(tester, 'diagnostics-usage-load');
    expect(
      find.byKey(const Key('diagnostics-usage-unavailable')),
      findsOneWidget,
    );

    await _tap(tester, 'diagnostics-trend-load');
    expect(find.byKey(const Key('diagnostics-trend-unknown')), findsOneWidget);

    await _tap(tester, 'diagnostics-budget-load');
    expect(
      find.byKey(const Key('diagnostics-budget-unconfigured')),
      findsOneWidget,
    );
    // Unconfigured budget must not be shown as a zero limit.
    expect(find.textContaining('每日 0'), findsNothing);
    // Nor may unconfigured usage be shown as a zero total.
    expect(find.textContaining('已记录 0 tokens'), findsNothing);
  });

  testWidgets('pending usage is shown as unknown, never as zero recorded', (
    tester,
  ) async {
    await tester.pumpWidget(
      _screen(
        _Loaders(usage: (_) async => DiagnosticsRead.loaded(_usage())),
        profiles: const ['profile-one'],
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, 'diagnostics-usage-load');

    expect(find.textContaining('2026-11-20'), findsOneWidget);
    expect(find.textContaining('b2DeepChat'), findsOneWidget);
    expect(find.textContaining('已记录 15 tokens'), findsOneWidget);
    // The pending capability says unknown; it is never rendered as "0 tokens".
    await _reveal(tester, 'diagnostics-usage-unknown-chatFast');
    final unknown = find.byKey(
      const Key('diagnostics-usage-unknown-chatFast'),
    );
    expect(unknown, findsOneWidget);
    expect(
      find.descendant(of: unknown, matching: find.textContaining('未知')),
      findsOneWidget,
    );
    expect(find.textContaining('chatFast：0 tokens'), findsNothing);
  });

  testWidgets('loaded trend shows seven recorded days with honest basis', (
    tester,
  ) async {
    await tester.pumpWidget(
      _screen(
        _Loaders(trend: (_) async => DiagnosticsRead.loaded(_trend())),
        profiles: const ['profile-one'],
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, 'diagnostics-trend-load');

    // The window header states the exact host basis, never a calendar week.
    expect(find.textContaining('窗口 rolling7'), findsOneWidget);
    expect(find.textContaining('口径 recordedBudgetDay'), findsOneWidget);
    expect(find.textContaining('2026-11-14 至 2026-11-20'), findsOneWidget);
    for (var index = 0; index < 7; index++) {
      final day = 'diagnostics-trend-day-2026-11-${14 + index}';
      await _reveal(tester, day);
      expect(find.byKey(Key(day)), findsOneWidget, reason: 'day ${14 + index}');
    }
    await _reveal(tester, 'diagnostics-trend-history-unknown');
    expect(
      find.byKey(const Key('diagnostics-trend-history-unknown')),
      findsOneWidget,
    );
  });

  testWidgets('loaded budget shows configured limits and offset', (tester) async {
    await tester.pumpWidget(
      _screen(
        _Loaders(budget: (_) async => DiagnosticsRead.loaded(_budget())),
        profiles: const ['profile-one'],
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, 'diagnostics-budget-load');

    expect(find.textContaining('每日 100'), findsOneWidget);
    expect(find.textContaining('时区偏移 480'), findsOneWidget);
    await _reveal(tester, 'diagnostics-budget-layer-b2DeepChat');
    expect(
      find.byKey(const Key('diagnostics-budget-layer-b2DeepChat')),
      findsOneWidget,
    );
    await _reveal(tester, 'diagnostics-budget-capability-chat');
    expect(
      find.byKey(const Key('diagnostics-budget-capability-chat')),
      findsOneWidget,
    );
  });

  testWidgets('an explicit provider id is required before the catalog loads', (
    tester,
  ) async {
    var requested = <String>[];
    await tester.pumpWidget(
      _screen(
        _Loaders(
          catalog: (id) async {
            requested.add(id);
            return DiagnosticsRead.loaded(_catalog());
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Requesting with no identity reports the gap and reads nothing.
    await _tap(tester, 'diagnostics-catalog-load');
    expect(requested, isEmpty);
    expect(
      find.byKey(const Key('diagnostics-catalog-needs-provider')),
      findsOneWidget,
    );

    await _enter(tester, 'diagnostics-catalog-provider-input', 'provider-typed');
    await _tap(tester, 'diagnostics-catalog-load');
    expect(requested, ['provider-typed']);
  });

  testWidgets('an explicit AI profile id is required before usage loads', (
    tester,
  ) async {
    var requested = <String>[];
    await tester.pumpWidget(
      _screen(
        _Loaders(
          usage: (id) async {
            requested.add(id);
            return DiagnosticsRead.loaded(_usage());
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _tap(tester, 'diagnostics-usage-load');
    expect(requested, isEmpty);
    expect(
      find.byKey(const Key('diagnostics-usage-needs-profile')),
      findsOneWidget,
    );

    await _enter(tester, 'diagnostics-usage-profile-input', 'profile-typed');
    await _tap(tester, 'diagnostics-usage-load');
    expect(requested, ['profile-typed']);
  });

  testWidgets('several known providers require an explicit dropdown choice', (
    tester,
  ) async {
    var requested = <String>[];
    await tester.pumpWidget(
      _screen(
        _Loaders(
          catalog: (id) async {
            requested.add(id);
            return DiagnosticsRead.loaded(_catalog());
          },
        ),
        providers: const ['provider-one', 'provider-two'],
      ),
    );
    await tester.pumpAndSettle();

    await _tap(tester, 'diagnostics-catalog-load');
    expect(requested, isEmpty);

    await tester.tap(find.byKey(const Key('diagnostics-catalog-provider')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('provider-two').last);
    await tester.pumpAndSettle();
    await _tap(tester, 'diagnostics-catalog-load');
    expect(requested, ['provider-two']);
  });

  testWidgets('a throwing loader becomes unknown without leaking details', (
    tester,
  ) async {
    await tester.pumpWidget(
      _screen(
        _Loaders(
          usage: (_) async => throw const FormatException('secret-detail-xyz'),
        ),
        profiles: const ['profile-one'],
      ),
    );
    await tester.pumpAndSettle();
    await _tap(tester, 'diagnostics-usage-load');

    expect(find.byKey(const Key('diagnostics-usage-unknown')), findsOneWidget);
    expect(find.textContaining('secret-detail-xyz'), findsNothing);
  });

  testWidgets('every read is explicit: one tap is exactly one read', (
    tester,
  ) async {
    var usageCalls = 0;
    var trendCalls = 0;
    var budgetCalls = 0;
    await tester.pumpWidget(
      _screen(
        _Loaders(
          usage: (_) async {
            usageCalls++;
            return DiagnosticsRead.loaded(_usage());
          },
          trend: (_) async {
            trendCalls++;
            return DiagnosticsRead.loaded(_trend());
          },
          budget: (_) async {
            budgetCalls++;
            return DiagnosticsRead.loaded(_budget());
          },
        ),
        profiles: const ['profile-one'],
      ),
    );
    await tester.pumpAndSettle();
    expect((usageCalls, trendCalls, budgetCalls), (0, 0, 0));

    await _tap(tester, 'diagnostics-usage-load');
    expect((usageCalls, trendCalls, budgetCalls), (1, 0, 0));

    await _tap(tester, 'diagnostics-trend-load');
    expect((usageCalls, trendCalls, budgetCalls), (1, 1, 0));

    await _tap(tester, 'diagnostics-budget-load');
    expect((usageCalls, trendCalls, budgetCalls), (1, 1, 1));

    // No polling: pumping more frames without taps issues no further reads.
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect((usageCalls, trendCalls, budgetCalls), (1, 1, 1));
  });

  testWidgets('the screen never renders a credential or key mask', (
    tester,
  ) async {
    await tester.pumpWidget(
      _screen(
        _Loaders(
          catalog: (_) async => DiagnosticsRead.loaded(_catalog()),
          usage: (_) async => DiagnosticsRead.loaded(_usage()),
          trend: (_) async => DiagnosticsRead.loaded(_trend()),
          budget: (_) async => DiagnosticsRead.loaded(_budget()),
        ),
        providers: const ['provider-one'],
        profiles: const ['profile-one'],
      ),
    );
    await tester.pumpAndSettle();
    for (final key in const [
      'diagnostics-catalog-load',
      'diagnostics-usage-load',
      'diagnostics-trend-load',
      'diagnostics-budget-load',
    ]) {
      await _tap(tester, key);
    }
    expect(find.textContaining('sk-'), findsNothing);
    expect(find.textContaining('key_mask'), findsNothing);
    expect(find.textContaining('Bearer'), findsNothing);
  });
}
