import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../net/host_connection.dart';
import '../../net/voice_api.dart';
import '../../ui/ui.dart';

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
    _VoiceState.missing =>
      '未配置音色档案（宿主返回不存在）：该 AI 尚未在宿主音色工作台配置，'
          '不是权限问题。',
    _VoiceState.denied => '无权读取该音色档案（已登录但被拒绝）。',
    _VoiceState.unknown =>
      '状态未知：未连接宿主或响应无法验证。不会自动重试；'
          '未知不代表已配置，也不代表未配置。',
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
        const SizedBox(height: 4),
        Text(
          '提示：档案 id 形如 ai_…，在“我的 AI”创建后由宿主生成；本页读取的 provider/model/voiceId '
          '仅为配置元数据，不代表音色可用、已授权或可发起语音通话。',
          key: const Key('voice-help'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('voice-ai-id'),
          controller: _input,
          enabled: widget.loadProfile != null && _state != _VoiceState.loading,
          decoration: InputDecoration(
            labelText: 'AI 档案 id',
            helperText: widget.loadProfile == null
                ? '当前入口未接线宿主连接，读取不可用'
                : '例如 ai_xxx；留空无法读取',
            border: const OutlineInputBorder(),
          ),
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
            padding: EdgeInsets.all(JySpace.lg),
            child: Center(child: JyBusyIndicator(label: '正在读取音色档案')),
          ),
        if (_state == _VoiceState.present && _profile != null)
          JySlab(
            key: const Key('voice-profile'),
            padding: EdgeInsets.zero,
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
        const Divider(height: 32),
        Text('语音文件', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        JySlab(
          key: const Key('voice-assets-unavailable'),
          padding: EdgeInsets.zero,
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前不可用：宿主未提供语音资产/文件列表路由。'),
                SizedBox(height: 4),
                Text('合成音频不落盘，仅返回短期可播放句柄；宿主没有可列的音频 blob 元数据。'),
                SizedBox(height: 4),
                Text('本页不列出语音文件、不播放、也不渲染任何音频内容；此处如实标注缺口，不代表没有配置音色。'),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
