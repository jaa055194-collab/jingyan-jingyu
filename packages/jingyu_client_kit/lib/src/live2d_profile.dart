/// Device-local Live2D model metadata.
///
/// This contract contains references only. It does not load, package, upload,
/// synchronize, or render model files.
library;

import 'plugin_package.dart';

/// A structurally validated mapping from avatar semantics to model targets.
class Live2DParamMap {
  Live2DParamMap._({
    required this.mouthOpen,
    required this.blinkLeft,
    required this.blinkRight,
    required Map<String, String> expressions,
    required Map<String, String> motions,
  }) : expressions = Map.unmodifiable(expressions),
       motions = Map.unmodifiable(motions);

  final String mouthOpen;
  final String blinkLeft;
  final String blinkRight;
  final Map<String, String> expressions;
  final Map<String, String> motions;

  /// Checks the parsed targets before enabling this map on a loaded model.
  ///
  /// Supply the complete, finite ID sets from that same device-local model,
  /// as enumerated by the runtime, not inferred from filenames or ID patterns.
  /// Matching is exact and separate for each kind; extra IDs are allowed.
  /// Throws [FormatException] for the first target missing from its kind.
  /// This check does not load, activate, or modify the model or profile.
  void validateTargets({
    required Set<String> parameters,
    required Set<String> expressions,
    required Set<String> motions,
  }) {
    // Use exact String equality even if the caller's sets use custom equality.
    final parameterIds = Set<String>.of(parameters);
    final expressionIds = Set<String>.of(expressions);
    final motionIds = Set<String>.of(motions);

    void requireTarget(
      String field,
      String target,
      Set<String> ids,
      String kind,
    ) {
      if (!ids.contains(target)) {
        throw FormatException(
          'paramMap.$field: unknown $kind target "$target"',
        );
      }
    }

    requireTarget('mouthOpen', mouthOpen, parameterIds, 'parameter');
    requireTarget('blinkLeft', blinkLeft, parameterIds, 'parameter');
    requireTarget('blinkRight', blinkRight, parameterIds, 'parameter');
    for (final entry in this.expressions.entries) {
      requireTarget(
        'expressions[${entry.key}]',
        entry.value,
        expressionIds,
        'expression',
      );
    }
    for (final entry in this.motions.entries) {
      requireTarget('motions[${entry.key}]', entry.value, motionIds, 'motion');
    }
  }

  Map<String, Object?> toJson() => {
    'mouthOpen': mouthOpen,
    'blinkLeft': blinkLeft,
    'blinkRight': blinkRight,
    'expressions': expressions,
    'motions': motions,
  };

  factory Live2DParamMap.fromJson(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const FormatException('paramMap must be an object');
    }

    const allowed = {
      'mouthOpen',
      'blinkLeft',
      'blinkRight',
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

    Map<String, String> namedMap(String key) {
      if (!value.containsKey(key)) {
        throw FormatException('paramMap.$key must be explicitly configured');
      }
      final raw = value[key];
      if (raw is! Map<String, Object?> || raw.isEmpty) {
        throw FormatException('paramMap.$key must be a non-empty object');
      }
      final result = <String, String>{};
      for (final entry in raw.entries) {
        final semantic = entry.key.trim();
        final target = entry.value;
        if (semantic.isEmpty || target is! String || target.trim().isEmpty) {
          throw FormatException('paramMap.$key contains an empty mapping');
        }
        result[semantic] = target.trim();
      }
      return Map.unmodifiable(result);
    }

    return Live2DParamMap._(
      mouthOpen: requiredName('mouthOpen'),
      blinkLeft: requiredName('blinkLeft'),
      blinkRight: requiredName('blinkRight'),
      expressions: namedMap('expressions'),
      motions: namedMap('motions'),
    );
  }
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
    if (!_modelIdPattern.hasMatch(modelId)) {
      throw const FormatException('modelId must be a stable identifier');
    }

    final revision = json['profileRev'];
    if (revision is! int || revision < 1) {
      throw const FormatException('profileRev must be a positive integer');
    }

    final modelFile = json['modelFile'];
    if (modelFile is! String ||
        modelFile.trim() != modelFile ||
        !_isSafeModelPath(modelFile)) {
      throw const FormatException('modelFile must be a safe relative path');
    }

    return Live2DProfile._(
      modelId: modelId,
      profileRev: revision,
      modelFile: modelFile,
      paramMap: Live2DParamMap.fromJson(json['paramMap']),
    );
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

  static bool _isSafeModelPath(String value) {
    if (value.isEmpty || value.contains('\u0000') || value.contains(':')) {
      return false;
    }
    final safe = sanitizePackageEntryPath(value);
    if (safe == null || safe != value) return false;
    return safe.toLowerCase().endsWith('.model3.json');
  }
}
