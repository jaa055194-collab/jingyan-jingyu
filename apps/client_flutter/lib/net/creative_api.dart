import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// Strict, typed read-only access to the merged host creative endpoints.
///
/// The adapter is bound to one authenticated [HostConnection]; it never accepts
/// an owner id from callers, never mutates consent or generation state, and
/// performs no local caching, polling or inference. Existing bounded host 401
/// renewal is inherited (one replay); transport/parse failures fail safely.
class CreativeTopicCount {
  const CreativeTopicCount({required this.label, required this.count});
  final String label;
  final int count;
}

class CreativeReport {
  const CreativeReport({
    required this.kind,
    required this.periodKey,
    required this.windowStartDay,
    required this.windowEndDay,
    required this.generatedAt,
    required this.commonTopics,
    required this.completedAgreements,
    required this.checkinDays,
    required this.moodCurve,
    required this.letter,
    required this.keywords,
    required this.milestones,
    required this.busiestDay,
    required this.sourceScopes,
  });

  final String kind;
  final String periodKey;
  final String windowStartDay;
  final String windowEndDay;
  final DateTime generatedAt;
  final List<CreativeTopicCount> commonTopics;
  final int completedAgreements;
  final int checkinDays;
  final Map<String, double> moodCurve;
  final String letter;
  final List<String> keywords;
  final List<String> milestones;
  final String? busiestDay;
  final List<String> sourceScopes;

  factory CreativeReport.fromJson(Map<String, Object?> json) {
    try {
      _exact(json, const {
        'kind',
        'periodKey',
        'windowStartDay',
        'windowEndDay',
        'generatedAt',
        'commonTopics',
        'completedAgreements',
        'checkinDays',
        'moodCurve',
        'letter',
        'keywords',
        'milestones',
        'busiestDay',
        'sourceScopes',
      });
      final topics = <CreativeTopicCount>[];
      for (final raw in _list(json['commonTopics'])) {
        final topic = _asMap(raw);
        _exact(topic, const {'label', 'count'});
        topics.add(
          CreativeTopicCount(
            label: _string(topic['label']),
            count: _nonNegativeInt(topic['count']),
          ),
        );
      }
      final moodRaw = _asMap(json['moodCurve']);
      final mood = <String, double>{
        for (final entry in moodRaw.entries) entry.key: _double(entry.value),
      };
      final busiest = json['busiestDay'];
      if (busiest != null && busiest is! String) throw const FormatException();
      return CreativeReport(
        kind: _reportKind(json['kind']),
        periodKey: _id(json['periodKey']),
        windowStartDay: _id(json['windowStartDay']),
        windowEndDay: _id(json['windowEndDay']),
        generatedAt: _utc(json['generatedAt']),
        commonTopics: List.unmodifiable(topics),
        completedAgreements: _nonNegativeInt(json['completedAgreements']),
        checkinDays: _nonNegativeInt(json['checkinDays']),
        moodCurve: Map.unmodifiable(mood),
        letter: _string(json['letter']),
        keywords: List.unmodifiable(_strings(json['keywords'])),
        milestones: List.unmodifiable(_strings(json['milestones'])),
        busiestDay: busiest as String?,
        sourceScopes: List.unmodifiable(_scopes(json['sourceScopes'])),
      );
    } on FormatException {
      throw const FormatException('关系报告响应无效');
    }
  }
}

class CreativeReportSummary {
  const CreativeReportSummary({
    required this.aiId,
    required this.kind,
    required this.periodKey,
    required this.status,
    this.report,
  });

  final String aiId;
  final String kind;
  final String periodKey;
  final String status;
  final CreativeReport? report;

  factory CreativeReportSummary.fromJson(Map<String, Object?> json) {
    try {
      final allowed = {'aiId', 'kind', 'periodKey', 'status', 'report'};
      if (json.keys.any((key) => !allowed.contains(key)) ||
          const [
            'aiId',
            'kind',
            'periodKey',
            'status',
          ].any((key) => !json.containsKey(key))) {
        throw const FormatException();
      }
      final rawReport = json['report'];
      final status = _reportStatus(json['status']);
      if (rawReport != null && status != 'generated') {
        throw const FormatException();
      }
      return CreativeReportSummary(
        aiId: _id(json['aiId']),
        kind: _reportKind(json['kind']),
        periodKey: _id(json['periodKey']),
        status: status,
        report: rawReport == null
            ? null
            : CreativeReport.fromJson(_asMap(rawReport)),
      );
    } on FormatException {
      throw const FormatException('关系报告列表响应无效');
    }
  }
}

class CreativeRadioSegment {
  const CreativeRadioSegment({required this.kind, required this.text});
  final String kind;
  final String text;
}

class CreativeRadioScript {
  const CreativeRadioScript({required this.text, required this.segments});
  final String text;
  final List<CreativeRadioSegment> segments;
}

class CreativeRadioEpisode {
  const CreativeRadioEpisode({
    required this.aiId,
    required this.dateKey,
    required this.scheduledFor,
    required this.generatedAt,
    required this.voiceId,
    required this.offlineCacheKey,
    required this.playableOffline,
    required this.script,
  });

  final String aiId;
  final String dateKey;
  final DateTime scheduledFor;
  final DateTime generatedAt;
  final String voiceId;
  final String offlineCacheKey;
  final bool playableOffline;
  final CreativeRadioScript script;

  factory CreativeRadioEpisode.fromJson(Map<String, Object?> json) {
    try {
      _exact(json, const {
        'aiId',
        'dateKey',
        'scheduledFor',
        'generatedAt',
        'voiceId',
        'offlineCacheKey',
        'playableOffline',
        'script',
      });
      final scriptRaw = _asMap(json['script']);
      _exact(scriptRaw, const {'text', 'segments'});
      final segments = <CreativeRadioSegment>[];
      for (final raw in _list(scriptRaw['segments'])) {
        final segment = _asMap(raw);
        _exact(segment, const {'kind', 'text'});
        segments.add(
          CreativeRadioSegment(
            kind: _string(segment['kind']),
            text: _string(segment['text']),
          ),
        );
      }
      final playable = json['playableOffline'];
      if (playable is! bool) throw const FormatException();
      return CreativeRadioEpisode(
        aiId: _id(json['aiId']),
        dateKey: _id(json['dateKey']),
        scheduledFor: _utc(json['scheduledFor']),
        generatedAt: _utc(json['generatedAt']),
        voiceId: _id(json['voiceId']),
        offlineCacheKey: _string(json['offlineCacheKey']),
        playableOffline: playable,
        script: CreativeRadioScript(
          text: _string(scriptRaw['text']),
          segments: List.unmodifiable(segments),
        ),
      );
    } on FormatException {
      throw const FormatException('电台期次响应无效');
    }
  }
}

class CreativeApi {
  CreativeApi(this._connection);
  final HostConnection _connection;

  static const _kinds = {'weekly', 'annual'};

  Future<List<CreativeReportSummary>> listReports({
    bool retryAuthentication = true,
  }) async {
    final response = await _request(
      Routes.creativeReports,
      retryAuthentication: retryAuthentication,
      invalidResponse: '关系报告列表响应无效',
    );
    _exact(response, const {'reports'});
    return List.unmodifiable([
      for (final raw in _list(response['reports']))
        CreativeReportSummary.fromJson(_asMap(raw)),
    ]);
  }

  Future<CreativeReport> getReport({
    required String aiId,
    required String kind,
    required String periodKey,
    bool retryAuthentication = true,
  }) async {
    final path = _reportPath(aiId: aiId, kind: kind, periodKey: periodKey);
    final response = await _request(
      path,
      retryAuthentication: retryAuthentication,
      invalidResponse: '关系报告响应无效',
    );
    return CreativeReport.fromJson(response);
  }

  Future<List<CreativeRadioEpisode>> listRadio({
    bool retryAuthentication = true,
  }) async {
    final response = await _request(
      Routes.creativeRadio,
      retryAuthentication: retryAuthentication,
      invalidResponse: '电台列表响应无效',
    );
    _exact(response, const {'episodes'});
    return List.unmodifiable([
      for (final raw in _list(response['episodes']))
        CreativeRadioEpisode.fromJson(_asMap(raw)),
    ]);
  }

  Future<CreativeRadioEpisode> getRadio({
    required String aiId,
    required String dateKey,
    bool retryAuthentication = true,
  }) async {
    final safeAi = _id(aiId);
    final safeDate = _id(dateKey);
    final path = Routes.creativeRadioEpisode
        .replaceFirst('{aiId}', Uri.encodeComponent(safeAi))
        .replaceFirst('{dateKey}', Uri.encodeComponent(safeDate));
    final response = await _request(
      path,
      retryAuthentication: retryAuthentication,
      invalidResponse: '电台期次响应无效',
    );
    return CreativeRadioEpisode.fromJson(response);
  }

  String _reportPath({
    required String aiId,
    required String kind,
    required String periodKey,
  }) {
    final safeAi = _id(aiId);
    if (!_kinds.contains(kind)) throw const FormatException('关系报告参数无效');
    final safePeriod = _id(periodKey);
    return Routes.creativeReport
        .replaceFirst('{aiId}', Uri.encodeComponent(safeAi))
        .replaceFirst('{kind}', Uri.encodeComponent(kind))
        .replaceFirst('{periodKey}', Uri.encodeComponent(safePeriod));
  }

  Future<Map<String, Object?>> _request(
    String path, {
    required bool retryAuthentication,
    required String invalidResponse,
  }) async {
    try {
      return await _connection.request(
        'GET',
        path,
        retryAuthentication: retryAuthentication,
      );
    } on FormatException {
      throw FormatException(invalidResponse);
    } on SocketException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on HttpException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on TimeoutException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    }
  }
}

// ---- strict, source-free parsing helpers ----

void _exact(Map<String, Object?> json, Set<String> fields) {
  if (json.length != fields.length ||
      json.keys.any((key) => !fields.contains(key))) {
    throw const FormatException();
  }
}

Map<String, Object?> _asMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw const FormatException();
}

List<Object?> _list(Object? value) {
  if (value is List) return value.cast<Object?>();
  throw const FormatException();
}

String _string(Object? value) {
  if (value is String) return value;
  throw const FormatException();
}

String _id(Object? value) {
  final text = _string(value);
  try {
    validateId(text);
  } on FormatException {
    // Never echo caller- or host-supplied identifiers into a surfaced error.
    throw const FormatException();
  }
  return text;
}

int _nonNegativeInt(Object? value) {
  if (value is int && value >= 0) return value;
  throw const FormatException();
}

double _double(Object? value) {
  if (value is num && value.isFinite) return value.toDouble();
  throw const FormatException();
}

DateTime _utc(Object? value) {
  final text = _string(value);
  final parsed = DateTime.tryParse(text);
  if (parsed == null || !parsed.isUtc) throw const FormatException();
  return parsed;
}

String _reportKind(Object? value) {
  final text = _string(value);
  if (text != 'weekly' && text != 'annual') throw const FormatException();
  return text;
}

String _reportStatus(Object? value) {
  final text = _string(value);
  if (text != 'generated' && text != 'missed' && text != 'deferred') {
    throw const FormatException();
  }
  return text;
}

List<String> _strings(Object? value) {
  return [for (final item in _list(value)) _string(item)];
}

List<String> _scopes(Object? value) {
  final names = _stringList(value);
  for (final name in names) {
    if (name != 'privateChat' && name != 'groupChat' && name != 'moments') {
      throw const FormatException();
    }
  }
  return names;
}

List<String> _stringList(Object? value) => [
  for (final item in _list(value)) _string(item),
];
