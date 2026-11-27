// An in-memory Live2DFileStore for widget tests. It records every write and
// checks what the real store checks (packages/jingyu_client_kit/lib/src/
// live2d_store.dart), so a test sees the same failures.
import 'package:jingyu_client_kit/jingyu_client_kit.dart';

final class FakeLive2DFileStore implements Live2DFileStore {
  @override
  String get root => '/data/user/0/jingyu/no_backup/live2d';

  final Map<String, Live2DStoredModel> _models = {};
  final Map<String, Live2DProfile> _profiles = {};
  String? _active;

  /// The files [importModel] received for each model.
  final Map<String, Map<String, List<int>>> importedFiles = {};

  /// Every write, in order, such as `saveProfile(m1, rev 1)`.
  final List<String> calls = <String>[];

  /// The info [setActive] was last called with.
  Live2DModelInfo? lastActivationInfo;

  /// Thrown by the next write instead of writing.
  Object? failNext;

  /// Adds a model, and a profile with [paramMap] when given, without
  /// recording a call.
  void addModel(
    String id, {
    String displayName = '示例模型',
    Map<String, Object?>? paramMap,
    bool active = false,
  }) {
    _models[id] = Live2DStoredModel(
      id: id,
      displayName: displayName,
      importedAt: DateTime.utc(2026, 11, 28),
      model3: 'model.model3.json',
    );
    if (paramMap != null) {
      _profiles[id] = Live2DProfile.fromJson({
        'schemaVersion': 1,
        'modelId': id,
        'profileRev': 1,
        'modelFile': 'model.model3.json',
        'paramMap': paramMap,
      });
    }
    if (active) _active = id;
  }

  void _write(String call) {
    calls.add(call);
    final failure = failNext;
    if (failure != null) {
      failNext = null;
      throw failure;
    }
  }

  @override
  List<Live2DStoredModel> get models => [
    for (final id in _models.keys.toList()..sort()) _models[id]!,
  ];

  @override
  Live2DStoredModel? model(String modelId) => _models[modelId];

  @override
  Live2DProfile? profile(String modelId) => _profiles[modelId];

  @override
  String? get activeModelId => _active;

  @override
  String modelDirectory(String modelId) {
    if (!_models.containsKey(modelId)) {
      throw StateError('unknown model $modelId');
    }
    return '$root/models/$modelId';
  }

  @override
  Future<Live2DStoredModel> importModel({
    required String modelId,
    required String displayName,
    required String model3,
    required Map<String, List<int>> files,
    bool replace = false,
    DateTime? importedAt,
  }) async {
    _write('importModel($modelId)');
    if (!files.containsKey(model3) ||
        !files.keys.every(Live2DProfile.isSafeModelFile)) {
      throw const FormatException('the files must be safe and hold model3');
    }
    final lower = modelId.toLowerCase();
    for (final id in _models.keys) {
      if (id.toLowerCase() == lower && (id != modelId || !replace)) {
        throw StateError('model $modelId exists');
      }
    }
    final model = Live2DStoredModel(
      id: modelId,
      displayName: displayName,
      importedAt: importedAt ?? DateTime.utc(2026, 11, 28),
      model3: model3,
    );
    _models[modelId] = model;
    importedFiles[modelId] = Map.of(files);
    if (replace && _active == modelId) _active = null;
    return model;
  }

  @override
  Future<void> saveProfile(Live2DProfile profile) async {
    final id = profile.modelId;
    _write('saveProfile($id, rev ${profile.profileRev})');
    final model = _models[id];
    if (model == null) throw StateError('unknown model $id');
    if (profile.modelFile != model.model3) {
      throw const FormatException('modelFile is not the model3');
    }
    final saved = _profiles[id];
    if (saved != null && profile.profileRev <= saved.profileRev) {
      throw const FormatException('profileRev must be above the saved one');
    }
    _profiles[id] = profile;
    if (_active == id) _active = null;
  }

  @override
  Future<void> setActive(String modelId, Live2DModelInfo info) async {
    _write('setActive($modelId)');
    lastActivationInfo = info;
    final model = _models[modelId];
    final profile = _profiles[modelId];
    if (model == null || profile == null) {
      throw StateError('$modelId has no profile');
    }
    if (profile.modelFile != model.model3) {
      throw StateError('modelFile is not the model3');
    }
    profile.paramMap.validateTargets(info);
    _active = modelId;
  }

  @override
  Future<void> clearActive() async {
    _write('clearActive()');
    _active = null;
  }

  @override
  Future<bool> delete(String modelId) async {
    _write('delete($modelId)');
    final known = _models.remove(modelId) != null;
    _profiles.remove(modelId);
    importedFiles.remove(modelId);
    if (_active == modelId) _active = null;
    return known;
  }
}
