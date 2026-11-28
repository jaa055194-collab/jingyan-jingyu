/// The dart:io [Live2DFileStore]. See live2d_store.dart for the contract.
library;

import 'dart:convert';
import 'dart:io';

import 'live2d_model_info.dart';
import 'live2d_profile.dart';
import 'live2d_store.dart';

/// Opens the store in [root]; see [Live2DFileStore.open].
Future<Live2DFileStore> openLive2DFileStore(String root) =>
    _IoLive2DFileStore._open(root);

/// Written into each model directory: the JSON of the `models.json` entry
/// that the directory's files belong to. It is not a model file type, so
/// the viewer never serves it. It tells a replace that reached
/// `models.json` apart from one that was interrupted before it.
const String _stampName = '.import.json';

const Set<String> _indexFields = {'schemaVersion', 'activeModelId', 'models'};

final class _IoLive2DFileStore implements Live2DFileStore {
  _IoLive2DFileStore._(this.root);

  @override
  final String root;

  final Map<String, Live2DStoredModel> _models = {};
  final Map<String, Live2DProfile> _profiles = {};
  String? _activeModelId;
  Future<void> _tail = Future<void>.value();

  String get _indexPath => _join(root, 'models.json');
  String get _modelsPath => _join(root, 'models');
  String get _profilesPath => _join(root, 'profiles');
  String _modelPath(String id) => _join(_modelsPath, id);
  String _profilePath(String id) => _join(_profilesPath, '$id.json');

  static Future<Live2DFileStore> _open(String root) async {
    if (!Directory(root).isAbsolute) {
      throw ArgumentError.value(root, 'root', 'must be an absolute path');
    }
    final store = _IoLive2DFileStore._(root);
    final index = File(store._indexPath);
    if (await index.exists()) {
      store._readIndex(await index.readAsBytes());
    }
    await Directory(store._modelsPath).create(recursive: true);
    await Directory(store._profilesPath).create(recursive: true);
    if (await store._collectGarbage()) {
      await store._commit(store._models, store._activeModelId);
    }
    return store;
  }

  @override
  List<Live2DStoredModel> get models {
    final ids = _models.keys.toList()..sort();
    return List.unmodifiable([for (final id in ids) _models[id]!]);
  }

  @override
  Live2DStoredModel? model(String modelId) => _models[modelId];

  @override
  Live2DProfile? profile(String modelId) => _profiles[modelId];

  @override
  String? get activeModelId => _activeModelId;

  @override
  String modelDirectory(String modelId) {
    if (!_models.containsKey(modelId)) {
      throw StateError('unknown model $modelId');
    }
    return _modelPath(modelId);
  }

  /// Runs [operation] once every earlier operation has finished.
  Future<T> _run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Writes `models.json`, then updates the memory copy to match it.
  Future<void> _commit(
    Map<String, Live2DStoredModel> models,
    String? active,
  ) async {
    final ids = models.keys.toList()..sort();
    await _writeJson(_indexPath, {
      'schemaVersion': 1,
      'activeModelId': active,
      'models': [for (final id in ids) models[id]!.toJson()],
    });
    if (!identical(models, _models)) {
      _models
        ..clear()
        ..addAll(models);
    }
    _activeModelId = active;
  }

  String _modelFile(String id, String path) => _under(_modelPath(id), path);

  void _readIndex(List<int> bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const FormatException('models.json is not valid UTF-8 JSON');
    }
    if (json is! Map<String, Object?> ||
        json.keys.any((key) => !_indexFields.contains(key)) ||
        json['schemaVersion'] is! int ||
        json['schemaVersion'] != 1) {
      throw const FormatException('models.json is not a Live2D model index');
    }
    final rawModels = json['models'];
    if (rawModels is! List<Object?>) {
      throw const FormatException('models.json models must be a list');
    }
    final lowerIds = <String>{};
    for (final raw in rawModels) {
      final entry = Live2DStoredModel.fromJson(raw);
      if (!lowerIds.add(entry.id.toLowerCase())) {
        throw FormatException('models.json repeats the model ID ${entry.id}');
      }
      _models[entry.id] = entry;
    }
    final active = json['activeModelId'];
    if (active is String) {
      _activeModelId = active;
    } else if (active != null) {
      throw const FormatException('models.json activeModelId must be a string');
    }
  }

  /// Rolls back or finishes what interrupted operations left, and drops
  /// whatever no longer checks out. Returns whether `models.json` must be
  /// written again.
  Future<bool> _collectGarbage() async {
    await _deleteQuietly(File('$_indexPath.pending'));
    final ids = <String>{};
    await for (final entity in Directory(
      _modelsPath,
    ).list(followLinks: false)) {
      final id = _modelIdOf(_baseName(entity.path));
      if (id != null && entity is Directory) ids.add(id);
    }
    final recovered = <String>{};
    for (final id in ids) {
      if (await _recoverModel(id)) recovered.add(id);
    }
    var dirty = false;
    for (final entry in _models.values.toList()) {
      if (!await File(_modelFile(entry.id, entry.model3)).exists()) {
        _models.remove(entry.id);
        dirty = true;
        await _deleteQuietly(Directory(_modelPath(entry.id)));
      }
    }
    final files = <File>[];
    await for (final entity in Directory(
      _profilesPath,
    ).list(followLinks: false)) {
      if (entity is File) files.add(entity);
    }
    for (final file in files) {
      final name = _baseName(file.path);
      if (name.endsWith('.json.pending')) {
        final id = name.substring(0, name.length - '.json.pending'.length);
        if (Live2DProfile.isValidModelId(id)) await _deleteQuietly(file);
      } else if (name.endsWith('.json')) {
        final id = name.substring(0, name.length - '.json'.length);
        if (!Live2DProfile.isValidModelId(id)) continue;
        if (!_models.containsKey(id)) {
          await _deleteQuietly(file);
          continue;
        }
        final profile = _parseProfile(await file.readAsBytes());
        if (profile != null && profile.modelId == id) {
          _profiles[id] = profile;
        }
      }
    }
    final active = _activeModelId;
    if (active != null) {
      final entry = _models[active];
      final profile = _profiles[active];
      if (entry == null ||
          profile == null ||
          profile.modelFile != entry.model3 ||
          recovered.contains(active)) {
        _activeModelId = null;
        dirty = true;
      }
    }
    return dirty;
  }

  /// Rolls back or finishes an interrupted import of [id]. It removes
  /// `<id>.pending`, then keeps whichever of `<id>` and `<id>.old` holds the
  /// files of the committed entry; with no entry, it removes both. Returns
  /// whether `<id>.old` was there, the only sign that the files under a
  /// committed entry may have been swapped: `<id>.pending` never holds
  /// committed files.
  Future<bool> _recoverModel(String id) async {
    final dir = Directory(_modelPath(id));
    final pending = Directory('${dir.path}.pending');
    final old = Directory('${dir.path}.old');
    final hadOld = await old.exists();
    await _deleteQuietly(pending);
    final entry = _models[id];
    if (entry == null) {
      await _deleteQuietly(old);
      await _deleteQuietly(dir);
    } else if (hadOld) {
      if (await dir.exists() && await _stampMatches(dir.path, entry)) {
        await _deleteQuietly(old);
      } else {
        await _delete(dir);
        await old.rename(dir.path);
      }
    }
    return hadOld;
  }

  static Future<bool> _stampMatches(String dir, Live2DStoredModel entry) async {
    try {
      final stamp = await File(_join(dir, _stampName)).readAsBytes();
      return utf8.decode(stamp) == jsonEncode(entry.toJson());
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  static Live2DProfile? _parseProfile(List<int> bytes) {
    try {
      final Object? json = jsonDecode(utf8.decode(bytes));
      return json is Map<String, Object?> ? Live2DProfile.fromJson(json) : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<Live2DStoredModel> importModel({
    required String modelId,
    required String displayName,
    required String model3,
    required Map<String, List<int>> files,
    bool replace = false,
    DateTime? importedAt,
  }) => _run(() async {
    final entry = Live2DStoredModel(
      id: modelId,
      displayName: displayName,
      importedAt: importedAt ?? DateTime.now(),
      model3: model3,
    );
    _checkFiles(files, model3);
    final existing = _models[modelId];
    if (existing != null && !replace) {
      throw StateError('model $modelId already exists');
    }
    final lower = modelId.toLowerCase();
    if (_models.keys.any((id) => id != modelId && id.toLowerCase() == lower)) {
      throw StateError('another model ID differs from $modelId only in case');
    }
    final dir = Directory(_modelPath(modelId));
    final pending = Directory('${dir.path}.pending');
    final old = Directory('${dir.path}.old');
    await _recoverModel(modelId);
    if (await pending.exists() ||
        await old.exists() ||
        (existing == null && await dir.exists())) {
      throw StateError('could not remove what an earlier import left');
    }
    try {
      if (existing == null) {
        final profile = _profilePath(modelId);
        await _delete(File('$profile.pending'));
        await _delete(File(profile));
      }
      for (final MapEntry(key: path, value: bytes) in files.entries) {
        final file = File(_under(pending.path, path));
        await file.parent.create(recursive: true);
        await _writeBytes(file, bytes);
      }
      await _writeBytes(
        File(_join(pending.path, _stampName)),
        utf8.encode(jsonEncode(entry.toJson())),
      );
      if (await dir.exists()) await dir.rename(old.path);
      await pending.rename(dir.path);
      await _commit({
        ..._models,
        modelId: entry,
      }, _activeModelId == modelId ? null : _activeModelId);
    } on Object {
      try {
        await _recoverModel(modelId);
      } on Object {
        // The next open finishes the rollback.
      }
      rethrow;
    }
    await _deleteQuietly(old);
    return entry;
  });

  /// Checks the paths of an import; see [importModel].
  static void _checkFiles(Map<String, List<int>> files, String model3) {
    if (!files.containsKey(model3)) {
      throw FormatException('files must include the model3 file $model3');
    }
    final lower = <String>{};
    for (final path in files.keys) {
      if (!Live2DProfile.isSafeModelFile(path)) {
        throw FormatException('"$path" is not a safe model file path');
      }
      if (!lower.add(path.toLowerCase())) {
        throw FormatException('"$path" repeats a path in another case');
      }
    }
    for (final path in lower) {
      var cut = path.indexOf('/');
      while (cut != -1) {
        final parent = path.substring(0, cut);
        if (lower.contains(parent)) {
          throw FormatException('"$parent" is both a file and a directory');
        }
        cut = path.indexOf('/', cut + 1);
      }
    }
  }

  @override
  Future<void> saveProfile(Live2DProfile profile) => _run(() async {
    final id = profile.modelId;
    final entry = _models[id];
    if (entry == null) {
      throw StateError('unknown model $id');
    }
    if (profile.modelFile != entry.model3) {
      throw FormatException(
        'modelFile ${profile.modelFile} is not the model3 file ${entry.model3}',
      );
    }
    final saved = _profiles[id];
    if (saved != null && profile.profileRev <= saved.profileRev) {
      throw FormatException(
        'profileRev ${profile.profileRev} must exceed ${saved.profileRev}',
      );
    }
    if (_activeModelId == id) await _commit(_models, null);
    await _writeJson(_profilePath(id), profile.toJson());
    _profiles[id] = profile;
  });

  @override
  Future<void> setActive(String modelId, Live2DModelInfo info) =>
      _run(() async {
        final entry = _models[modelId];
        if (entry == null) {
          throw StateError('unknown model $modelId');
        }
        final profile = _profiles[modelId];
        if (profile == null) {
          throw StateError('model $modelId has no profile');
        }
        if (profile.modelFile != entry.model3) {
          throw StateError(
            'the profile of $modelId maps ${profile.modelFile}, '
            'not the model3 file ${entry.model3}',
          );
        }
        profile.paramMap.validateTargets(info);
        if (_activeModelId != modelId) await _commit(_models, modelId);
      });

  @override
  Future<void> clearActive() => _run(() async {
    if (_activeModelId != null) await _commit(_models, null);
  });

  @override
  Future<bool> delete(String modelId) => _run(() async {
    if (!_models.containsKey(modelId)) return false;
    final models = {..._models}..remove(modelId);
    await _commit(models, _activeModelId == modelId ? null : _activeModelId);
    _profiles.remove(modelId);
    final profile = _profilePath(modelId);
    await _deleteQuietly(File('$profile.pending'));
    await _deleteQuietly(File(profile));
    final dir = _modelPath(modelId);
    await _deleteQuietly(Directory('$dir.pending'));
    await _deleteQuietly(Directory(dir));
    await _deleteQuietly(Directory('$dir.old'));
    return true;
  });
}

/// Joins [name] to the directory [dir].
String _join(String dir, String name) => dir.endsWith(Platform.pathSeparator)
    ? '$dir$name'
    : '$dir${Platform.pathSeparator}$name';

/// Joins the `/`-separated relative [path], which passed
/// [Live2DProfile.isSafeModelFile], to the directory [dir].
String _under(String dir, String path) =>
    _join(dir, path.replaceAll('/', Platform.pathSeparator));

String _baseName(String path) => path.substring(
  path.lastIndexOf(Platform.isWindows ? RegExp(r'[\\/]') : '/') + 1,
);

/// The model ID that a `models/` entry named [name] belongs to, or null.
String? _modelIdOf(String name) {
  for (final suffix in const ['.pending', '.old']) {
    if (name.endsWith(suffix)) {
      final id = name.substring(0, name.length - suffix.length);
      return Live2DProfile.isValidModelId(id) ? id : null;
    }
  }
  return Live2DProfile.isValidModelId(name) ? name : null;
}

/// Writes [bytes] to [file] and flushes them to the disk.
Future<void> _writeBytes(File file, List<int> bytes) async {
  final out = await file.open(mode: FileMode.writeOnly);
  try {
    await out.writeFrom(bytes);
    await out.flush();
  } finally {
    await out.close();
  }
}

/// Writes [json] to `<path>.pending`, flushes it and renames it to [path].
Future<void> _writeJson(String path, Object? json) async {
  final pending = File('$path.pending');
  await _writeBytes(pending, utf8.encode(jsonEncode(json)));
  await pending.rename(path);
}

/// Deletes [entity] when it exists, a directory with all it holds.
Future<void> _delete(FileSystemEntity entity) async {
  if (await entity.exists()) await entity.delete(recursive: true);
}

/// Like [_delete], but leaves a failure for the next open to retry.
Future<void> _deleteQuietly(FileSystemEntity entity) async {
  try {
    await _delete(entity);
  } on FileSystemException {
    // The next open removes it.
  }
}
