/// Device-local Live2D model/profile registry and active-selection state.
///
/// Pure Dart, no file system or network. The host UI/shell owns persistence;
/// this type holds the per-device records and produces a JSON snapshot that
/// contains references and mappings only (never model bytes or absolute paths).
library;

import 'live2d_profile.dart';

class Live2DModelStore {
  Live2DModelStore();

  final Map<String, Live2DProfile> _models = <String, Live2DProfile>{};
  String? _activeModelId;

  List<Live2DProfile> get models {
    final list = _models.values.toList()
      ..sort((a, b) => a.modelId.compareTo(b.modelId));
    return List<Live2DProfile>.unmodifiable(list);
  }

  String? get activeModelId => _activeModelId;

  Live2DProfile? get active =>
      _activeModelId == null ? null : _models[_activeModelId];

  /// Insert or replace a profile. Same modelId requires a strictly greater
  /// profileRev; otherwise [FormatException] (no silent overwrite).
  void save(Live2DProfile profile) {
    final existing = _models[profile.modelId];
    if (existing != null && profile.profileRev <= existing.profileRev) {
      throw FormatException(
        'profileRev ${profile.profileRev} must exceed ${existing.profileRev}',
      );
    }
    _models[profile.modelId] = profile;
  }

  /// Removes a model; clears active selection when it pointed at that model.
  bool remove(String modelId) {
    final removed = _models.remove(modelId) != null;
    if (removed && _activeModelId == modelId) _activeModelId = null;
    return removed;
  }

  /// Selects an existing model; unknown id throws [StateError].
  void setActive(String modelId) {
    if (!_models.containsKey(modelId)) {
      throw StateError('unknown model $modelId');
    }
    _activeModelId = modelId;
  }

  void clearActive() => _activeModelId = null;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    if (_activeModelId != null) 'activeModelId': _activeModelId,
    'models': [for (final model in models) model.toJson()],
  };

  /// Parses a snapshot atomically: any invalid entry leaves no partial store.
  factory Live2DModelStore.fromJson(Map<String, Object?> json) {
    const allowed = {'schemaVersion', 'activeModelId', 'models'};
    if (json.keys.any((key) => !allowed.contains(key)) ||
        json['schemaVersion'] != 1) {
      throw const FormatException('invalid Live2D model store snapshot');
    }
    final rawModels = json['models'];
    if (rawModels is! List) {
      throw const FormatException('models must be a list');
    }
    final store = Live2DModelStore();
    for (final raw in rawModels) {
      if (raw is! Map<String, Object?>) {
        throw const FormatException('model entry must be an object');
      }
      final profile = Live2DProfile.fromJson(raw);
      if (store._models.containsKey(profile.modelId)) {
        throw FormatException('duplicate modelId ${profile.modelId}');
      }
      store._models[profile.modelId] = profile;
    }
    final active = json['activeModelId'];
    if (active != null) {
      if (active is! String || !store._models.containsKey(active)) {
        throw const FormatException('activeModelId does not reference a model');
      }
      store._activeModelId = active;
    }
    return store;
  }
}
