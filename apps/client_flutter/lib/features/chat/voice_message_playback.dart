import 'package:material_ui/material_ui.dart';

import '../../app/shell_view_model.dart';

/// Inline action for a sent audio row. It never owns the media bytes.
class VoiceMessagePlaybackControl extends StatelessWidget {
  const VoiceMessagePlaybackControl({
    super.key,
    required this.messageId,
    required this.phase,
    required this.onPlay,
    required this.onStop,
  });

  final String messageId;
  final ShellVoicePhase? phase;
  final VoidCallback? onPlay;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final active =
        phase == ShellVoicePhase.loading || phase == ShellVoicePhase.playing;
    final status = switch (phase) {
      ShellVoicePhase.loading => '正在加载语音…',
      ShellVoicePhase.denied => '语音不可访问。',
      ShellVoicePhase.unavailable => '语音暂无法播放。',
      ShellVoicePhase.playing || null => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          key: Key('${active ? 'stop' : 'play'}-voice-$messageId'),
          onPressed: active ? onStop : onPlay,
          icon: Icon(active ? Icons.stop : Icons.play_arrow, size: 18),
          label: Text(switch (phase) {
            ShellVoicePhase.loading => '取消加载',
            ShellVoicePhase.playing => '停止播放',
            _ => '播放语音',
          }),
        ),
        if (status != null)
          Semantics(
            liveRegion: true,
            child: Text(status, style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }
}
