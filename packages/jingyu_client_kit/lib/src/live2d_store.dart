/// Device-local Live2D model/profile registry and active-selection state.
///
/// [Live2DModelStore] is pure Dart, with no file system or network: the host
/// UI/shell owns its persistence. It holds the per-device records and produces
/// a JSON snapshot that contains references and mappings only (never model
/// bytes or absolute paths). [Live2DFileStore] keeps models, profiles and the
/// active selection in a directory that the app passes in.
library;

import 'live2d_file_store_stub.dart'
    if (dart.library.io) 'live2d_file_store_io.dart';
import 'live2d_model_info.dart';
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
  ///
  /// When [info] is given, it must come from the `ready` event of that model,
  /// and the model's mapping must pass [Live2DParamMap.validateTargets]
  /// against it, which throws [Live2DTargetException] listing every missing
  /// target. The selection is unchanged when this throws.
  void setActive(String modelId, {Live2DModelInfo? info}) {
    final profile = _models[modelId];
    if (profile == null) {
      throw StateError('unknown model $modelId');
    }
    if (info != null) profile.paramMap.validateTargets(info);
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

/// One model in a [Live2DFileStore]: its entry in `models.json`.
final class Live2DStoredModel {
  /// Throws [FormatException] for an invalid [id] or [model3], or for a
  /// [displayName] that is empty after trimming or longer than
  /// [maxDisplayNameLength].
  factory Live2DStoredModel({
    required String id,
    required String displayName,
    required DateTime importedAt,
    required String model3,
  }) {
    if (!Live2DProfile.isValidModelId(id)) {
      throw FormatException('invalid model ID "$id"');
    }
    final name = displayName.trim();
    if (name.isEmpty || name.length > maxDisplayNameLength) {
      throw const FormatException(
        'displayName must be 1 to $maxDisplayNameLength characters',
      );
    }
    if (!Live2DProfile.isSafeModelFile(model3) ||
        !model3.toLowerCase().endsWith('.model3.json')) {
      throw FormatException('model3 "$model3" is not a safe .model3.json path');
    }
    return Live2DStoredModel._(id, name, importedAt.toUtc(), model3);
  }

  const Live2DStoredModel._(
    this.id,
    this.displayName,
    this.importedAt,
    this.model3,
  );

  /// Longest [displayName], in UTF-16 code units.
  static const int maxDisplayNameLength = 256;

  /// The model ID, which also names the model directory `models/<id>/`.
  final String id;

  final String displayName;

  /// When the current files were imported, in UTC.
  final DateTime importedAt;

  /// The model3 file, relative to the model directory.
  final String model3;

  Map<String, Object?> toJson() => {
    'id': id,
    'displayName': displayName,
    'importedAt': importedAt.toIso8601String(),
    'model3': model3,
  };

  /// Parses one `models.json` entry, which must have exactly the fields that
  /// [toJson] writes. Throws [FormatException] otherwise.
  factory Live2DStoredModel.fromJson(Object? value) {
    if (value is! Map<String, Object?> ||
        value.length != _fields.length ||
        value.keys.any((key) => !_fields.contains(key))) {
      throw const FormatException(
        'a model entry must have exactly id, displayName, importedAt '
        'and model3',
      );
    }
    final id = value['id'];
    final displayName = value['displayName'];
    final importedAt = value['importedAt'];
    final model3 = value['model3'];
    if (id is! String ||
        displayName is! String ||
        importedAt is! String ||
        model3 is! String) {
      throw const FormatException('model entry fields must be strings');
    }
    final time = DateTime.tryParse(importedAt);
    if (time == null) {
      throw const FormatException('importedAt must be an ISO 8601 time');
    }
    return Live2DStoredModel(
      id: id,
      displayName: displayName,
      importedAt: time,
      model3: model3,
    );
  }

  static const Set<String> _fields = {
    'id',
    'displayName',
    'importedAt',
    'model3',
  };

  @override
  String toString() => 'Live2DStoredModel($id, $model3)';
}

/// Models, profiles and the active selection kept in one directory.
///
/// The app passes the root, which on Android is `noBackupFilesDir/live2d`;
/// the store never computes it and never writes outside it. `models/<id>/`
/// holds a model's files, `profiles/<id>.json` its profile, and
/// `models.json` lists the models and the active one. Each JSON file is
/// written to `<name>.pending`, flushed and renamed into place.
/// `models.json` is the commit point: [open] removes or rolls back whatever
/// an interrupted operation left before reaching it. Operations run one at
/// a time; the getters read memory, which matches the last commit.
abstract interface class Live2DFileStore {
  /// Opens or creates the store in [root], an absolute directory path.
  ///
  /// Throws [ArgumentError] for a relative [root], [FormatException] for an
  /// unreadable `models.json`, before anything is cleaned up, and
  /// [UnsupportedError] where there is no file system.
  static Future<Live2DFileStore> open(String root) => openLive2DFileStore(root);

  /// The root directory, as passed to [open].
  String get root;

  /// The stored models, sorted by ID.
  List<Live2DStoredModel> get models;

  /// The model with exactly [modelId], or null.
  Live2DStoredModel? model(String modelId);

  /// The saved profile of [modelId], or null when there is none or its file
  /// could not be parsed.
  Live2DProfile? profile(String modelId);

  /// The active model, which always has a checked profile, or null.
  String? get activeModelId;

  /// The directory holding [modelId]'s files. Throws [StateError] for an
  /// unknown model.
  String modelDirectory(String modelId);

  /// Imports a model as [modelId] and returns its entry.
  ///
  /// [files] maps each path, relative to the model directory and accepted by
  /// [Live2DProfile.isSafeModelFile], to the file's bytes, and must include
  /// [model3]. The files are written to `models/<id>.pending/` and renamed
  /// into place; writing `models.json` commits the import, and a failure
  /// before that leaves the store as it was. Throws [FormatException] for an
  /// invalid argument, and [StateError] when [modelId] exists and [replace]
  /// is false, or when another model's ID differs from it only in case.
  ///
  /// Replacing keeps the model's profile but clears the active selection
  /// when it was this model: the mapping must be checked again against the
  /// new files with [setActive].
  Future<Live2DStoredModel> importModel({
    required String modelId,
    required String displayName,
    required String model3,
    required Map<String, List<int>> files,
    bool replace = false,
    DateTime? importedAt,
  });

  /// Saves [profile] as its model's profile.
  ///
  /// Throws [StateError] for an unknown model, and [FormatException] when
  /// the profile's modelFile is not the model's model3 or its profileRev is
  /// not above the saved one. Saving clears the active selection when it was
  /// this model; call [setActive] to check the new mapping.
  Future<void> saveProfile(Live2DProfile profile);

  /// Makes [modelId] active once its profile passes
  /// [Live2DParamMap.validateTargets] against [info], which must come from
  /// the `ready` event of this model's files.
  ///
  /// Throws [StateError] for an unknown model, a model without a profile or
  /// a profile whose modelFile is not the model's model3, and
  /// [Live2DTargetException] listing every missing target. When it throws,
  /// the profile is kept and the selection is unchanged.
  Future<void> setActive(String modelId, Live2DModelInfo info);

  /// Clears the active selection.
  Future<void> clearActive();

  /// Deletes [modelId], its files and its profile, and clears the active
  /// selection when it was this model. Returns false for an unknown model.
  Future<bool> delete(String modelId);
}
