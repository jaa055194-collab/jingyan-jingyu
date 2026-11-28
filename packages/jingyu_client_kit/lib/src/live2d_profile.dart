/// Device-local Live2D model metadata.
///
/// This contract contains references only. It does not load, package, upload,
/// synchronize, or render model files.
library;

import 'live2d_model_info.dart';
import 'plugin_package.dart';

/// A structurally validated mapping from avatar semantics to model targets.
///
/// The mouth and both eyes are always mapped. [expressions] and [motions] may
/// be empty only when the user confirmed that the model has none of that
/// kind, which [noExpressions] and [noMotions] record.
class Live2DParamMap {
  Live2DParamMap._({
    required this.mouthOpen,
    required this.blinkLeft,
    required this.blinkRight,
    required this.noExpressions,
    required this.noMotions,
    required Map<String, String> expressions,
    required Map<String, Live2DMotionTarget> motions,
  }) : expressions = Map.unmodifiable(expressions),
       motions = Map.unmodifiable(motions);

  /// The semantic expression keys: the VRM 1.0 emotion presets.
  static const Set<String> expressionKeys = {
    'neutral',
    'happy',
    'angry',
    'sad',
    'relaxed',
    'surprised',
  };

  /// Most motion mappings one map may hold.
  static const int maxMotions = 64;

  final String mouthOpen;
  final String blinkLeft;
  final String blinkRight;

  /// The user confirmed that the model has no expressions to map.
  final bool noExpressions;

  /// The user confirmed that the model has no motions to map.
  final bool noMotions;

  /// Expression names keyed by a member of [expressionKeys].
  final Map<String, String> expressions;

  /// Motion targets keyed by a non-empty semantic name.
  final Map<String, Live2DMotionTarget> motions;

  /// Lists every target that the loaded model's runtime did not report.
  ///
  /// [info] must come from the `ready` event of this same device-local model.
  /// Only runtime-reported names count, never names inferred from filenames
  /// or ID patterns. Matching is exact and separate for each kind; extra
  /// runtime names are allowed. When the runtime left a kind out, every
  /// target of that kind is listed, with [Live2DTargetMiss.reported] false.
  /// This check does not load, activate, or modify the model or profile.
  List<Live2DTargetMiss> missingTargets(Live2DModelInfo info) {
    final misses = <Live2DTargetMiss>[];
    final ids = info.parameterIds;
    for (final (field, id) in [
      ('mouthOpen', mouthOpen),
      ('blinkLeft', blinkLeft),
      ('blinkRight', blinkRight),
    ]) {
      if (ids == null || !ids.contains(id)) {
        misses.add(
          Live2DTargetMiss._(
            field,
            Live2DTargetKind.parameter,
            id,
            null,
            ids != null,
          ),
        );
      }
    }
    final names = info.expressionNames;
    for (final MapEntry(:key, :value) in expressions.entries) {
      if (names == null || !names.contains(value)) {
        misses.add(
          Live2DTargetMiss._(
            'expressions[$key]',
            Live2DTargetKind.expression,
            value,
            null,
            names != null,
          ),
        );
      }
    }
    for (final MapEntry(:key, :value) in motions.entries) {
      final count = info.motionCount(value.group);
      if (count == null || value.index >= count) {
        misses.add(
          Live2DTargetMiss._(
            'motions[$key]',
            Live2DTargetKind.motion,
            value.group,
            value.index,
            info.motions != null,
          ),
        );
      }
    }
    return List.unmodifiable(misses);
  }

  /// Throws [Live2DTargetException] listing every [missingTargets] entry.
  /// Call it before enabling this map on a loaded model.
  void validateTargets(Live2DModelInfo info) {
    final misses = missingTargets(info);
    if (misses.isNotEmpty) throw Live2DTargetException(misses);
  }

  Map<String, Object?> toJson() => {
    'mouthOpen': mouthOpen,
    'blinkLeft': blinkLeft,
    'blinkRight': blinkRight,
    'noExpressions': noExpressions,
    'noMotions': noMotions,
    'expressions': expressions,
    'motions': {
      for (final entry in motions.entries) entry.key: entry.value.toJson(),
    },
  };

  /// Parses a mapping and applies the D1-B rule.
  ///
  /// `mouthOpen`, `blinkLeft` and `blinkRight` are required. `expressions`
  /// and `motions` must always be present; each may be empty only when its
  /// `noExpressions` or `noMotions` flag is true, and a true flag needs an
  /// empty map. Expression keys must be in [expressionKeys]. Motion values
  /// are `{group, index}` objects.
  factory Live2DParamMap.fromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('paramMap must be an object');
    }

    const allowed = {
      'mouthOpen',
      'blinkLeft',
      'blinkRight',
      'noExpressions',
      'noMotions',
      'expressions',
      'motions',
    };
    if (value.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('unknown paramMap field');
    }

    String requiredName(String key) {
      final name = value[key];
      if (name is! String || name.trim().isEmpty) {
        throw FormatException('paramMap.$key must be a non-empty string');
      }
      return name.trim();
    }

    final mouthOpen = requiredName('mouthOpen');
    final blinkLeft = requiredName('blinkLeft');
    final blinkRight = requiredName('blinkRight');

    // D1-B: an empty map needs its "this model has none" flag, and a true
    // flag needs an empty map.
    Map<String, Object?> namedMap(String key, String flag) {
      final none = value[flag];
      if (none is! bool) {
        throw FormatException('paramMap.$flag must be true or false');
      }
      if (!value.containsKey(key)) {
        throw FormatException('paramMap.$key must be explicitly configured');
      }
      final raw = value[key];
      if (raw is! Map<String, Object?>) {
        throw FormatException('paramMap.$key must be an object');
      }
      if (none && raw.isNotEmpty) {
        throw FormatException('paramMap.$key must be empty when $flag is true');
      }
      if (!none && raw.isEmpty) {
        throw FormatException(
          'paramMap.$key may be empty only when $flag is true',
        );
      }
      return raw;
    }

    String semanticKey(String field, String key, Map<String, Object?> seen) {
      final semantic = key.trim();
      if (semantic.isEmpty) {
        throw FormatException('paramMap.$field contains an empty mapping');
      }
      if (seen.containsKey(semantic)) {
        throw FormatException('paramMap.$field repeats the key "$semantic"');
      }
      return semantic;
    }

    final expressions = <String, String>{};
    for (final entry in namedMap('expressions', 'noExpressions').entries) {
      final semantic = semanticKey('expressions', entry.key, expressions);
      if (!expressionKeys.contains(semantic)) {
        throw FormatException(
          'paramMap.expressions key "$semantic" must be one of '
          '${expressionKeys.join(', ')}',
        );
      }
      final target = entry.value;
      if (target is! String || target.trim().isEmpty) {
        throw const FormatException(
          'paramMap.expressions contains an empty mapping',
        );
      }
      expressions[semantic] = target.trim();
    }

    final rawMotions = namedMap('motions', 'noMotions');
    if (rawMotions.length > maxMotions) {
      throw FormatException(
        'paramMap.motions holds more than $maxMotions mappings',
      );
    }
    final motions = <String, Live2DMotionTarget>{};
    for (final entry in rawMotions.entries) {
      final semantic = semanticKey('motions', entry.key, motions);
      motions[semantic] = Live2DMotionTarget._fromJson(
        entry.value,
        'paramMap.motions[$semantic]',
      );
    }

    return Live2DParamMap._(
      mouthOpen: mouthOpen,
      blinkLeft: blinkLeft,
      blinkRight: blinkRight,
      noExpressions: value['noExpressions'] == true,
      noMotions: value['noMotions'] == true,
      expressions: expressions,
      motions: motions,
    );
  }
}

/// One motion as the runtime addresses it: a model3 motion group and the
/// motion's index in that group.
final class Live2DMotionTarget {
  const Live2DMotionTarget._(this.group, this.index);

  /// The group name exactly as in model3. Cubism allows an empty one.
  final String group;

  /// The motion's index in [group], from 0.
  final int index;

  Map<String, Object?> toJson() => {'group': group, 'index': index};

  static Live2DMotionTarget _fromJson(Object? value, String field) {
    if (value is! Map<String, Object?>) {
      throw FormatException('$field must be an object');
    }
    if (value.keys.any((key) => key != 'group' && key != 'index')) {
      throw FormatException('$field has an unknown field');
    }
    final group = value['group'];
    if (group is! String || group.length > Live2DModelInfo.maxIdLength) {
      throw FormatException(
        '$field.group must be a string of at most '
        '${Live2DModelInfo.maxIdLength} characters',
      );
    }
    final index = value['index'];
    if (index is! int ||
        index < 0 ||
        index >= Live2DModelInfo.maxMotionsPerGroup) {
      throw FormatException(
        '$field.index must be an integer from 0 to '
        '${Live2DModelInfo.maxMotionsPerGroup - 1}',
      );
    }
    return Live2DMotionTarget._(group, index);
  }

  @override
  bool operator ==(Object other) =>
      other is Live2DMotionTarget &&
      other.group == group &&
      other.index == index;

  @override
  int get hashCode => Object.hash(group, index);

  @override
  String toString() => 'Live2DMotionTarget("$group", $index)';
}

/// The kind of model target that a mapping names.
enum Live2DTargetKind { parameter, expression, motion }

/// One mapped target that the loaded model's runtime did not report.
final class Live2DTargetMiss {
  const Live2DTargetMiss._(
    this.field,
    this.kind,
    this.target,
    this.index,
    this.reported,
  );

  /// The mapping field, such as `mouthOpen`, `expressions[happy]` or
  /// `motions[idle]`.
  final String field;

  final Live2DTargetKind kind;

  /// The parameter ID, expression name or motion group that was not found.
  final String target;

  /// The motion index in [target], for a motion only.
  final int? index;

  /// False when the runtime left this kind out of its `ready` event, so no
  /// target of the kind could be checked.
  final bool reported;

  @override
  String toString() {
    final name = index == null ? '"$target"' : '"$target" index $index';
    if (!reported) {
      return 'paramMap.$field: the runtime did not report ${kind.name}s, '
          'so ${kind.name} target $name cannot be checked';
    }
    return 'paramMap.$field: unknown ${kind.name} target $name';
  }
}

/// Thrown when a mapping names targets that the loaded model's runtime did
/// not report. [misses] lists every one, in mapping order.
final class Live2DTargetException extends FormatException {
  Live2DTargetException(List<Live2DTargetMiss> misses)
    : misses = List.unmodifiable(misses),
      super(misses.join('; '));

  final List<Live2DTargetMiss> misses;
}

/// A local model reference and its per-model semantic mapping revision.
class Live2DProfile {
  Live2DProfile._({
    required this.modelId,
    required this.profileRev,
    required this.modelFile,
    required this.paramMap,
  });

  final String modelId;
  final int profileRev;
  final String modelFile;
  final Live2DParamMap paramMap;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'modelId': modelId,
    'profileRev': profileRev,
    'modelFile': modelFile,
    'paramMap': paramMap.toJson(),
  };

  /// Parses profile metadata without touching the referenced file system path.
  factory Live2DProfile.fromJson(Map<String, Object?> json) {
    const allowed = {
      'schemaVersion',
      'modelId',
      'profileRev',
      'modelFile',
      'paramMap',
    };
    if (json.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('unknown Live2D profile field');
    }
    if (json['schemaVersion'] is! int || json['schemaVersion'] != 1) {
      throw const FormatException('unsupported Live2D profile schemaVersion');
    }

    final modelId = _requiredString(json, 'modelId');
    if (!isValidModelId(modelId)) {
      throw const FormatException('modelId must be a stable identifier');
    }

    final revision = json['profileRev'];
    if (revision is! int || revision < 1) {
      throw const FormatException('profileRev must be a positive integer');
    }

    final modelFile = json['modelFile'];
    if (modelFile is! String ||
        modelFile.trim() != modelFile ||
        !isSafeModelFile(modelFile) ||
        !modelFile.toLowerCase().endsWith('.model3.json')) {
      throw const FormatException('modelFile must be a safe relative path');
    }

    return Live2DProfile._(
      modelId: modelId,
      profileRev: revision,
      modelFile: modelFile,
      paramMap: Live2DParamMap.fromJson(json['paramMap']),
    );
  }

  /// Whether [id] can name a stored model.
  ///
  /// The whole [id] must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`, and in
  /// lower case it must not end with `.pending` or `.old`, which the file
  /// store uses for its staging directories. The Kotlin route
  /// apps/client_flutter/android/app/src/main/kotlin/com/jingyu/client_flutter/Live2DViewerRoutes.kt
  /// mirrors this rule and [isSafeModelFile]: change them together.
  static bool isValidModelId(String id) {
    if (!_modelIdPattern.hasMatch(id)) return false;
    final lower = id.toLowerCase();
    return !lower.endsWith('.pending') && !lower.endsWith('.old');
  }

  /// The file types a stored model may hold, matched case-insensitively
  /// against the end of a path.
  static const List<String> modelFileTypes = [
    '.model3.json',
    '.moc3',
    '.png',
    '.exp3.json',
    '.motion3.json',
    '.physics3.json',
    '.pose3.json',
  ];

  /// Whether [path] is a safe relative path to a file of one of the
  /// [modelFileTypes]: [sanitizePackageEntryPath] must return it unchanged.
  static bool isSafeModelFile(String path) {
    if (sanitizePackageEntryPath(path) != path) return false;
    final lower = path.toLowerCase();
    return modelFileTypes.any(lower.endsWith);
  }

  static final RegExp _modelIdPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
  );

  static String _requiredString(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key must be a non-empty string');
    }
    return value.trim();
  }
}
