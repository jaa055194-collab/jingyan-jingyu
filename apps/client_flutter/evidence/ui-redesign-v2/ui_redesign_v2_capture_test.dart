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

/// The user's own AI companion; its direct chat is `xiaojing`.
const ShellOwnedAi sampleCompanion = ShellOwnedAi(
  accountId: 'ai-xiaojing',
  displayName: '小鲸',
  disabled: false,
);

/// Signed in as account-a with [sampleCompanion] as the own AI (signed out
/// and not onboarded when [signedIn] is false), online and without an error
/// unless [online] or [error] say otherwise, nothing queued. Opening a
/// conversation shows its entry in [messagesById] (none when absent).
class CaptureModel extends TestShellModel {
  CaptureModel({
    List<ShellConversation> conversations = sampleConversations,
    this.messagesById = const {},
    bool signedIn = true,
    bool online = true,
    String? error,
  }) {
    onboarded = signedIn;
    chatEntered = signedIn;
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
