/// What the Live2D viewer reports about a loaded model.
///
/// The viewer adds these lists to its `ready` event
/// (`packages/jingyu_live2d_web/web/live2d_viewer.js`). They are the
/// runtime's own enumeration of the model, the complete ID sets that
/// `Live2DParamMap.validateTargets` asks for; nothing here is inferred from
/// file names or ID patterns.
library;

/// One model parameter as the runtime enumerates it.
final class Live2DParameterInfo {
  const Live2DParameterInfo._({
    required this.id,
    this.min,
    this.max,
    this.defaultValue,
  });

  final String id;

  /// The runtime's minimum value, or null when the viewer reported none.
  final double? min;

  /// The runtime's maximum value, or null when the viewer reported none.
  final double? max;

  /// The runtime's default value, or null when the viewer reported none.
  final double? defaultValue;
}

/// One model3 `FileReferences.Motions` group as the runtime reports it.
final class Live2DMotionGroupInfo {
  const Live2DMotionGroupInfo._({required this.group, required this.count});

  /// The group name exactly as in model3; Cubism allows an empty one.
  final String group;

  /// How many of the group's motions were staged and loaded. A mapping may
  /// use index 0 up to, not including, this count.
  final int count;
}

/// The model information carried by one viewer `ready` event.
///
/// The viewer sends each list whole or leaves it out, never cut short. A null
/// list means the runtime could not enumerate that kind: treat those IDs as
/// unknown, never as empty.
final class Live2DModelInfo {
  Live2DModelInfo._({
    required List<Live2DParameterInfo>? parameters,
    required List<String>? parts,
    required List<String>? expressions,
    required List<Live2DMotionGroupInfo>? motions,
  }) : parameters = parameters == null ? null : List.unmodifiable(parameters),
       parameterIds = parameters == null
           ? null
           : Set.unmodifiable(parameters.map((parameter) => parameter.id)),
       _parametersById = parameters == null
           ? null
           : Map.unmodifiable({
               for (final parameter in parameters) parameter.id: parameter,
             }),
       parts = parts == null ? null : List.unmodifiable(parts),
       partIds = parts == null ? null : Set.unmodifiable(parts),
       expressions = expressions == null
           ? null
           : List.unmodifiable(expressions),
       expressionNames = expressions == null
           ? null
           : Set.unmodifiable(expressions),
       motions = motions == null ? null : List.unmodifiable(motions),
       _motionCounts = motions == null
           ? null
           : Map.unmodifiable({
               for (final motion in motions) motion.group: motion.count,
             });

  /// Most entries one list may hold; the viewer leaves out a longer one.
  static const int maxEntries = 4096;

  /// Longest ID accepted, in UTF-16 code units.
  static const int maxIdLength = 256;

  /// Most expressions the `expressions` list may hold.
  static const int maxExpressions = 1024;

  /// Highest motion count one `motions` group may report.
  static const int maxMotionsPerGroup = 1024;

  /// Expression names in model3 order, or null when they were not reported.
  final List<String>? expressions;

  /// The names in [expressions] as a set, or null when they were not reported.
  final Set<String>? expressionNames;

  /// Motion groups in model3 order, or null when they were not reported.
  final List<Live2DMotionGroupInfo>? motions;

  final Map<String, int>? _motionCounts;

  /// How many motions the group named exactly [group] reported, or null when
  /// there is no such group or the motions were not reported.
  int? motionCount(String group) => _motionCounts?[group];

  /// Parameters in runtime order, or null when they were not reported.
  final List<Live2DParameterInfo>? parameters;

  /// The IDs of [parameters], or null when they were not reported.
  final Set<String>? parameterIds;

  /// Part IDs in runtime order, or null when they were not reported.
  final List<String>? parts;

  /// The IDs of [parts] as a set, or null when they were not reported.
  final Set<String>? partIds;

  final Map<String, Live2DParameterInfo>? _parametersById;

  /// The parameter with this exact [id], or null when there is none or the
  /// parameters were not reported.
  Live2DParameterInfo? parameter(String id) => _parametersById?[id];

  /// Reads the `parameters`, `parts`, `expressions` and `motions` fields of a
  /// viewer `ready` event.
  ///
  /// An absent or null field leaves that list null. Throws [FormatException]
  /// when a field that is present is malformed: not a list, more than
  /// [maxEntries] entries, an ID that is not a non-empty string of at most
  /// [maxIdLength] characters, a repeated ID, a range value that is not a
  /// finite number, or a minimum above the maximum. `expressions` holds at
  /// most [maxExpressions] names. Each `motions` entry needs a `group` string
  /// of at most [maxIdLength] characters, which may be empty but must not
  /// repeat, and an integer `count` from 1 to [maxMotionsPerGroup]. Other
  /// fields, including unknown keys inside an entry, are not read.
  factory Live2DModelInfo.fromReadyEvent(Map<String, Object?> event) {
    return Live2DModelInfo._(
      parameters: _readParameters(event['parameters']),
      parts: _readParts(event['parts']),
      expressions: _readExpressions(event['expressions']),
      motions: _readMotions(event['motions']),
    );
  }

  static List<Live2DParameterInfo>? _readParameters(Object? raw) {
    if (raw == null) return null;
    final entries = _readList(raw, 'parameters');
    final seen = <String>{};
    final result = <Live2DParameterInfo>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry is! Map<String, Object?>) {
        throw FormatException('parameters[$i] must be an object');
      }
      final id = _readId(entry['id'], 'parameters[$i].id', seen);
      final min = _readFinite(entry['min'], 'parameters[$i].min');
      final max = _readFinite(entry['max'], 'parameters[$i].max');
      if (min != null && max != null && min > max) {
        throw FormatException('parameters[$i] has a minimum above its maximum');
      }
      result.add(
        Live2DParameterInfo._(
          id: id,
          min: min,
          max: max,
          defaultValue: _readFinite(entry['default'], 'parameters[$i].default'),
        ),
      );
    }
    return result;
  }

  static List<String>? _readParts(Object? raw) {
    if (raw == null) return null;
    final entries = _readList(raw, 'parts');
    final seen = <String>{};
    return [
      for (var i = 0; i < entries.length; i++)
        _readId(entries[i], 'parts[$i]', seen),
    ];
  }

  static List<String>? _readExpressions(Object? raw) {
    if (raw == null) return null;
    final entries = _readList(raw, 'expressions');
    if (entries.length > maxExpressions) {
      throw FormatException(
        'expressions has more than $maxExpressions entries',
      );
    }
    final seen = <String>{};
    return [
      for (var i = 0; i < entries.length; i++)
        _readId(entries[i], 'expressions[$i]', seen),
    ];
  }

  static List<Live2DMotionGroupInfo>? _readMotions(Object? raw) {
    if (raw == null) return null;
    final entries = _readList(raw, 'motions');
    final seen = <String>{};
    final result = <Live2DMotionGroupInfo>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry is! Map<String, Object?>) {
        throw FormatException('motions[$i] must be an object');
      }
      final group = entry['group'];
      if (group is! String || group.length > maxIdLength) {
        throw FormatException(
          'motions[$i].group must be a string of at most $maxIdLength '
          'characters',
        );
      }
      if (!seen.add(group)) {
        throw FormatException('motions[$i].group repeats an earlier group');
      }
      final count = entry['count'];
      if (count is! int || count < 1 || count > maxMotionsPerGroup) {
        throw FormatException(
          'motions[$i].count must be an integer from 1 to $maxMotionsPerGroup',
        );
      }
      result.add(Live2DMotionGroupInfo._(group: group, count: count));
    }
    return result;
  }

  static List<Object?> _readList(Object raw, String field) {
    if (raw is! List<Object?>) {
      throw FormatException('$field must be a list');
    }
    if (raw.length > maxEntries) {
      throw FormatException('$field has more than $maxEntries entries');
    }
    return raw;
  }

  static String _readId(Object? value, String field, Set<String> seen) {
    if (value is! String || value.isEmpty || value.length > maxIdLength) {
      throw FormatException(
        '$field must be a non-empty string of at most $maxIdLength characters',
      );
    }
    if (!seen.add(value)) {
      throw FormatException('$field repeats an earlier ID');
    }
    return value;
  }

  static double? _readFinite(Object? value, String field) {
    if (value == null) return null;
    if (value is! num || !value.isFinite) {
      throw FormatException('$field must be a finite number');
    }
    return value.toDouble();
  }
}
