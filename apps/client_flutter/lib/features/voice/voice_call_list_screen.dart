import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../net/host_connection.dart';
import '../../net/voice_call_api.dart';
import '../../ui/ui.dart';

typedef VoiceCallLister = Future<List<VoiceCallView>> Function({
  String? status,
  required int limit,
  DateTime? before,
});

const _statusChoices = <(String?, String)>[
  (null, '全部'),
  ('ringing', '响铃中'),
  ('active', '通话中'),
  ('missed', '未接来电'),
  ('ended', '已结束'),
];

enum _Phase { unbound, loading, empty, denied, unknown, ready }

/// Honest, read-only owner-scoped voice call list.
///
/// Consumes `GET /voice/calls` metadata only (status/对端/时间戳; no audio, no
/// transcript). States are explicit: unbound, loading, empty, denied, unknown,
/// or a ready list with optional "load more" pagination. Nothing here answers,
/// ends or interrupts a call.
class VoiceCallListScreen extends StatefulWidget {
  const VoiceCallListScreen({super.key, this.listCalls, this.pageSize = 50});

  /// Host-backed lister ([VoiceCallApi.listCalls] in production).
  final VoiceCallLister? listCalls;

  /// Page size, 1..100 (host bound).
  final int pageSize;

  @override
  State<VoiceCallListScreen> createState() => _VoiceCallListScreenState();
}

class _VoiceCallListScreenState extends State<VoiceCallListScreen> {
  String? _status;
  final List<VoiceCallView> _items = <VoiceCallView>[];
  _Phase _phase = _Phase.loading;
  String? _notice;
  bool _busy = false;
  bool _hasMore = false;

  @override
  void initState() {
    super.initState();
    if (widget.listCalls == null) {
      _phase = _Phase.unbound;
    } else {
      _load();
    }
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

  Future<void> _load({bool more = false}) async {
    final lister = widget.listCalls;
    if (lister == null || _busy) return;
    setState(() {
      _busy = true;
      _notice = null;
      if (!more) {
        _phase = _Phase.loading;
        _items.clear();
        _hasMore = false;
      }
    });
    try {
      final page = await lister(
        status: _status,
        limit: widget.pageSize,
        before: more && _items.isNotEmpty ? _items.last.startedAt : null,
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(page);
        _hasMore = page.length == widget.pageSize;
        _phase = _items.isEmpty ? _Phase.empty : _Phase.ready;
      });
    } on HostRequestException catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = switch (error.failure.code) {
          FailureCode.unauthenticated || FailureCode.forbidden => _Phase.denied,
          _ => _Phase.unknown,
        };
        _notice = _phase == _Phase.denied
            ? '无权限查看通话列表；不对结果做推测，不会自动重试。'
            : '读取失败或结果未确认；不会自动重试。';
      });
    } on FormatException {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.unknown;
        _notice = '通话列表响应无效或参数无效；不会自动重试。';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.unknown;
        _notice = '读取失败或结果未确认；不会自动重试。';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _card(VoiceCallView call, TextStyle? title) => JySlab(
    key: Key('voice-call-item-${call.callId}'),
    padding: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('状态：${_state(call.state)}', style: title),
          Text('通话标识：${call.callId}'),
          Text('AI 档案：${call.aiId}'),
          Text('对端账号：${call.peerAccountId}'),
          Text('开始：${_time(call.startedAt)}'),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final bound = widget.listCalls != null;
    return Scaffold(
      appBar: AppBar(title: const Text('语音通话列表')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '只读列出当前账号发起的通话元数据（状态/AI/对端/时间戳）。'
            '不接听、不结束、不播放音频，也不显示转写正文。不代表可接听或已授权。',
          ),
          const SizedBox(height: 12),
          if (!bound)
            const Text(
              '当前入口未接线宿主连接：通话列表不可用（需装配 VoiceCallApi）。',
              key: Key('voice-call-list-unbound'),
            )
          else ...[
            InputDecorator(
              decoration: const InputDecoration(labelText: '状态过滤'),
              child: DropdownButton<String?>(
                key: const Key('voice-call-status-filter'),
                value: _status,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: [
                  for (final (value, label) in _statusChoices)
                    DropdownMenuItem<String?>(value: value, child: Text(label)),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        setState(() => _status = value);
                        _load();
                      },
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('voice-call-list-refresh'),
              onPressed: _busy ? null : () => _load(),
              child: Text(_busy ? '读取中…' : '刷新'),
            ),
            const SizedBox(height: 12),
            if (_phase == _Phase.loading)
              const Padding(
                padding: EdgeInsets.all(JySpace.lg),
                child: Center(child: JyBusyIndicator(label: '正在读取通话列表')),
              )
            else if (_phase == _Phase.denied)
              Text(
                _notice ?? '无权限查看通话列表。',
                key: const Key('voice-call-list-denied'),
              )
            else if (_phase == _Phase.unknown)
              Text(
                _notice ?? '读取失败或结果未确认。',
                key: const Key('voice-call-list-unknown'),
              )
            else if (_phase == _Phase.empty)
              const Text(
                '没有可显示的通话（或该状态下暂无通话）。',
                key: Key('voice-call-list-empty'),
              )
            else if (_phase == _Phase.ready) ...[
              for (final call in _items) _card(call, text.titleMedium),
              if (_hasMore)
                TextButton(
                  key: const Key('voice-call-list-load-more'),
                  onPressed: _busy ? null : () => _load(more: true),
                  child: const Text('加载更多'),
                ),
            ],
          ],
        ],
      ),
    );
  }
}
