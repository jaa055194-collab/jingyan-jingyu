// Sample data for the -data scenarios of ui_redesign_v2_capture_test.dart
// (ticket ui-redesign-v2-58efb3240b0f).
//
// CaptureModel has no host connection, so the shell wires no loaders into
// these pages and they show their offline state. The -data scenarios push the
// pages built here instead. Each page is made with its public constructor and
// only the arguments the widget tests in test/ already pass. Fake loaders
// return the rows below at once; accepting and denying do nothing and the AI
// config writer throws, so nothing reaches a host. The same file renders
// Before (main 0300369) and After: when a redesigned page changes its
// constructor, only this file changes.
//
// Names and ids come from the capture test's sample conversations: the user is
// account-a, 小鲸 is the own AI (account ai-xiaojing, profile
// profile-xiaojing). Nothing here is real personal data.

import 'package:material_ui/material_ui.dart';

import 'package:client_flutter/features/ai_config/ai_config_editor.dart';
import 'package:client_flutter/features/ai_config/ai_config_panel.dart';
import 'package:client_flutter/features/contacts/contacts_screen.dart';
import 'package:client_flutter/features/creative/creative_screen.dart';
import 'package:client_flutter/features/inbox/inbox_screen.dart';
import 'package:client_flutter/features/voice/voice_call_list_screen.dart';
import 'package:client_flutter/features/voice/voice_screen.dart';
import 'package:client_flutter/features/world/world_status_screen.dart';
import 'package:client_flutter/net/ai_config_write_api.dart';
import 'package:client_flutter/net/creative_api.dart';
import 'package:client_flutter/net/friends_api.dart';
import 'package:client_flutter/net/notification_api.dart';
import 'package:client_flutter/net/owner_ai_readiness_api.dart';
import 'package:client_flutter/net/voice_api.dart';
import 'package:client_flutter/net/voice_call_api.dart';

/// The own AI 小鲸: its account and its AI profile.
const String sampleAiAccountId = 'ai-xiaojing';
const String sampleAiProfileId = 'profile-xiaojing';

// 联系人: two incoming friend requests, then two friends.

const List<FriendContact> sampleFriends = [
  FriendContact(
    accountId: 'azhe',
    displayName: '阿哲',
    state: FriendState.incomingPending,
  ),
  FriendContact(
    accountId: 'aqing',
    displayName: '阿青',
    state: FriendState.incomingPending,
  ),
  FriendContact(
    accountId: 'linwu',
    displayName: '林雾',
    state: FriendState.friends,
  ),
  FriendContact(
    accountId: 'mom',
    displayName: '妈妈',
    state: FriendState.friends,
  ),
];

Future<FriendState> _lookupFriend(String accountId) async {
  for (final friend in sampleFriends) {
    if (friend.accountId == accountId) return friend.state;
  }
  return FriendState.none;
}

/// 联系人 with [sampleFriends]; accepting or denying does nothing.
Widget contactsDataPage() => ContactsScreen(
  lookupState: _lookupFriend,
  loadFriends: () async => sampleFriends,
  acceptFriend: (_) async {},
  denyFriend: (_) async {},
);

// 收件箱: the two friend requests (actionable), 小鲸's weekly report notice,
// a group invite and an accepted friend request. Each refId differs: rows
// are keyed by it.

const List<NotificationItem> sampleNotifications = [
  NotificationItem(
    kind: 'friendRequest',
    title: '好友邀请',
    status: 'pending',
    createdAt: '2026-11-25T09:12:00.000Z',
    refId: 'azhe',
  ),
  NotificationItem(
    kind: 'friendRequest',
    title: '好友邀请',
    status: 'pending',
    createdAt: '2026-11-24T20:05:00.000Z',
    refId: 'aqing',
  ),
  NotificationItem(
    kind: 'creativeReport',
    title: '小鲸的周报已生成',
    status: 'unread',
    createdAt: '2026-11-22T13:31:00.000Z',
    refId: sampleAiAccountId,
  ),
  NotificationItem(
    kind: 'groupInvite',
    title: '群聊邀请：周末徒步小队',
    status: 'accepted',
    createdAt: '2026-11-21T08:30:00.000Z',
    refId: 'hiking',
  ),
  NotificationItem(
    kind: 'friendRequest',
    title: '好友邀请',
    status: 'accepted',
    createdAt: '2026-11-18T12:30:00.000Z',
    refId: 'linwu',
  ),
];

final Object _inboxSession = Object();

/// 收件箱 with [sampleNotifications]. InboxScreen has no Scaffold of its own
/// (the shell hosts it), so it gets one here, as in its widget tests.
Widget inboxDataPage() => Scaffold(
  body: InboxScreen(
    loadNotifications: () async => sampleNotifications,
    acceptFriend: (_) async {},
    denyFriend: (_) async {},
    actionContext: () => _inboxSession,
  ),
);

// 动态: the latest weekly report, a missed and a deferred week, last year's
// annual report, and two radio episodes (one cached for offline play).

final List<CreativeReportSummary> sampleReports = [
  CreativeReportSummary(
    aiId: sampleAiProfileId,
    kind: 'weekly',
    periodKey: '2026-11-22',
    status: 'generated',
    report: CreativeReport(
      kind: 'weekly',
      periodKey: '2026-11-22',
      windowStartDay: '2026-11-16',
      windowEndDay: '2026-11-22',
      generatedAt: DateTime.utc(2026, 11, 22, 13, 30),
      commonTopics: const [
        CreativeTopicCount(label: '徒步', count: 4),
        CreativeTopicCount(label: '灯光展', count: 2),
        CreativeTopicCount(label: '读书会', count: 1),
      ],
      completedAgreements: 2,
      checkinDays: 5,
      moodCurve: const {
        '2026-11-18': 3.5,
        '2026-11-20': 4.0,
        '2026-11-22': 4.5,
      },
      letter: '这一周你去看了灯光展，还和徒步小队约好了周末出发。',
      keywords: const [],
      milestones: const [],
      busiestDay: null,
      sourceScopes: const ['privateChat', 'moments'],
    ),
  ),
  const CreativeReportSummary(
    aiId: sampleAiProfileId,
    kind: 'weekly',
    periodKey: '2026-11-15',
    status: 'missed',
  ),
  const CreativeReportSummary(
    aiId: sampleAiProfileId,
    kind: 'weekly',
    periodKey: '2026-11-08',
    status: 'deferred',
  ),
  CreativeReportSummary(
    aiId: sampleAiProfileId,
    kind: 'annual',
    periodKey: '2025',
    status: 'generated',
    report: CreativeReport(
      kind: 'annual',
      periodKey: '2025',
      windowStartDay: '2025-01-01',
      windowEndDay: '2025-12-31',
      generatedAt: DateTime.utc(2026, 1, 1, 9),
      commonTopics: const [
        CreativeTopicCount(label: '旅行', count: 12),
        CreativeTopicCount(label: '读书', count: 9),
        CreativeTopicCount(label: '电影', count: 6),
      ],
      completedAgreements: 18,
      checkinDays: 160,
      moodCurve: const {'2025-08-15': 4.5, '2025-12-31': 4.0},
      letter: '这一年我们一起走过了很多地方。',
      keywords: const ['旅行', '读书', '电影'],
      milestones: const ['2025-08-15 一起看海'],
      busiestDay: '2025-08-15',
      sourceScopes: const ['privateChat', 'moments'],
    ),
  ),
];

final List<CreativeRadioEpisode> sampleRadio = [
  CreativeRadioEpisode(
    aiId: sampleAiProfileId,
    dateKey: '2026-11-25',
    scheduledFor: DateTime.utc(2026, 11, 25, 14),
    generatedAt: DateTime.utc(2026, 11, 25, 13, 50),
    voiceId: 'voice-xiaojing',
    offlineCacheKey: 'cache/2026-11-25',
    playableOffline: true,
    script: const CreativeRadioScript(
      text: '晚安，今天也辛苦了。',
      segments: [CreativeRadioSegment(kind: 'comfort', text: '晚安，今天也辛苦了。')],
    ),
  ),
  CreativeRadioEpisode(
    aiId: sampleAiProfileId,
    dateKey: '2026-11-24',
    scheduledFor: DateTime.utc(2026, 11, 24, 14),
    generatedAt: DateTime.utc(2026, 11, 24, 13, 50),
    voiceId: 'voice-xiaojing',
    offlineCacheKey: 'cache/2026-11-24',
    playableOffline: false,
    script: const CreativeRadioScript(
      text: '明早有雨，出门记得带伞。',
      segments: [CreativeRadioSegment(kind: 'comfort', text: '明早有雨，出门记得带伞。')],
    ),
  ),
];

/// 动态 with [sampleReports] and [sampleRadio].
Widget creativeDataPage() => CreativeScreen(
  loadReports: () async => sampleReports,
  loadRadio: () async => sampleRadio,
);

// 语音音色: 小鲸's voice profile at revision 3 with revision 4 pending.

/// 语音音色; reading any AI profile id returns 小鲸's voice profile under that
/// id (voice-data reads [sampleAiProfileId]).
Widget voiceDataPage() => VoiceScreen(
  loadProfile: (aiId) async => VoiceProfileView.fromJson({
    'aiId': aiId,
    'provider': 'vendor-a',
    'model': 'tts-model-2',
    'voiceId': 'voice-xiaojing',
    'params': {'speed': 1.0, 'pitch': 1.0},
    'revision': 3,
    'consentRef': 'consent-xiaojing-1',
    'activatedAt': '2026-11-20T08:00:00.000Z',
    'pendingRevision': 4,
    'pendingParams': {'speed': 1.1},
  }, expectedAiId: aiId),
);

// 语音通话列表: three calls with 小鲸, newest first.

final List<VoiceCallView> sampleVoiceCalls = [
  VoiceCallView.fromJson({
    'callId': 'call-20261125-1',
    'aiId': sampleAiProfileId,
    'peerAccountId': sampleAiAccountId,
    'state': 'ended',
    'startedAt': '2026-11-25T12:30:00.000Z',
    'answeredAt': '2026-11-25T12:30:04.000Z',
    'endedAt': '2026-11-25T12:41:10.000Z',
  }),
  VoiceCallView.fromJson({
    'callId': 'call-20261124-1',
    'aiId': sampleAiProfileId,
    'peerAccountId': sampleAiAccountId,
    'state': 'missed',
    'startedAt': '2026-11-24T22:05:00.000Z',
  }),
  VoiceCallView.fromJson({
    'callId': 'call-20261123-1',
    'aiId': sampleAiProfileId,
    'peerAccountId': sampleAiAccountId,
    'state': 'ended',
    'startedAt': '2026-11-23T08:15:00.000Z',
    'answeredAt': '2026-11-23T08:15:03.000Z',
    'endedAt': '2026-11-23T08:22:47.000Z',
  }),
];

/// 语音通话列表 with [sampleVoiceCalls], filtered and paged like the host.
Widget voiceCallsDataPage() => VoiceCallListScreen(
  listCalls: ({String? status, required int limit, DateTime? before}) async => [
    for (final call in sampleVoiceCalls)
      if ((status == null || call.state == status) &&
          (before == null || call.startedAt.isBefore(before)))
        call,
  ].take(limit).toList(),
  pageSize: 20,
);

// AI 运行配置体检: persona, bindings and provider configured, budget not.

const AiConfigSnapshot sampleAiConfig = AiConfigSnapshot([
  AiConfigEntry('人格', ConfigurationReadStatus.configurationPresent, [
    '档案：$sampleAiProfileId · 版本 3',
    '人格未锁定',
    'p0 字段：name、style',
    'p1 字段：tone、habits',
    'p2 字段：mood',
  ]),
  AiConfigEntry('绑定', ConfigurationReadStatus.configurationPresent, [
    'chat → provider-main · model-x',
    'tts → provider-main · tts-model-2',
  ]),
  AiConfigEntry('预算', ConfigurationReadStatus.unconfigured, ['未配置']),
  AiConfigEntry('Provider', ConfigurationReadStatus.configurationPresent, [
    'vendor-a',
    'https://llm.example.com/v1',
    '掩码：sk-…7f2c（不是密钥）',
    '已启用',
    '能力：chat、tts',
  ]),
]);

/// AI 运行配置体检 with [sampleAiConfig].
Widget aiConfigCheckDataPage() =>
    AiConfigPanel(load: () async => sampleAiConfig);

/// AI 运行配置 for 小鲸, its profile resolved. Writes throw: no host.
Widget aiConfigEditDataPage() => AiConfigEditor(
  writer: const _SampleWriter(),
  resolveProfileId: (aiAccountId) async => sampleAiProfileId,
  ownedAiAccountIds: const [sampleAiAccountId],
);

class _SampleWriter implements AiConfigWriter {
  const _SampleWriter();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('sample data: no host to write to');
}

// 世界状态 for space home, each section in a different state: the layout is
// read, presence is not found, avatars are denied (lines as the host
// projection in WorldStatusScreen.loadFrom writes them).

const List<WorldSection> sampleWorldSections = [
  WorldSection('世界布局', WorldReadStatus.present, [
    '空间：home · 版本 5',
    '风格：温馨木屋',
    '主色：#6FA8DC',
    '房间 3 个',
    '· 客厅（6 件家具）',
    '· 书房（4 件家具）',
    '· 阳台（2 件家具）',
    '更新：2026-11-24T20:15:00.000Z',
  ]),
  WorldSection('在场', WorldReadStatus.missing, ['未找到（可能不存在或不可见）']),
  WorldSection('形象', WorldReadStatus.denied, ['未认证或无权限']),
];

/// 世界状态 opened on space home with [sampleWorldSections].
Widget worldDataPage() => WorldStatusScreen(
  initialSpaceId: 'home',
  load: (spaceId) async => WorldStatusSnapshot(spaceId, sampleWorldSections),
);
