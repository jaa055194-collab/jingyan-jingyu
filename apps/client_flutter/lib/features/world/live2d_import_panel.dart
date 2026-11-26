import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:material_ui/material_ui.dart';

import 'live2d_preview_view.dart';

/// Owns temporary resources until the world panel closes or releases them.
final class Live2DImportSession {
  const Live2DImportSession(this.close, {this.previewDirectory});

  final Future<void> Function() close;

  /// Absolute path of the staged preview inside the app's `live2d-preview`
  /// cache directory, shown until [close]; null when there is nothing to
  /// show. Only Android has a preview host; other platforms ignore it.
  final String? previewDirectory;
}

final class Live2DImportFailure implements Exception {
  const Live2DImportFailure(this.message);

  final String message;
}

class Live2DImportPanel extends StatefulWidget {
  const Live2DImportPanel({super.key, required this.open, this.enabled = true});

  final Future<Live2DImportSession?> Function() open;
  final bool enabled;

  @override
  State<Live2DImportPanel> createState() => _Live2DImportPanelState();
}

class _Live2DImportPanelState extends State<Live2DImportPanel>
    with AutomaticKeepAliveClientMixin<Live2DImportPanel> {
  Live2DImportSession? _session;
  bool _busy = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  /// The stage to show. Only Android has a preview host, so elsewhere the
  /// panel keeps the prepared-files text and creates no platform view.
  String? get _previewDirectory =>
      defaultTargetPlatform == TargetPlatform.android
      ? _session?.previewDirectory
      : null;

  Future<void> _open() async {
    if (_busy || _session != null || !widget.enabled) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await widget.open();
      if (!mounted) {
        if (session != null) await _discard(session);
        return;
      }
      setState(() => _session = session);
    } on Live2DImportFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } catch (_) {
      if (mounted) setState(() => _error = '无法准备此模型包，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _release() async {
    final session = _session;
    if (session == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.close();
      if (mounted) setState(() => _session = null);
    } catch (_) {
      if (mounted) setState(() => _error = '临时文件未能清理，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Future<void> _discard(Live2DImportSession session) async {
    // Lifecycle cleanup is best-effort. Do not log personal file paths.
    try {
      await session.close();
    } catch (_) {
      try {
        await session.close();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    final session = _session;
    if (session != null) unawaited(_discard(session));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('从本机选择模型包，仅准备临时预览文件，不会上传。'),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('live2d-select-zip'),
          onPressed: widget.enabled && !_busy && _session == null
              ? _open
              : null,
          icon: const Icon(Icons.folder_open_outlined),
          label: const Text('选择 Live2D ZIP'),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(semanticsLabel: '正在处理本机模型包'),
          ),
        if (_session != null) ...[
          // Hidden while the files are cleaned, so the view goes first.
          if (_previewDirectory case final directory? when !_busy) ...[
            const SizedBox(height: 4),
            Card(
              key: const Key('live2d-import-preview'),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                height: 280,
                child: Live2DPreviewView(directory: directory),
              ),
            ),
          ],
          Semantics(
            liveRegion: true,
            child: Text(
              _previewDirectory == null
                  ? '已准备临时预览文件，未显示或启用形象。'
                  : '仅本机临时预览，未启用形象。',
              key: const Key('live2d-import-prepared'),
            ),
          ),
          TextButton(
            key: const Key('live2d-release-zip'),
            onPressed: _busy ? null : _release,
            child: const Text('清理临时文件'),
          ),
        ],
        if (_error case final error?)
          Semantics(
            liveRegion: true,
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}
