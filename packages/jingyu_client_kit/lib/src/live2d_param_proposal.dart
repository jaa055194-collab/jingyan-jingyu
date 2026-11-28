/// Suggested targets for a loaded Live2D model's parameter mapping.
///
/// Suggestions only: nothing here builds, saves or enables a
/// `Live2DParamMap`, and the user confirms every target first
/// (`docs/research/live2d-phase-two-survey.md`, section 4.11). Each
/// suggested ID is one the runtime reported for the loaded model
/// ([Live2DModelInfo.parameterIds]), matched exactly.
library;

import 'live2d_model_info.dart';
import 'live2d_package.dart';

/// Why an ID was suggested, strongest evidence first.
enum Live2DParamEvidence {
  /// The ID is in the `model3.json` group that Cubism reads for the slot:
  /// `LipSync` for the mouth, `EyeBlink` for the eyes.
  group,

  /// The ID is the slot's Cubism standard parameter ID, such as
  /// `ParamMouthOpenY`.
  standardId,

  /// The ID is the slot's Cubism 2 standard parameter ID, such as
  /// `PARAM_MOUTH_OPEN_Y`.
  cubism2StandardId,
}

/// One suggested target and the evidence for it.
final class Live2DParamSuggestion {
  const Live2DParamSuggestion._(this.id, this.evidence);

  /// A parameter ID the runtime reported for the model.
  final String id;

  final Live2DParamEvidence evidence;

  @override
  String toString() => 'Live2DParamSuggestion($id, ${evidence.name})';
}

/// Suggested targets for the `mouthOpen`, `blinkLeft` and `blinkRight` slots
/// of a `Live2DParamMap`.
///
/// Evidence, strongest first:
/// 1. The model's `LipSync` and `EyeBlink` groups, read as the Cubism
///    framework reads them: only the first group with that exact name counts,
///    whatever its target (`CubismModelSettingJson.getLipSyncParameterId` and
///    `getEyeBlinkParameterId`). Only group IDs the runtime reports count,
///    and a group without any is ignored.
/// 2. The Cubism standard IDs `ParamMouthOpenY`, `ParamEyeLOpen` and
///    `ParamEyeROpen`, then their Cubism 2 forms.
///
/// A group overrides the standard IDs outside it. A group can list several
/// IDs, but a slot takes one: the mouth takes the standard ID when the
/// `LipSync` group has it, otherwise the group's first ID. The `EyeBlink`
/// group does not say which ID is which eye, so an ID settles an eye only
/// when it is that eye's standard ID, or when it is the group's only ID that
/// is not the other eye's standard ID. A slot the evidence does not settle
/// gets no suggestion, and the user picks its target. Display names
/// (`cdi3.json`) and value ranges are not consulted yet, and expressions and
/// motions are not proposed.
final class Live2DParamProposal {
  const Live2DParamProposal._({
    this.mouthOpen,
    this.blinkLeft,
    this.blinkRight,
  });

  /// Proposes targets for the model that [info] describes.
  ///
  /// [groups] are the model's `model3.json` groups in file order, as
  /// [Live2DPackageValidation.groups] reads them. When the runtime reported
  /// no parameters, no ID can be checked, so nothing is suggested.
  factory Live2DParamProposal.forModel(
    Live2DModelInfo info, {
    Iterable<Live2DModelGroup> groups = const [],
  }) {
    final runtimeIds = info.parameterIds;
    if (runtimeIds == null) return const Live2DParamProposal._();
    final lipSync = _reported(runtimeIds, _firstGroup(groups, 'LipSync'));
    final eyeBlink = _reported(runtimeIds, _firstGroup(groups, 'EyeBlink'));
    return Live2DParamProposal._(
      mouthOpen: _mouth(runtimeIds, lipSync),
      blinkLeft: _eye(runtimeIds, eyeBlink, _eyeLOpenIds, _eyeROpenIds),
      blinkRight: _eye(runtimeIds, eyeBlink, _eyeROpenIds, _eyeLOpenIds),
    );
  }

  /// The suggested mouth-open parameter, or null when none is settled.
  final Live2DParamSuggestion? mouthOpen;

  /// The suggested left-eye open parameter, or null when none is settled.
  final Live2DParamSuggestion? blinkLeft;

  /// The suggested right-eye open parameter, or null when none is settled.
  final Live2DParamSuggestion? blinkRight;

  // Each slot's Cubism standard ID, then its Cubism 2 form.
  static const _mouthOpenIds = ['ParamMouthOpenY', 'PARAM_MOUTH_OPEN_Y'];
  static const _eyeLOpenIds = ['ParamEyeLOpen', 'PARAM_EYE_L_OPEN'];
  static const _eyeROpenIds = ['ParamEyeROpen', 'PARAM_EYE_R_OPEN'];

  /// The IDs of the first group named [name], or null when there is none.
  static List<String>? _firstGroup(
    Iterable<Live2DModelGroup> groups,
    String name,
  ) {
    for (final group in groups) {
      if (group.name == name) return group.ids;
    }
    return null;
  }

  /// The group IDs the runtime reports, in group order, without repeats.
  static List<String> _reported(
    Set<String> runtimeIds,
    Iterable<String>? ids,
  ) => [...?ids?.where(runtimeIds.contains).toSet()];

  static Live2DParamSuggestion? _mouth(
    Set<String> runtimeIds,
    List<String> lipSync,
  ) {
    if (lipSync.isEmpty) return _standard(runtimeIds, _mouthOpenIds);
    final id = _mouthOpenIds.firstWhere(
      lipSync.contains,
      orElse: () => lipSync.first,
    );
    return Live2DParamSuggestion._(id, Live2DParamEvidence.group);
  }

  static Live2DParamSuggestion? _eye(
    Set<String> runtimeIds,
    List<String> eyeBlink,
    List<String> ownIds,
    List<String> otherIds,
  ) {
    if (eyeBlink.isEmpty) return _standard(runtimeIds, ownIds);
    final own = ownIds.where(eyeBlink.contains);
    final rest = [
      for (final id in eyeBlink)
        if (!otherIds.contains(id)) id,
    ];
    final id = own.isNotEmpty
        ? own.first
        : (rest.length == 1 ? rest.single : null);
    return id == null
        ? null
        : Live2DParamSuggestion._(id, Live2DParamEvidence.group);
  }

  static Live2DParamSuggestion? _standard(
    Set<String> runtimeIds,
    List<String> ids,
  ) {
    final [standard, cubism2] = ids;
    if (runtimeIds.contains(standard)) {
      return Live2DParamSuggestion._(standard, Live2DParamEvidence.standardId);
    }
    if (runtimeIds.contains(cubism2)) {
      return Live2DParamSuggestion._(
        cubism2,
        Live2DParamEvidence.cubism2StandardId,
      );
    }
    return null;
  }
}
