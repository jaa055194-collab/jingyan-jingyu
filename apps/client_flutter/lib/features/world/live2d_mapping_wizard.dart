// Mapping wizard for a Live2D model kept on this device. Every candidate
// comes from what the ready preview of the kept files reported
// (Live2DModelInfo); nothing is inferred from file names. Only 确认并保存
// writes, through Live2DFileStore.saveProfile.
import 'dart:async';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:material_ui/material_ui.dart';

/// Chinese labels of [Live2DParamMap.expressionKeys], which name both the
/// expression rows and the motion rows.
const Map<String, String> live2dSemanticLabels = {
  'neutral': '平静',
  'happy': '开心',
  'angry': '生气',
  'sad': '难过',
  'relaxed': '放松',
  'surprised': '惊讶',
};

const Map<String, String> _slotLabels = {
  'mouthOpen': '口型',
  'blinkLeft': '左眼眨眼',
  'blinkRight': '右眼眨眼',
};

String _semanticLabel(String key) => live2dSemanticLabels[key] ?? key;

/// How a motion is named to the user: its group and its position, from 1.
String live2dMotionLabel(String group, int index) =>
    '${group.isEmpty ? '（无名组）' : group} 第 ${index + 1} 个';

/// One line for a mapped target that the model did not report.
String describeLive2DTargetMiss(Live2DTargetMiss miss) {
  final field = miss.field;
  final open = field.indexOf('[');
  final String slot;
  if (open < 0) {
    slot = _slotLabels[field] ?? field;
  } else {
    final key = field.substring(open + 1, field.length - 1);
    final row = field.startsWith('expressions') ? '表情' : '动作';
    slot = '$row「${_semanticLabel(key)}」';
  }
  final kind = switch (miss.kind) {
    Live2DTargetKind.parameter => '参数',
    Live2DTargetKind.expression => '表情',
    Live2DTargetKind.motion => '动作',
  };
  final index = miss.index;
  final target = index == null
      ? miss.target
      : live2dMotionLabel(miss.target, index);
  return miss.reported
      ? '$slot：此模型没有$kind $target。'
      : '$slot：模型未报告$kind列表，无法核对 $target。';
}

/// Makes [modelId] the active model of [store] once its saved mapping
/// passes the check against [info], which must come from a ready preview of
/// that model's kept files. Returns null on success, otherwise the lines
/// that say why not; then the store's selection is unchanged.
Future<List<String>?> enableLive2DModel(
  Live2DFileStore store,
  String modelId,
  Live2DModelInfo? info, {
  String? infoError,
}) async {
  if (info == null) {
    return ['无法启用：预览未提供有效的模型报告。', ?infoError];
  }
  try {
    await store.setActive(modelId, info);
    return null;
  } on Live2DTargetException catch (error) {
    return [
      '无法启用：以下映射目标未通过核对。',
      for (final miss in error.misses) describeLive2DTargetMiss(miss),
    ];
  } on StateError catch (error) {
    return ['无法启用。', error.message];
  } on FormatException catch (error) {
    return ['无法启用。', error.message];
  } catch (_) {
    return ['无法启用，请重试。'];
  }
}

/// Steps through 口型与眨眼, 表情 and 动作 for [modelId], saves the choices
/// as the model's profile, then offers to enable the model.
class Live2DMappingWizard extends StatefulWidget {
  const Live2DMappingWizard({
    super.key,
    required this.store,
    required this.modelId,
    required this.info,
    this.infoError,
    this.groups = const <Live2DModelGroup>[],
    required this.setParameter,
    required this.clearParameter,
    required this.setExpression,
    required this.clearExpression,
    required this.playMotion,
    required this.blink,
    required this.speak,
    required this.onClose,
    required this.onChanged,
  });

  final Live2DFileStore store;
  final String modelId;

  /// What the ready preview of this model's kept files reported, or null
  /// when that report was rejected; [infoError] then says why.
  final Live2DModelInfo? info;
  final String? infoError;

  /// The package's model3 groups, which feed the suggestions; empty when
  /// they are not known.
  final List<Live2DModelGroup> groups;

  /// Sets a parameter of the preview, in the parameter's own units. The
  /// preview holds the value until [clearParameter].
  final Future<void> Function(String id, double value) setParameter;

  /// Hands a parameter back to the preview, so its own motions, blinking and
  /// lip sync move it again.
  final Future<void> Function(String id) clearParameter;

  /// Plays a listed expression on the preview, for trying one out.
  final Future<void> Function(String name) setExpression;

  /// Clears the expression being tried out.
  final Future<void> Function() clearExpression;

  /// Plays motion [index] of [group] on the preview, for trying one out.
  final Future<void> Function(String group, int index) playMotion;

  /// Makes the preview blink once, for checking the mapped blink parameters.
  final Future<void> Function() blink;

  /// Plays a short synthetic mouth envelope, for checking the mapped mouth
  /// parameter without a speech engine.
  final Future<void> Function(List<double> levels, int stepMs) speak;

  /// Leaves the wizard. Choices that were not saved are discarded.
  final VoidCallback onClose;

  /// Called after the store changed, so the caller shows its new state.
  final VoidCallback onChanged;

  @override
  State<Live2DMappingWizard> createState() => _Live2DMappingWizardState();
}

class _Live2DMappingWizardState extends State<Live2DMappingWizard> {
  static const _slots = ['mouthOpen', 'blinkLeft', 'blinkRight'];
  static const _titles = ['口型与眨眼（必填）', '表情', '动作'];

  int _page = 0;
  final Map<String, String> _parameters = {};
  final Map<String, String> _expressions = {};
  final Map<String, (String, int)> _motions = {};
  bool _noExpressions = false;
  bool _noMotions = false;

  /// The slot whose slider is being dragged, and its value.
  String? _trialSlot;
  double _trialValue = 0;
  String? _driveError;
  String? _previewError;
  static const _testSpeechLevels = <double>[
    0, 0.4, 0.9, 0.6, 1, 0.5, 0.8, 0.2, 0,
  ];
  final Map<String, double> _queued = {};
  final Set<String> _releasing = {};
  final Set<String> _driving = {};

  bool _busy = false;
  bool _saved = false;
  List<String> _errors = const [];

  @override
  void initState() {
    super.initState();
    _suggestParameters();
    _restoreSaved();
  }

  /// The suggestions of [Live2DParamProposal] for page 1.
  void _suggestParameters() {
    _parameters.clear();
    final info = widget.info;
    if (info == null) return;
    final proposal = Live2DParamProposal.forModel(info, groups: widget.groups);
    for (final (slot, suggestion) in [
      ('mouthOpen', proposal.mouthOpen),
      ('blinkLeft', proposal.blinkLeft),
      ('blinkRight', proposal.blinkRight),
    ]) {
      if (suggestion != null) _parameters[slot] = suggestion.id;
    }
  }

  /// Preselects a saved choice only while this preview still reports it.
  void _restoreSaved() {
    final info = widget.info;
    final saved = widget.store.profile(widget.modelId)?.paramMap;
    if (info == null || saved == null) return;
    final ids = info.parameterIds;
    if (ids != null) {
      for (final (slot, id) in [
        ('mouthOpen', saved.mouthOpen),
        ('blinkLeft', saved.blinkLeft),
        ('blinkRight', saved.blinkRight),
      ]) {
        if (ids.contains(id)) _parameters[slot] = id;
      }
    }
    final names = info.expressionNames;
    if (names != null) {
      for (final MapEntry(:key, :value) in saved.expressions.entries) {
        if (names.contains(value)) _expressions[key] = value;
      }
    }
    _noExpressions =
        saved.noExpressions && (info.expressions?.isEmpty ?? false);
    if (info.motions != null) {
      for (final MapEntry(:key, :value) in saved.motions.entries) {
        final count = info.motionCount(value.group);
        if (Live2DParamMap.expressionKeys.contains(key) &&
            count != null &&
            value.index < count) {
          _motions[key] = (value.group, value.index);
        }
      }
    }
    _noMotions = saved.noMotions && (info.motions?.isEmpty ?? false);
  }

  bool get _parametersReady {
    final ids = widget.info?.parameterIds;
    return ids != null &&
        _slots.every((slot) => ids.contains(_parameters[slot]));
  }

  bool get _expressionsReady {
    final names = widget.info?.expressions;
    if (names == null) return false;
    return names.isEmpty ? _noExpressions : _expressions.isNotEmpty;
  }

  bool get _motionsReady {
    final groups = widget.info?.motions;
    if (groups == null) return false;
    return groups.isEmpty ? _noMotions : _motions.isNotEmpty;
  }

  bool get _pageReady => switch (_page) {
    0 => _parametersReady,
    1 => _expressionsReady,
    _ => _motionsReady,
  };

  /// Sends the latest value for [id] once the previous command went out, so
  /// a dragged slider does not queue up commands. A release that has not gone
  /// out yet is dropped: the new drag ends with its own.
  void _drive(String id, double value) {
    _releasing.remove(id);
    _queued[id] = value;
    _start(id);
  }

  /// Clears [id] once its last value went out, so the preview's own motions
  /// move it again instead of holding the trial value.
  void _release(String id) {
    _releasing.add(id);
    _start(id);
  }

  void _start(String id) {
    if (_driving.add(id)) unawaited(_send(id));
  }

  Future<void> _send(String id) async {
    try {
      while (true) {
        if (_queued.remove(id) case final value?) {
          await widget.setParameter(id, value);
        } else if (_releasing.remove(id)) {
          await widget.clearParameter(id);
        } else {
          break;
        }
      }
      if (mounted && _driveError != null) setState(() => _driveError = null);
    } catch (_) {
      _queued.remove(id);
      _releasing.remove(id);
      if (mounted) setState(() => _driveError = '预览暂时无法试动。');
    } finally {
      _driving.remove(id);
    }
  }

  /// Runs a preview-only action, such as trying a motion; a failure shows one
/// line and leaves the mapping alone.
  void _tryPreview(Future<void> Function() action) {
    if (_busy) return;
    unawaited(() async {
      try {
        await action();
        if (mounted && _previewError != null) {
          setState(() => _previewError = null);
        }
      } catch (_) {
        if (mounted) setState(() => _previewError = '预览暂时无法试看。');
      }
    }());
  }

  Map<String, Object?> _profileJson() {
    final store = widget.store;
    return <String, Object?>{
      'schemaVersion': 1,
      'modelId': widget.modelId,
      'profileRev': (store.profile(widget.modelId)?.profileRev ?? 0) + 1,
      'modelFile': store.model(widget.modelId)?.model3,
      'paramMap': <String, Object?>{
        for (final slot in _slots) slot: _parameters[slot],
        'noExpressions': _noExpressions,
        'noMotions': _noMotions,
        'expressions': <String, Object?>{
          for (final key in Live2DParamMap.expressionKeys)
            key: ?_expressions[key],
        },
        'motions': <String, Object?>{
          for (final key in Live2DParamMap.expressionKeys)
            if (_motions[key] case (final group, final index))
              key: <String, Object?>{'group': group, 'index': index},
        },
      },
    };
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errors = const [];
    });
    var errors = const <String>[];
    try {
      await widget.store.saveProfile(Live2DProfile.fromJson(_profileJson()));
      _saved = true;
    } on FormatException catch (error) {
      errors = ['无法保存映射。', error.message];
    } on StateError catch (error) {
      errors = ['无法保存映射。', error.message];
    } catch (_) {
      errors = ['无法保存映射，请重试。'];
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _errors = errors;
    });
    if (_saved) widget.onChanged();
  }

  Future<void> _enable() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errors = const [];
    });
    final errors = await enableLive2DModel(
      widget.store,
      widget.modelId,
      widget.info,
      infoError: widget.infoError,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _errors = errors ?? const [];
    });
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errorStyle = TextStyle(color: theme.colorScheme.error);
    return Column(
      key: const Key('live2d-mapping-wizard'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        if (_saved)
          ..._savedView()
        else ...[
          Text(
            '第 ${_page + 1}/3 步：${_titles[_page]}',
            key: const Key('live2d-wizard-page'),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          ...switch (_page) {
            0 => _parameterPage(),
            1 => _expressionPage(),
            _ => _motionPage(),
          },
          const SizedBox(height: 8),
          _navigation(),
        ],
        if (_errors.isNotEmpty)
          Semantics(
            liveRegion: true,
            child: Column(
              key: const Key('live2d-wizard-errors'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in _errors) Text(line, style: errorStyle),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _parameterPage() {
    final info = widget.info;
    final parameters = info?.parameters;
    if (info == null || parameters == null) {
      return [
        Text(
          info == null ? '预览未提供有效的模型报告，无法设置映射。' : '模型未报告参数列表，无法设置映射。',
          key: const Key('live2d-wizard-blocked'),
        ),
        if (widget.infoError case final error?) Text(error),
      ];
    }
    return [
      const Text('拖动滑块可在预览中试动，松开后交还模型自身的动作。'),
      for (final slot in _slots) _parameterRow(slot, parameters),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          OutlinedButton(
            key: const Key('live2d-wizard-test-blink'),
            onPressed: _busy ? null : () => _tryPreview(widget.blink),
            child: const Text('测试眨眼'),
          ),
          OutlinedButton(
            key: const Key('live2d-wizard-test-speak'),
            onPressed: _busy
                ? null
                : () => _tryPreview(
                      () => widget.speak(_testSpeechLevels, 40),
                    ),
            child: const Text('测试说话'),
          ),
        ],
      ),
      if (_driveError case final error?)
        Text(error, key: const Key('live2d-wizard-drive-error')),
      if (_previewError case final error?)
        Text(error, key: const Key('live2d-wizard-preview-error')),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(
          key: const Key('live2d-wizard-reset'),
          onPressed: _busy ? null : () => setState(_suggestParameters),
          child: const Text('恢复建议值'),
        ),
      ),
    ];
  }

  Widget _parameterRow(String slot, List<Live2DParameterInfo> parameters) {
    final selected = _parameters[slot];
    final index = parameters.indexWhere(
      (parameter) => parameter.id == selected,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${_slotLabels[slot]}（$slot）'),
          DropdownButton<int>(
            key: Key('live2d-wizard-param-$slot'),
            isExpanded: true,
            value: index < 0 ? null : index,
            hint: const Text('请选择参数'),
            items: [
              for (var i = 0; i < parameters.length; i++)
                DropdownMenuItem<int>(
                  value: i,
                  child: Text(
                    parameters[i].id,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _busy
                ? null
                : (i) {
                    if (i != null) {
                      setState(() => _parameters[slot] = parameters[i].id);
                    }
                  },
          ),
          if (index >= 0) _trial(slot, parameters[index]),
        ],
      ),
    );
  }

  Widget _trial(String slot, Live2DParameterInfo parameter) {
    final min = parameter.min;
    final max = parameter.max;
    final initial = parameter.defaultValue;
    if (min == null ||
        max == null ||
        initial == null ||
        !(min < max) ||
        initial < min ||
        initial > max) {
      return const Text('模型未报告此参数的范围或默认值，无法试动。');
    }
    final value = _trialSlot == slot
        ? _trialValue.clamp(min, max).toDouble()
        : initial;
    return Slider(
      key: Key('live2d-wizard-slider-$slot'),
      min: min,
      max: max,
      value: value,
      semanticFormatterCallback: (value) => value.toStringAsFixed(2),
      onChanged: _busy
          ? null
          : (value) {
              setState(() {
                _trialSlot = slot;
                _trialValue = value;
              });
              _drive(parameter.id, value);
            },
      onChangeEnd: (_) {
        setState(() => _trialSlot = null);
        _release(parameter.id);
      },
    );
  }

  List<Widget> _expressionPage() {
    final names = widget.info?.expressions;
    if (names == null) {
      return const [
        Text('模型未报告表情列表，无法映射表情，因此不能保存。', key: Key('live2d-wizard-blocked')),
      ];
    }
    return [
      const Text('选择后可试看一次；试看不会保存。'),
      if (names.isEmpty)
        CheckboxListTile(
          key: const Key('live2d-wizard-no-expressions'),
          contentPadding: EdgeInsets.zero,
          value: _noExpressions,
          title: const Text('此模型没有表情'),
          onChanged: _busy
              ? null
              : (value) => setState(() => _noExpressions = value ?? false),
        )
      else ...[
        const Text('至少映射一项。'),
        for (final key in Live2DParamMap.expressionKeys)
          _choiceRow(
            Key('live2d-wizard-expression-$key'),
            '${_semanticLabel(key)}（$key）',
            names,
            switch (_expressions[key]) {
              final name? => names.indexOf(name),
              null => -1,
            },
            (i) => setState(() {
              if (i < 0) {
                _expressions.remove(key);
              } else {
                _expressions[key] = names[i];
              }
            }),
            previewKey: Key('live2d-wizard-expression-' '$key' '-preview'),
            onPreview: switch (_expressions[key]) {
              final name? => () => _tryPreview(
                    () => widget.setExpression(name),
                  ),
              null => null,
            },
          ),
        if (_previewError case final error?)
          Text(error, key: const Key('live2d-wizard-preview-error')),
      ],
    ];
  }

  List<Widget> _motionPage() {
    final groups = widget.info?.motions;
    if (groups == null) {
      return const [
        Text('模型未报告动作列表，无法映射动作，因此不能保存。', key: Key('live2d-wizard-blocked')),
      ];
    }
    final motions = [
      for (final group in groups)
        for (var i = 0; i < group.count; i++) (group.group, i),
    ];
    final labels = [
      for (final (group, index) in motions) live2dMotionLabel(group, index),
    ];
    return [
      const Text('选择后可试看一次；试看不会保存。'),
      if (motions.isEmpty)
        CheckboxListTile(
          key: const Key('live2d-wizard-no-motions'),
          contentPadding: EdgeInsets.zero,
          value: _noMotions,
          title: const Text('此模型没有动作'),
          onChanged: _busy
              ? null
              : (value) => setState(() => _noMotions = value ?? false),
        )
      else ...[
        const Text('至少映射一项。'),
        for (final key in Live2DParamMap.expressionKeys)
          _choiceRow(
            Key('live2d-wizard-motion-$key'),
            '${_semanticLabel(key)}（$key）',
            labels,
            switch (_motions[key]) {
              final motion? => motions.indexOf(motion),
              null => -1,
            },
            (i) => setState(() {
              if (i < 0) {
                _motions.remove(key);
              } else {
                _motions[key] = motions[i];
              }
            }),
            previewKey: Key('live2d-wizard-motion-$key-preview'),
            onPreview: switch (_motions[key]) {
              final motion? => () => _tryPreview(
                    () => widget.playMotion(motion.$1, motion.$2),
                  ),
              null => null,
            },
          ),
        if (_previewError case final error?)
          Text(error, key: const Key('live2d-wizard-preview-error')),
      ],
    ];
  }

  Widget _choiceRow(
    Key key,
    String label,
    List<String> options,
    int selected,
    ValueChanged<int> onChanged, {
    Key? previewKey,
    VoidCallback? onPreview,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          DropdownButton<int>(
            key: key,
            isExpanded: true,
            value: selected,
            items: [
              const DropdownMenuItem<int>(value: -1, child: Text('不映射')),
              for (var i = 0; i < options.length; i++)
                DropdownMenuItem<int>(
                  value: i,
                  child: Text(options[i], overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: _busy
                ? null
                : (i) {
                    if (i != null) onChanged(i);
                  },
          ),
          if (onPreview != null && selected >= 0)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: previewKey,
                onPressed: _busy ? null : onPreview,
                child: const Text('试看'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _navigation() {
    final ready = _pageReady && !_busy;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        TextButton(
          key: const Key('live2d-wizard-cancel'),
          onPressed: _busy ? null : widget.onClose,
          child: const Text('取消'),
        ),
        if (_page > 0)
          OutlinedButton(
            key: const Key('live2d-wizard-back'),
            onPressed: _busy ? null : () => setState(() => _page--),
            child: const Text('上一步'),
          ),
        if (_page < 2)
          FilledButton(
            key: const Key('live2d-wizard-next'),
            onPressed: ready ? () => setState(() => _page++) : null,
            child: const Text('下一步'),
          )
        else
          FilledButton(
            key: const Key('live2d-wizard-save'),
            onPressed: ready && _parametersReady && _expressionsReady
                ? _save
                : null,
            child: const Text('确认并保存'),
          ),
      ],
    );
  }

  List<Widget> _savedView() {
    final active = widget.store.activeModelId == widget.modelId;
    return [
      Semantics(
        liveRegion: true,
        child: Text(
          active ? '已启用。会显示在聊天页，暂不显示在世界场景中。' : '映射已保存，尚未启用。',
          key: const Key('live2d-wizard-saved'),
        ),
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        children: [
          if (!active)
            FilledButton(
              key: const Key('live2d-wizard-enable'),
              onPressed: _busy ? null : _enable,
              child: const Text('启用此形象'),
            ),
          TextButton(
            key: const Key('live2d-wizard-done'),
            onPressed: _busy ? null : widget.onClose,
            child: const Text('完成'),
          ),
        ],
      ),
    ];
  }
}
