import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../net/host_connection.dart';
import '../../net/voice_call_api.dart';

/// Honest, read-only single-call view.
///
/// The host exposes `GET /voice/calls/{callId}` only — there is **no** call list
/// route — so the caller must enter an explicit callId; nothing here answers,
/// ends or interrupts a call, and no audio or transcript is ever requested or
/// rendered. States are explicit: unbound, loading, denied, unknown, ready.
class VoiceCallScreen extends StatefulWidget {
  const VoiceCallScreen({super.key, this.readCall});

  /// Host-backed reader ([VoiceCallApi.readCall] in production).
  final Future<VoiceCallView> Function(String callId)? readCall;

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen> {
  final _callId = TextEditingController();
  VoiceCallView? _call;
  String? _notice;
  bool _busy = false;

  @override
  void dispose() {
    _callId.dispose();
    super.dispose();
  }

  static String _state(String state) => switch (state) {
    'ringing' => '响铃中',
    'active' => '通话中',
    'missed' => '未接来电',
    'ended' => '已结束',
    _ => '未知状态',
  };

  static String _time(DateTime? value) =>
      value == null ? '无' : value.toUtc().toIso8601String();

  Future<void> _read() async {
    final read = widget.readCall;
    final id = _callId.text.trim();
    if (read == null || id.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _notice = null;
      _call = null;
    });
    try {
      final call = await read(id);
      if (!mounted) return;
      setState(() => _call = call);
    } on HostRequestException catch (error) {
      if (!mounted) return;
      setState(() {
        _notice = switch (error.failure.code) {
          FailureCode.unauthenticated ||
          FailureCode.forbidden => '无权限查看该通话；不对结果做推测，不会自动重试。',
          FailureCode.notFound => '未找到该通话；不会自动重试。',
          _ => '读取失败或结果未确认；不会自动重试。',
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _notice = '读取失败或结果未确认；不会自动重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final read = widget.readCall;
    return Scaffold(
      appBar: AppBar(title: const Text('语音通话状态')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '只读查看一通语音通话的状态元数据（状态/对端/时间戳）。'
            '宿主未提供通话列表路由，需显式输入通话标识；不接听、不结束、不播放音频。',
          ),
          const SizedBox(height: 12),
          if (read == null)
            const Text(
              '当前入口未接线宿主连接：读取不可用（需装配 VoiceCallApi）。',
              key: Key('voice-call-unbound'),
            )
          else ...[
            TextField(
              key: const Key('voice-call-id-input'),
              controller: _callId,
              decoration: const InputDecoration(
                labelText: '通话标识（callId）',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _read(),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('voice-call-read'),
              onPressed: _busy ? null : _read,
              child: Text(_busy ? '读取中…' : '读取状态'),
            ),
            const SizedBox(height: 12),
            if (_notice != null)
              Text(
                _notice!,
                key: Key(
                  _notice!.startsWith('无权限')
                      ? 'voice-call-denied'
                      : 'voice-call-unknown',
                ),
              ),
            if (_call != null)
              Card(
                key: const Key('voice-call-metadata'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '状态：${_state(_call!.state)}',
                        style: text.titleMedium,
                      ),
                      Text('通话标识：${_call!.callId}'),
                      Text('AI 档案：${_call!.aiId}'),
                      Text('对端账号：${_call!.peerAccountId}'),
                      Text('开始：${_time(_call!.startedAt)}'),
                      Text('接听：${_time(_call!.answeredAt)}'),
                      Text('结束：${_time(_call!.endedAt)}'),
                      const SizedBox(height: 4),
                      const Text('仅为状态元数据，不代表可接听、已授权或已接通。'),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
