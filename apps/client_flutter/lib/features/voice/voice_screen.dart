import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../net/host_connection.dart';
import '../../net/voice_api.dart';

/// Read-only voice profile inspector (developer tool).
///
/// Only GET [VoiceApi.readProfile] is used; the ticket-issuing call is never
/// invoked. The host addresses a voice profile by AI profile id, which is not
/// the same as an AI account id, so the id is entered explicitly rather than
/// inferred. Parameter values are never rendered (keys only) to avoid leaking
/// any vendor or secret material. States are honest: missing/denied/unknown.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key, this.loadProfile});

  final Future<VoiceProfileView> Function(String aiId)? loadProfile;

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

enum _VoiceState { idle, loading, present, missing, denied, unknown }

class _VoiceScreenState extends State<VoiceScreen> {
  final _input = TextEditingController();
  _VoiceState _state = _VoiceState.idle;
  VoiceProfileView? _profile;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _read() async {
    final load = widget.loadProfile;
    final aiId = _input.text.trim();
    if (load == null || aiId.isEmpty) {
      setState(() {
        _state = _VoiceState.unknown;
        _profile = null;
      });
      return;
    }
    setState(() {
      _state = _VoiceState.loading;
      _profile = null;
    });
    try {
      final profile = await load(aiId);
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _state = _VoiceState.present;
      });
    } on HostRequestException catch (error) {
      if (!mounted) return;
      setState(() {
        _profile = null;
        _state = switch (error.failure.code) {
          FailureCode.notFound => _VoiceState.missing,
          FailureCode.forbidden ||
          FailureCode.unauthenticated => _VoiceState.denied,
          _ => _VoiceState.unknown,
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _profile = null;
        _state = _VoiceState.unknown;
      });
    }
  }

  String _paramsKeys(Map<String, Object?>? params) {
    if (params == null) return '无';
    if (params.isEmpty) return '空';
    return params.keys.join('、');
  }

  String _stateText() => switch (_state) {
    _VoiceState.idle => '输入 AI 档案 id 后读取；只读，不会签发票据或修改配置。',
    _VoiceState.loading => '正在读取…',
    _VoiceState.present => '已读取音色档案（只读）。',
    _VoiceState.missing => '未配置音色档案（宿主返回不存在）。',
    _VoiceState.denied => '无权读取该音色档案（已登录但被拒绝）。',
    _VoiceState.unknown => '状态未知：未连接宿主或响应无法验证。不会自动重试。',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('语音音色')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '只读：查看某 AI 的音色档案。AI 档案 id 与 AI 账户 id 不是同一个概念，需显式输入；不自动推断、不签发票据、不修改配置。',
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('voice-ai-id'),
          controller: _input,
          enabled: widget.loadProfile != null && _state != _VoiceState.loading,
          decoration: const InputDecoration(labelText: 'AI 档案 id'),
          onSubmitted: (_) => _read(),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: const Key('voice-read'),
            onPressed:
                widget.loadProfile == null || _state == _VoiceState.loading
                ? null
                : _read,
            child: const Text('读取'),
          ),
        ),
        const SizedBox(height: 12),
        Text(_stateText()),
        if (_state == _VoiceState.loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_state == _VoiceState.present && _profile != null)
          Card(
            key: const Key('voice-profile'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('AI 档案：${_profile!.aiId}'),
                  Text('provider：${_profile!.provider}'),
                  Text('model：${_profile!.model}'),
                  Text('voiceId：${_profile!.voiceId}'),
                  Text('revision：${_profile!.revision}'),
                  Text('consentRef：${_profile!.consentRef}'),
                  Text(
                    'activatedAt：${_profile!.activatedAt.toUtc().toIso8601String()}',
                  ),
                  Text(
                    '待生效 revision：${_profile!.pendingRevision?.toString() ?? '无'}',
                  ),
                  Text('待生效参数键：${_paramsKeys(_profile!.pendingParams)}'),
                  Text('参数键：${_paramsKeys(_profile!.params)}'),
                  const SizedBox(height: 4),
                  const Text('已配置音色档案仅表示配置存在，不代表可用或已授权；本页不签发票据、不做厂商调用。'),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
