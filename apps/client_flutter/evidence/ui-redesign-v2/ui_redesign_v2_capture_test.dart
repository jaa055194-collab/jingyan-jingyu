// UI redesign v2 screenshot harness (ticket ui-redesign-v2-58efb3240b0f).
//
// Renders real pages from a fake model into PNG files. These are harness
// renders, not native-window or live-host evidence. Nothing runs unless
// CAPTURE_OUT is set, so a plain `flutter test` of this file reports one
// skipped test. team-tools/capture.ps1 in the ticket directory runs it and
// sets:
//
// * CAPTURE_OUT: absolute output directory (required).
// * CAPTURE_SCENARIO: a scenario name, a comma-separated list, or `all`.
// * CAPTURE_THEME: `light`, `dark` or `both` (the default).
// * CAPTURE_SIZE: `412x915`, `1280x800` or `both` (the default).
//
// Each render is written as `<scenario>-<size>-<theme>.png` at device pixel
// ratio 1 and reported on a `CAPTURE_PNG` line with pixel statistics, so a
// blank image shows without opening it. Framework errors (overflows and the
// like) do not fail a render; each is printed on a `CAPTURE_EXCEPTION` line.
//
// The same file must compile on main 0300369 (Before) and on the redesign
// branches (After). It only uses WhaleChatApp, the ShellViewModel data
// classes and TestShellModel; members only newer models have are declared
// without @override, and noSuchMethod reports anything still missing.
//
// Fonts: the app's FontManifest.json supplies the icon fonts under their own
// family names. msyh.ttc from the Windows fonts folder stands in for Ahem,
// Roboto, FlutterTest and every other family the rendered text asks for (the
// page is rendered again after a new family is registered), so Chinese text
// renders as on Windows; emoji families get seguiemj.ttf.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';

import '../../test/ui_test.dart' show TestShellModel;

const _imageKey = Key('ui-redesign-v2-capture');

/// Viewports by name; renders use device pixel ratio 1.
const Map<String, Size> captureSizes = {
  '412x915': Size(412, 915),
  '1280x800': Size(1280, 800),
};

const List<String> captureThemes = ['light', 'dark'];

/// One state of the app: [build] makes the model, the app is pumped with it
/// and settled, then [act] (if given) drives the app and it settles again.
class CaptureScenario {
  const CaptureScenario(this.name, this.build, [this.act]);

  final String name;
  final CaptureModel Function() build;
  final Future<void> Function(WidgetTester tester, CaptureModel model)? act;
}

/// The scenarios; capture.ps1 -Scenario takes these names.
final List<CaptureScenario> captureScenarios = [
  // Shell and conversation list. Signed in and online with six
  // conversations (previews, unread counts), none of them open.
  const CaptureScenario('conversations', CaptureModel.new),
  // Signed in and online, no conversations yet.
  CaptureScenario(
    'conversations-empty',
    () => CaptureModel(conversations: const []),
  ),
  // Signed in but offline; nothing loaded.
  CaptureScenario(
    'conversations-offline',
    () => CaptureModel(conversations: const [], online: false),
  ),
  // Signed in and online, but reading the conversations failed.
  CaptureScenario(
    'conversations-error',
    () => CaptureModel(conversations: const [], error: '会话读取失败，请稍后重试'),
  ),
  // Chat. Each scenario opens a conversation by tapping its row: on a phone
  // the chat replaces the list, on a wide screen it fills the right pane.
  // A group created a moment ago, without messages.
  CaptureScenario(
    'chat-empty',
    () => CaptureModel(conversations: [...sampleConversations, newGroup]),
    (tester, model) => openConversation(tester, model, newGroup.id),
  ),
  // A friend chat: incoming and outgoing text, an image, an edited and a
  // recalled message, then one queued and one failed outgoing message.
  CaptureScenario(
    'chat',
    () => CaptureModel(messagesById: {'linwu': friendChat}),
    (tester, model) => openConversation(tester, model, 'linwu'),
  ),
  // The direct chat with the user's own AI companion 小鲸.
  CaptureScenario(
    'chat-companion',
    () => CaptureModel(messagesById: {'xiaojing': companionChat}),
    (tester, model) => openConversation(tester, model, 'xiaojing'),
  ),
  // The friend chat while the app is busy, with an unsent draft.
  CaptureScenario(
    'chat-busy',
    () => CaptureModel(messagesById: {'linwu': friendChat}),
    (tester, model) async {
      await openConversation(tester, model, 'linwu');
      await _settle(tester);
      if (model.selectedConversationId != null) {
        model.updateDraft('我可能会晚十分钟到。');
      }
      model.update((m) => m.busy = true);
    },
  ),
  // Settings, opened with the title-bar button: the top of the list.
  CaptureScenario(
    'settings',
    () => CaptureModel(),
    (tester, _) => openSettings(tester),
  ),
  // Settings scrolled to 我的 AI, which lists the own AI 小鲸.
  CaptureScenario('settings-own-ai', () => CaptureModel(), (tester, _) async {
    await openSettings(tester);
    await scrollTo(tester, find.text('我的 AI'), '我的 AI', top: true);
  }),
  // The other tabs, opened from the navigation bar (phone) or rail (wide).
  // CaptureModel is not a ClientRuntime, so on 0300369 the shell wires no
  // host loaders into 联系人, 动态 and 收件箱: they show their offline state.
  CaptureScenario(
    'contacts',
    () => CaptureModel(),
    (tester, _) => openTab(tester, '联系人'),
  ),
  CaptureScenario(
    'creative',
    () => CaptureModel(),
    (tester, _) => openTab(tester, '动态'),
  ),
  CaptureScenario(
    'inbox',
    () => CaptureModel(),
    (tester, _) => openTab(tester, '收件箱'),
  ),
  CaptureScenario(
    'world',
    () => CaptureModel(),
    (tester, _) => openTab(tester, '世界'),
  ),
  // Pages pushed from settings. Without a ClientRuntime they get no host
  // connection on 0300369.
  CaptureScenario(
    'voice',
    () => CaptureModel(),
    (tester, _) => openFromSettings(tester, 'open-voice-profile', '语音音色'),
  ),
  CaptureScenario(
    'voice-calls',
    () => CaptureModel(),
    (tester, _) => openFromSettings(tester, 'open-voice-call-list', '语音通话列表'),
  ),
  CaptureScenario(
    'ai-config-check',
    () => CaptureModel(),
    (tester, _) => openFromSettings(tester, 'open-ai-config', 'AI 运行配置体检'),
  ),
  CaptureScenario(
    'ai-config-edit',
    () => CaptureModel(),
    (tester, _) => openFromSettings(tester, 'open-ai-config-write', 'AI 运行配置'),
  ),
  // Onboarding, step 1/3: signed out.
  CaptureScenario('onboarding-host', () => CaptureModel(signedIn: false)),
  // Step 2/3: signed in as account-a, world setup not done.
  CaptureScenario('onboarding-character', () => CaptureModel(onboarded: false)),
  // Step 3/3: the same after tapping 下一步.
  CaptureScenario(
    'onboarding-room',
    () => CaptureModel(onboarded: false),
    (tester, _) => tapText(tester, '下一步'),
  ),
];

const List<ShellConversation> sampleConversations = [
  ShellConversation(
    id: 'xiaojing',
    title: '小鲸',
    preview: '明早有雨，出门记得带伞。',
    unread: 1,
    kind: 'direct',
  ),
  ShellConversation(
    id: 'linwu',
    title: '林雾',
    preview: '周六的展我买到票了！',
    unread: 2,
    kind: 'direct',
  ),
  ShellConversation(
    id: 'hiking',
    title: '周末徒步小队',
    preview: '阿哲：集合时间改到 7:30',
    unread: 12,
    kind: 'group',
  ),
  ShellConversation(id: 'mom', title: '妈妈', preview: '到家了吗？', kind: 'direct'),
  ShellConversation(
    id: 'review',
    title: '设计评审',
    preview: '你：新稿已经发到群文件',
    kind: 'group',
  ),
  ShellConversation(id: 'aqing', title: '阿青', preview: '[图片]', kind: 'direct'),
];

/// A group without messages, for chat-empty.
const ShellConversation newGroup = ShellConversation(
  id: 'bookclub',
  title: '读书会',
  kind: 'group',
);

DateTime _at(int hour, int minute) => DateTime(2026, 11, 24, hour, minute);

/// The chat with 林雾, oldest first. The last two are local: one waits to be
/// sent, one failed.
final List<ShellMessage> friendChat = [
  ShellMessage(
    id: 'm-linwu-1',
    text: '周六有空吗？想去看江边那个灯光展。',
    outgoing: true,
    sentAt: _at(20, 2),
  ),
  ShellMessage(
    id: 'm-linwu-2',
    text: '有空！我去看看还有没有票，听说周末人很多，可能要早点去排队。',
    sentAt: _at(20, 5),
  ),
  ShellMessage(
    id: 'm-linwu-3',
    text: '灯光展海报.jpg',
    attachmentId: 'att-poster',
    attachmentName: '灯光展海报.jpg',
    imageAttachment: true,
    sentAt: _at(20, 6),
  ),
  ShellMessage(
    id: 'm-linwu-4',
    text: '好，晚饭的位子我来订。',
    outgoing: true,
    edited: true,
    sentAt: _at(20, 8),
  ),
  ShellMessage(
    id: 'm-linwu-5',
    text: '消息已撤回',
    outgoing: true,
    recalled: true,
    sentAt: _at(20, 9),
  ),
  ShellMessage(id: 'm-linwu-6', text: '周六的展我买到票了！', sentAt: _at(20, 31)),
  const ShellMessage(
    id: 'm-linwu-7',
    text: '太好了，周六见！',
    outgoing: true,
    status: '等待补传',
  ),
  const ShellMessage(
    id: 'm-linwu-8',
    text: '我把餐厅地址发你。',
    outgoing: true,
    status: '发送失败',
  ),
];

/// The chat with the own AI companion 小鲸, oldest first.
final List<ShellMessage> companionChat = [
  ShellMessage(
    id: 'm-xiaojing-1',
    text: '小鲸，明天天气怎么样？',
    outgoing: true,
    sentAt: _at(21, 40),
  ),
  ShellMessage(
    id: 'm-xiaojing-2',
    text: '明天白天多云，最高 14 度，傍晚风会大一些。',
    sentAt: _at(21, 40),
  ),
  ShellMessage(
    id: 'm-xiaojing-3',
    text: '那早上呢？要早起去赶车。',
    outgoing: true,
    sentAt: _at(21, 41),
  ),
  ShellMessage(id: 'm-xiaojing-4', text: '明早有雨，出门记得带伞。', sentAt: _at(21, 41)),
];

/// Opens conversation [id] the way a user does, by tapping its row in the
/// list (found by its key, else by its title). Prints CAPTURE_WARN when the
/// row is missing or the tap did not open the conversation.
Future<void> openConversation(
  WidgetTester tester,
  CaptureModel model,
  String id,
) async {
  final title = model.conversations
      .firstWhere((conversation) => conversation.id == id)
      .title;
  var row = find.byKey(ValueKey(id));
  if (row.evaluate().isEmpty) row = find.text(title, findRichText: true);
  if (row.evaluate().isEmpty) {
    debugPrint('CAPTURE_WARN no row for conversation $id ($title)');
    return;
  }
  await tester.ensureVisible(row.first);
  await tester.pump();
  await tester.tap(row.first, warnIfMissed: false);
  await tester.pump();
  if (model.selectedConversationId != id) {
    debugPrint('CAPTURE_WARN tapping $title did not open conversation $id');
  }
}

/// Opens settings with the title-bar button (tooltip 设置). Prints
/// CAPTURE_WARN when the button is missing or the conversation list still
/// shows afterwards.
Future<void> openSettings(WidgetTester tester) async {
  final button = find.byTooltip('设置');
  if (button.evaluate().isEmpty) {
    debugPrint('CAPTURE_WARN no settings button');
    return;
  }
  await tester.tap(button.first, warnIfMissed: false);
  await _settle(tester);
  if (_listShowing()) {
    debugPrint('CAPTURE_WARN the settings button left the list showing');
  }
}

/// Opens the tab [label] by tapping it in the navigation bar (phone) or the
/// rail (wide). Prints CAPTURE_WARN when the label is missing or the
/// conversation list still shows afterwards.
Future<void> openTab(WidgetTester tester, String label) async {
  final tab = find.text(label);
  if (tab.evaluate().isEmpty) {
    debugPrint('CAPTURE_WARN no navigation label $label');
    return;
  }
  await tester.tap(tab.last, warnIfMissed: false);
  await _settle(tester);
  if (_listShowing()) {
    debugPrint('CAPTURE_WARN tapping $label left the list showing');
  }
}

/// Opens settings, scrolls to the entry with key [key] (or else the text
/// [title]) and taps it. Prints CAPTURE_WARN when the entry is missing or
/// the tap pushed no page.
Future<void> openFromSettings(
  WidgetTester tester,
  String key,
  String title,
) async {
  await openSettings(tester);
  final entry = find.byWidgetPredicate(
    (widget) =>
        widget.key == ValueKey(key) || (widget is Text && widget.data == title),
    description: 'key $key or text $title',
  );
  if (!await scrollTo(tester, entry, title)) return;
  await tester.tap(entry.first, warnIfMissed: false);
  await _settle(tester);
  final pushed = tester
      .stateList<NavigatorState>(find.byType(Navigator))
      .any((navigator) => navigator.canPop());
  if (!pushed) debugPrint('CAPTURE_WARN tapping $title pushed no page');
}

/// Taps the button labelled [text]. Prints CAPTURE_WARN when it is missing
/// or still shows afterwards.
Future<void> tapText(WidgetTester tester, String text) async {
  if (!await scrollTo(tester, find.text(text), text)) return;
  await tester.tap(find.text(text).first, warnIfMissed: false);
  await _settle(tester);
  if (find.text(text).evaluate().isNotEmpty) {
    debugPrint('CAPTURE_WARN $text still shows after tapping it');
  }
}

/// Scrolls until [target] is built, then brings it into view when it is off
/// screen (to the top of the view when [top]). The scroll offset is set
/// directly instead of dragged, on the vertical scrollables in order of
/// viewport height. Prints CAPTURE_WARN with each tried scrollable's
/// offset/extent and returns false when [target] never appears.
Future<bool> scrollTo(
  WidgetTester tester,
  Finder target,
  String what, {
  bool top = false,
}) async {
  final tried = <String>[];
  if (target.evaluate().isEmpty) {
    final scrollables = [
      for (final state in tester.stateList<ScrollableState>(
        find.byType(Scrollable),
      ))
        if (state.position.axis == Axis.vertical &&
            state.position.hasViewportDimension &&
            state.position.hasContentDimensions)
          state,
    ];
    scrollables.sort(
      (a, b) =>
          b.position.viewportDimension.compareTo(a.position.viewportDimension),
    );
    for (final state in scrollables) {
      if (!state.mounted) continue;
      final position = state.position;
      for (var step = 0; step < 200 && target.evaluate().isEmpty; step++) {
        if (position.pixels >= position.maxScrollExtent) break;
        final next = position.pixels + position.viewportDimension / 2;
        position.jumpTo(
          next < position.maxScrollExtent ? next : position.maxScrollExtent,
        );
        await tester.pump();
      }
      tried.add(
        '${position.pixels.round()}/${position.maxScrollExtent.round()}',
      );
      if (target.evaluate().isNotEmpty) break;
    }
  }
  if (target.evaluate().isEmpty) {
    debugPrint(
      'CAPTURE_WARN $what not found; vertical scrollables at offset/max: '
      '${tried.isEmpty ? 'none' : tried.join(', ')}',
    );
    return false;
  }
  final rect = tester.getRect(target.first);
  final height = tester.view.physicalSize.height / tester.view.devicePixelRatio;
  if (top || rect.top < 0 || rect.bottom > height) {
    await tester.ensureVisible(target.first);
    await tester.pump();
  }
  return true;
}

/// Whether the conversation list shows: a sample conversation title is on
/// screen. The companion's is skipped, since settings lists 小鲸 too.
bool _listShowing() => sampleConversations
    .where((conversation) => conversation.id != 'xiaojing')
    .any((conversation) => find.text(conversation.title).evaluate().isNotEmpty);

/// The user's own AI companion; its direct chat is `xiaojing`.
const ShellOwnedAi sampleCompanion = ShellOwnedAi(
  accountId: 'ai-xiaojing',
  displayName: '小鲸',
  disabled: false,
);

/// Signed in as account-a with [sampleCompanion] as the own AI (signed out
/// and not onboarded when [signedIn] is false), onboarded unless [onboarded]
/// is false (a signed-in user then stays in onboarding), online and without
/// an error unless [online] or [error] say otherwise, nothing queued.
/// Opening a conversation shows its entry in [messagesById] (none when
/// absent).
class CaptureModel extends TestShellModel {
  CaptureModel({
    List<ShellConversation> conversations = sampleConversations,
    this.messagesById = const {},
    bool signedIn = true,
    bool? onboarded,
    bool online = true,
    String? error,
  }) {
    this.onboarded = onboarded ?? signedIn;
    chatEntered = this.onboarded;
    connectedAccountId = signedIn ? 'account-a' : null;
    this.online = online;
    this.error = error;
    queuedCount = 0;
    this.conversations = signedIn ? conversations : const [];
  }

  final Map<String, List<ShellMessage>> messagesById;
  final Object _ownAiEpoch = Object();

  @override
  List<ShellOwnedAi> get ownAiAccounts =>
      authenticated ? const [sampleCompanion] : const [];

  @override
  bool get ownAiLoaded => authenticated;

  @override
  Object? get ownAiDirectContext => authenticated ? _ownAiEpoch : null;

  @override
  ShellOwnAiDirectState ownAiDirectState(String aiAccountId) =>
      authenticated && aiAccountId == sampleCompanion.accountId
      ? const ShellOwnAiDirectState(
          phase: ShellOwnAiDirectPhase.ready,
          profileId: 'profile-xiaojing',
          revision: 1,
          enabled: true,
          conversationId: 'xiaojing',
        )
      : const ShellOwnAiDirectState();

  @override
  Future<void> selectConversation(String id) async {
    selectedConversationId = id;
    messages = messagesById[id] ?? const [];
    notifyListeners();
  }

  /// Applies [change] and notifies the app.
  void update(void Function(CaptureModel model) change) {
    change(this);
    notifyListeners();
  }

  /// Members that neither this class nor TestShellModel implements.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    debugPrint('CAPTURE_NO_SUCH_METHOD ${invocation.memberName}');
    return super.noSuchMethod(invocation);
  }
}

void main() {
  final env = Platform.environment;
  final out = (env['CAPTURE_OUT'] ?? '').trim();
  if (out.isEmpty) {
    test('capture is off (set CAPTURE_OUT)', () {}, skip: true);
    return;
  }
  final unknown = <String>[];
  final names = _pick(env['CAPTURE_SCENARIO'], [
    for (final scenario in captureScenarios) scenario.name,
  ], unknown);
  final sizes = _pick(env['CAPTURE_SIZE'], captureSizes.keys.toList(), unknown);
  final themes = _pick(env['CAPTURE_THEME'], captureThemes, unknown);
  debugPrint(
    'CAPTURE_PLAN scenarios=${names.join(',')} sizes=${sizes.join(',')} '
    'themes=${themes.join(',')} out=$out',
  );
  if (unknown.isNotEmpty || names.isEmpty || sizes.isEmpty || themes.isEmpty) {
    test('capture arguments', () {
      fail(
        'unknown value(s): ${unknown.join(', ')}; scenarios: '
        '${captureScenarios.map((scenario) => scenario.name).join(', ')}',
      );
    });
    return;
  }
  for (final scenario in captureScenarios) {
    if (!names.contains(scenario.name)) continue;
    for (final size in sizes) {
      for (final theme in themes) {
        testWidgets(
          'capture ${scenario.name} $size $theme',
          (tester) => _capture(tester, scenario, size, theme, out),
        );
      }
    }
  }
}

/// [raw] is empty, `all`, `both` or a comma-separated subset of [known].
List<String> _pick(String? raw, List<String> known, List<String> unknown) {
  final value = (raw ?? '').trim();
  if (value.isEmpty || value == 'all' || value == 'both') return known;
  final picked = <String>[];
  for (final part in value.split(',')) {
    final name = part.trim();
    if (name.isEmpty || picked.contains(name)) continue;
    if (known.contains(name)) {
      picked.add(name);
    } else {
      unknown.add(name);
    }
  }
  return picked;
}

String _firstLine(Object error) {
  final text = error.toString();
  final end = text.indexOf('\n');
  return (end < 0 ? text : text.substring(0, end)).trim();
}

Future<void> _capture(
  WidgetTester tester,
  CaptureScenario scenario,
  String size,
  String theme,
  String out,
) async {
  final file = '${scenario.name}-$size-$theme.png';
  final mode = theme == 'dark' ? ThemeMode.dark : ThemeMode.light;
  final errors = <String>[];
  final onError = FlutterError.onError;
  final shadows = debugDisableShadows;
  final banner = WidgetsApp.debugAllowBannerOverride;
  FlutterError.onError = (details) =>
      errors.add(_firstLine(details.exceptionAsString()));
  debugDisableShadows = false;
  WidgetsApp.debugAllowBannerOverride = false;
  try {
    tester.view.physicalSize = captureSizes[size]!;
    tester.view.devicePixelRatio = 1;
    await _loadBaseFonts();
    await _render(tester, scenario, mode);
    final added = await _alias(_usedFamilies(tester));
    if (added.isNotEmpty) {
      debugPrint('CAPTURE_FONTS +${added.join(', ')} (rendering $file again)');
      errors.clear();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await _render(tester, scenario, mode);
    }
    await _writePng(tester, '$out${Platform.pathSeparator}$file', file);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  } finally {
    FlutterError.onError = onError;
    debugDisableShadows = shadows;
    WidgetsApp.debugAllowBannerOverride = banner;
    tester.view.reset();
  }
  for (final error in errors) {
    debugPrint('CAPTURE_EXCEPTION $file: $error');
  }
}

Future<void> _render(
  WidgetTester tester,
  CaptureScenario scenario,
  ThemeMode mode,
) async {
  final model = scenario.build()..themeMode = mode;
  await tester.pumpWidget(
    RepaintBoundary(
      key: _imageKey,
      child: WhaleChatApp(model: model),
    ),
  );
  await _settle(tester);
  final act = scenario.act;
  if (act != null) {
    await act(tester, model);
    await _settle(tester);
  }
}

/// Fixed-length pumps: busy states animate forever, so no pumpAndSettle.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _writePng(WidgetTester tester, String path, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_imageKey),
  );
  final line = await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final file = File(path)..parent.createSync(recursive: true);
      file.writeAsBytesSync(
        png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
      return 'CAPTURE_PNG $name ${image.width}x${image.height} '
          '${png.lengthInBytes}B ${_stats(raw!)}';
    } finally {
      image.dispose();
    }
  });
  debugPrint(line ?? 'CAPTURE_PNG $name failed');
}

/// Number of distinct colors, the most common one and its share of pixels.
String _stats(ByteData raw) {
  final pixels = raw.lengthInBytes ~/ 4;
  final counts = <int, int>{};
  for (var i = 0; i < pixels; i++) {
    final rgba = raw.getUint32(i * 4);
    counts[rgba] = (counts[rgba] ?? 0) + 1;
  }
  var top = 0;
  var topCount = 0;
  for (final entry in counts.entries) {
    if (entry.value > topCount) {
      top = entry.key;
      topCount = entry.value;
    }
  }
  final rgb = (top >> 8).toRadixString(16).padLeft(6, '0').toUpperCase();
  final share = pixels == 0 ? 0.0 : 100 * topCount / pixels;
  return 'colors=${counts.length} top=#$rgb ${share.toStringAsFixed(1)}%';
}

final Set<String> _families = {};
ByteData? _cjk;
ByteData? _emoji;
var _baseLoaded = false;

Future<void> _loadBaseFonts() async {
  if (_baseLoaded) return;
  _baseLoaded = true;
  final notes = <String>[];
  try {
    final manifest = json.decode(
      await rootBundle.loadString('FontManifest.json'),
    ) as List<dynamic>;
    for (final entry in manifest.cast<Map<String, dynamic>>()) {
      final family = entry['family'] as String;
      final fonts = (entry['fonts'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final loader = FontLoader(family);
      for (final font in fonts) {
        loader.addFont(rootBundle.load(font['asset'] as String));
      }
      await loader.load();
      _families.add(family);
      notes.add('$family(${fonts.length})');
    }
  } on Object catch (error) {
    notes.add('FontManifest.json failed: ${_firstLine(error)}');
  }
  final dir = '${Platform.environment['WINDIR'] ?? 'C:/Windows'}/Fonts';
  _cjk = _readFont('$dir/msyh.ttc', notes);
  _emoji = _readFont('$dir/seguiemj.ttf', notes);
  notes.addAll(await _alias(const ['Ahem', 'Roboto', 'FlutterTest']));
  debugPrint('CAPTURE_FONTS ${notes.join(', ')}');
}

ByteData? _readFont(String path, List<String> notes) {
  final file = File(path);
  if (file.existsSync()) return ByteData.sublistView(file.readAsBytesSync());
  notes.add('missing $path');
  return null;
}

/// Registers a system font under every family in [families] that is not
/// loaded yet and returns what it registered. Package fonts missing from the
/// manifest are only reported: a text font cannot stand in for icons.
Future<List<String>> _alias(Iterable<String> families) async {
  final added = <String>[];
  for (final family in families) {
    if (!_families.add(family)) continue;
    if (family.startsWith('packages/')) {
      debugPrint('CAPTURE_FONTS missing package font $family');
      continue;
    }
    final emoji = family.toLowerCase().contains('emoji') && _emoji != null;
    final bytes = emoji ? _emoji : _cjk;
    if (bytes == null) continue;
    await (FontLoader(family)..addFont(Future.value(bytes))).load();
    added.add('$family=${emoji ? 'seguiemj' : 'msyh'}');
  }
  return added;
}

/// Font families (and fallbacks) of all laid-out text. Every span is walked,
/// including root spans without text of their own, whose style the children
/// inherit.
Set<String> _usedFamilies(WidgetTester tester) {
  final families = <String>{};
  void walk(InlineSpan? span) {
    if (span == null) return;
    final style = span.style;
    if (style != null) {
      final family = style.fontFamily;
      if (family != null) families.add(family);
      families.addAll(style.fontFamilyFallback ?? const <String>[]);
    }
    if (span is TextSpan) {
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  for (final object in tester.allRenderObjects) {
    if (object is RenderParagraph) {
      walk(object.text);
    } else if (object is RenderEditable) {
      walk(object.text);
    }
  }
  return families;
}
