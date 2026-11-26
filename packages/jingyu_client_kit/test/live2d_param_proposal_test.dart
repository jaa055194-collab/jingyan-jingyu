import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

/// The model information that a viewer `ready` event with these parameter
/// IDs carries.
Live2DModelInfo modelWith(List<String> parameterIds) =>
    Live2DModelInfo.fromReadyEvent({
      'event': 'ready',
      'parameters': [
        for (final id in parameterIds) {'id': id},
      ],
    });

Live2DModelGroup lipSync(List<String> ids) =>
    Live2DModelGroup(name: 'LipSync', ids: ids);

Live2DModelGroup eyeBlink(List<String> ids) =>
    Live2DModelGroup(name: 'EyeBlink', ids: ids);

Matcher suggests(String id, Live2DParamEvidence evidence) =>
    isA<Live2DParamSuggestion>()
        .having((suggestion) => suggestion.id, 'id', id)
        .having((suggestion) => suggestion.evidence, 'evidence', evidence);

const standardIds = ['ParamEyeLOpen', 'ParamEyeROpen', 'ParamMouthOpenY'];

void main() {
  group('Live2DParamProposal.forModel', () {
    test('suggests the Cubism standard IDs when the model has no groups', () {
      final proposal = Live2DParamProposal.forModel(
        modelWith(['ParamAngleX', ...standardIds]),
      );
      expect(
        proposal.mouthOpen,
        suggests('ParamMouthOpenY', Live2DParamEvidence.standardId),
      );
      expect(
        proposal.blinkLeft,
        suggests('ParamEyeLOpen', Live2DParamEvidence.standardId),
      );
      expect(
        proposal.blinkRight,
        suggests('ParamEyeROpen', Live2DParamEvidence.standardId),
      );
    });

    test('falls back to the Cubism 2 standard IDs', () {
      final proposal = Live2DParamProposal.forModel(
        modelWith([
          'PARAM_EYE_L_OPEN',
          'PARAM_EYE_R_OPEN',
          'PARAM_MOUTH_OPEN_Y',
        ]),
      );
      expect(
        proposal.mouthOpen,
        suggests('PARAM_MOUTH_OPEN_Y', Live2DParamEvidence.cubism2StandardId),
      );
      expect(
        proposal.blinkLeft,
        suggests('PARAM_EYE_L_OPEN', Live2DParamEvidence.cubism2StandardId),
      );
      expect(
        proposal.blinkRight,
        suggests('PARAM_EYE_R_OPEN', Live2DParamEvidence.cubism2StandardId),
      );
    });

    test('prefers a Cubism standard ID over its Cubism 2 form', () {
      final proposal = Live2DParamProposal.forModel(
        modelWith(['PARAM_MOUTH_OPEN_Y', 'ParamMouthOpenY']),
      );
      expect(
        proposal.mouthOpen,
        suggests('ParamMouthOpenY', Live2DParamEvidence.standardId),
      );
    });

    test('matches IDs exactly', () {
      final proposal = Live2DParamProposal.forModel(
        modelWith(['parammouthopeny', 'ParamEyeLOpen ', 'ParamEyeROpen2']),
        groups: [
          lipSync(['ParamMouthOpenY']),
        ],
      );
      expect(proposal.mouthOpen, isNull);
      expect(proposal.blinkLeft, isNull);
      expect(proposal.blinkRight, isNull);
    });

    test('takes the mouth from the LipSync group over standard IDs', () {
      final proposal = Live2DParamProposal.forModel(
        modelWith(['ParamMouthOpenY', 'MouthOpen2']),
        groups: [
          lipSync(['MouthOpen2']),
        ],
      );
      expect(
        proposal.mouthOpen,
        suggests('MouthOpen2', Live2DParamEvidence.group),
      );
    });

    test('prefers the standard ID inside the LipSync group', () {
      final proposal = Live2DParamProposal.forModel(
        modelWith(['MouthA', 'ParamMouthOpenY']),
        groups: [
          lipSync(['MouthA', 'ParamMouthOpenY']),
        ],
      );
      expect(
        proposal.mouthOpen,
        suggests('ParamMouthOpenY', Live2DParamEvidence.group),
      );
    });

    test('takes the first LipSync ID the runtime reports', () {
      final proposal = Live2DParamProposal.forModel(
        modelWith(['MouthA', 'MouthB']),
        groups: [
          lipSync(['Missing', 'MouthB', 'MouthA']),
        ],
      );
      expect(proposal.mouthOpen, suggests('MouthB', Live2DParamEvidence.group));
    });

    test('ignores groups without an ID the runtime reports', () {
      for (final ids in [
        <String>[],
        ['Missing'],
      ]) {
        final proposal = Live2DParamProposal.forModel(
          modelWith(standardIds),
          groups: [lipSync(ids), eyeBlink(ids)],
        );
        expect(
          proposal.mouthOpen,
          suggests('ParamMouthOpenY', Live2DParamEvidence.standardId),
        );
        expect(
          proposal.blinkLeft,
          suggests('ParamEyeLOpen', Live2DParamEvidence.standardId),
        );
        expect(
          proposal.blinkRight,
          suggests('ParamEyeROpen', Live2DParamEvidence.standardId),
        );
      }
    });

    test('reads only the first group with each exact name', () {
      final proposal = Live2DParamProposal.forModel(
        modelWith([...standardIds, 'MouthA', 'MouthB', 'EyeOpen']),
        groups: [
          Live2DModelGroup(name: 'lipsync', ids: ['MouthA']),
          eyeBlink(['Missing']),
          lipSync(['MouthB']),
          lipSync(['MouthA']),
          eyeBlink(['EyeOpen']),
        ],
      );
      expect(proposal.mouthOpen, suggests('MouthB', Live2DParamEvidence.group));
      // The first EyeBlink group has no reported ID, and the second one is
      // never read, so the standard IDs decide.
      expect(
        proposal.blinkLeft,
        suggests('ParamEyeLOpen', Live2DParamEvidence.standardId),
      );
      expect(
        proposal.blinkRight,
        suggests('ParamEyeROpen', Live2DParamEvidence.standardId),
      );
    });

    test('assigns EyeBlink IDs to the eyes by their standard IDs', () {
      final proposal = Live2DParamProposal.forModel(
        modelWith(standardIds),
        groups: [
          eyeBlink(['ParamEyeROpen', 'ParamEyeLOpen']),
        ],
      );
      expect(
        proposal.blinkLeft,
        suggests('ParamEyeLOpen', Live2DParamEvidence.group),
      );
      expect(
        proposal.blinkRight,
        suggests('ParamEyeROpen', Live2DParamEvidence.group),
      );
    });

    test('gives the other eye the one remaining EyeBlink ID', () {
      final proposal = Live2DParamProposal.forModel(
        modelWith([...standardIds, 'EyeRight']),
        groups: [
          eyeBlink(['ParamEyeLOpen', 'EyeRight']),
        ],
      );
      expect(
        proposal.blinkLeft,
        suggests('ParamEyeLOpen', Live2DParamEvidence.group),
      );
      expect(
        proposal.blinkRight,
        suggests('EyeRight', Live2DParamEvidence.group),
      );
    });

    test('uses a lone EyeBlink ID for both eyes', () {
      final proposal = Live2DParamProposal.forModel(
        modelWith([...standardIds, 'EyeOpen']),
        groups: [
          eyeBlink(['EyeOpen', 'Missing', 'EyeOpen']),
        ],
      );
      expect(
        proposal.blinkLeft,
        suggests('EyeOpen', Live2DParamEvidence.group),
      );
      expect(
        proposal.blinkRight,
        suggests('EyeOpen', Live2DParamEvidence.group),
      );
    });

    test(
      'leaves an eye unassigned when the EyeBlink group does not settle it',
      () {
        final unnamed = Live2DParamProposal.forModel(
          modelWith([...standardIds, 'EyeA', 'EyeB']),
          groups: [
            eyeBlink(['EyeA', 'EyeB']),
          ],
        );
        expect(unnamed.blinkLeft, isNull);
        expect(unnamed.blinkRight, isNull);

        final leftOnly = Live2DParamProposal.forModel(
          modelWith(standardIds),
          groups: [
            eyeBlink(['ParamEyeLOpen']),
          ],
        );
        expect(
          leftOnly.blinkLeft,
          suggests('ParamEyeLOpen', Live2DParamEvidence.group),
        );
        expect(leftOnly.blinkRight, isNull);
      },
    );

    test('suggests nothing when the runtime reported no parameters', () {
      final proposal = Live2DParamProposal.forModel(
        Live2DModelInfo.fromReadyEvent({'event': 'ready'}),
        groups: [
          lipSync(['ParamMouthOpenY']),
          eyeBlink(['ParamEyeLOpen', 'ParamEyeROpen']),
        ],
      );
      expect(proposal.mouthOpen, isNull);
      expect(proposal.blinkLeft, isNull);
      expect(proposal.blinkRight, isNull);
    });
  });
}
