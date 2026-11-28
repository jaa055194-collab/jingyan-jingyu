import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'live2d_kept_models.dart';
import 'live2d_mapping_wizard.dart';
import 'live2d_preview_view.dart';

/// Owns temporary resources until the world panel closes or releases them.
final class Live2DImportSession {
  const Live2DImportSession(
    this.close, {
    this.previewDirectory,
    this.displayName = '未命名模型',
    this.groups = const <Live2DModelGroup>[],
    this.readFiles,
  });

  final Future<void> Function() close;

  /// Absolute path of the staged preview inside the app's `live2d-preview`
  /// cache directory, shown until [close]; null when there is nothing to
  /// show. Only Android has a preview host; other platforms ignore it.
  final String? previewDirectory;

  /// The display name a kept copy of this model gets.
  final String displayName;

  /// The package's model3 groups, which feed the mapping suggestions.
  final List<Live2DModelGroup> groups;

  /// Reads back the staged files, keyed by their names relative to
  /// [previewDirectory], so that the model can be kept; null when it cannot.
  final Future<Map<String, List<int>>> Function()? readFiles;
}

final class Live2DImportFailure implements Exception {
  const Live2DImportFailure(this.message);

  final String message;
}

class Live2DImportPanel extends StatefulWidget {
  const Live2DImportPanel({
    super.key,
    required this.open,
    this.enabled = true,
    this.openStore = openDeviceLive2DStore,
    this.onAvatarEnabled,
  });

  final Future<Live2DImportSession?> Function() open;
  final bool enabled;

  /// Called after the enabled model changed (another model enabled, disabled,
  /// or its mapping re-enabled), so the resident chat card can reload it while
  /// hidden from chat.
  final VoidCallback? onAvatarEnabled;

  /// Opens the store of the models kept on this device. Only Android keeps
  /// models, so it is not called elsewhere.
  final Future<Live2DFileStore> Function() openStore;

  @override
  State<Live2DImportPanel> createState() => _Live2DImportPanelState();
}

class _Live2DImportPanelState extends State<Live2DImportPanel>
    with AutomaticKeepAliveClientMixin<Live2DImportPanel> {
  Live2DImportSession? _session;
  bool _busy = false;

  /// True while the temporary files are removed; the preview goes first.
  bool _cleaning = false;
  String? _error;

  /// The controller of the temporary preview, once it was ready.
  Live2DPreviewController? _previewReady;

  /// The model kept from the current temporary preview while its files
  /// could not be removed yet. It is not kept a second time, and its preview
  /// opens once the temporary files are cleaned.
  String? _sessionKeptId;

  Live2DFileStore? _store;
  String? _storeError;

  /// The kept model whose preview is open, and that preview's controller
  /// once it is ready.
  String? _keptId;
  Live2DPreviewController? _keptReady;

  /// What that preview reported when it became ready. Kept after a later
  /// failure, because it still describes the kept files.
  Live2DModelInfo? _keptInfo;
  String? _keptInfoError;
  bool _wizard = false;
  bool _enableWhenReady = false;
  List<String> _keptErrors = const [];

  /// The groups of the models kept during this run, for the suggestions.
  final Map<String, List<Live2DModelGroup>> _groups = {};

  @override
  bool get wantKeepAlive => true;

  /// Only Android has a preview host and a model store.
  bool get _android => defaultTargetPlatform == TargetPlatform.android;

  /// The stage to show. Elsewhere the panel keeps the prepared-files text
  /// and creates no platform view.
  String? get _previewDirectory => _android ? _session?.previewDirectory : null;

  @override
  void initState() {
    super.initState();
    if (_android) unawaited(_openStore());
  }

  Future<void> _openStore() async {
    String error;
    try {
      final store = await widget.openStore();
      if (mounted) {
        setState(() {
          _store = store;
          _storeError = null;
        });
      }
      return;
    } on FormatException {
      error = '本机模型记录无法读取。';
    } catch (_) {
      error = '无法打开本机模型存储。';
    }
    // The error itself can contain a path; only a fixed text is shown.
    if (mounted) setState(() => _storeError = error);
  }

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
      setState(() {
        // Only one preview at a time: a new ZIP closes the kept preview.
        if (session != null) _closeKept();
        _session = session;
        _previewReady = null;
      });
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
      _cleaning = true;
      _error = null;
    });
    try {
      await session.close();
      if (mounted) {
        setState(() {
          _session = null;
          _previewReady = null;
          final kept = _sessionKeptId;
          _sessionKeptId = null;
          if (kept != null && _store?.model(kept) != null) _openKept(kept);
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '临时文件未能清理，请重试。');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _cleaning = false;
        });
      }
    }
  }

  /// Copies the ready temporary preview into the store, removes the
  /// temporary files and opens the preview of the kept copy.
  Future<void> _keep() async {
    final session = _session;
    final store = _store;
    final read = session?.readFiles;
    final ready = _previewReady;
    if (session == null ||
        store == null ||
        read == null ||
        ready == null ||
        _sessionKeptId != null ||
        _busy ||
        !widget.enabled) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _keptErrors = const [];
    });
    String? kept;
    var errors = const <String>[];
    try {
      if (ready.state != Live2DPreviewState.ready) {
        errors = const ['预览未就绪，无法保留此模型。'];
      } else {
        final files = await read();
        final id = newLive2DModelId(store);
        await store.importModel(
          modelId: id,
          displayName: session.displayName,
          model3: Live2DPreviewView.model3Name,
          files: files,
        );
        kept = id;
      }
    } on FormatException catch (error) {
      errors = ['无法保留此模型。', error.message];
    } on StateError catch (error) {
      errors = ['无法保留此模型。', error.message];
    } catch (_) {
      errors = const ['无法保留此模型，请重试。'];
    }
    if (!mounted) return;
    if (kept == null) {
      setState(() {
        _busy = false;
        _error = errors.join('\n');
      });
      return;
    }
    _groups[kept] = session.groups;
    setState(() => _cleaning = true);
    var cleaned = true;
    try {
      await session.close();
    } catch (_) {
      cleaned = false;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _cleaning = false;
      if (cleaned) {
        _session = null;
        _previewReady = null;
        _openKept(kept!);
      } else {
        // Keeping again would add a second copy.
        _sessionKeptId = kept;
        _error = '模型已保留，但临时文件未能清理，请点“清理临时文件”重试。';
      }
    });
  }

  /// Shows the preview of the kept model [id], replacing any other.
  void _openKept(String id) {
    if (_keptId != id) {
      _keptId = id;
      _keptReady = null;
      _keptInfo = null;
      _keptInfoError = null;
    }
    _wizard = false;
    _enableWhenReady = false;
    _keptErrors = const [];
  }

  void _closeKept() {
    _keptId = null;
    _keptReady = null;
    _keptInfo = null;
    _keptInfoError = null;
    _wizard = false;
    _enableWhenReady = false;
    _keptErrors = const [];
  }

  void _onKeptReady(String id, Live2DPreviewController controller) {
    if (!mounted || _keptId != id) return;
    final enable = _enableWhenReady;
    setState(() {
      _keptReady = controller;
      _keptInfo = controller.modelInfo;
      _keptInfoError = controller.modelInfoError;
      _enableWhenReady = false;
    });
    if (enable) unawaited(_enable(id));
  }

  void _map(String id) {
    setState(() {
      _openKept(id);
      _wizard = true;
    });
  }

  /// Enables [id] with the info of a ready preview of its kept files, and
  /// opens that preview first when it is not the ready one.
  Future<void> _enable(String id) async {
    final store = _store;
    if (store == null || _busy) return;
    final controller = _keptId == id ? _keptReady : null;
    if (controller == null || controller.state != Live2DPreviewState.ready) {
      setState(() {
        _openKept(id);
        _enableWhenReady = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _keptErrors = const [];
    });
    final errors = await enableLive2DModel(
      store,
      id,
      controller.modelInfo,
      infoError: controller.modelInfoError,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _keptErrors = errors ?? const [];
    });
    if (errors == null) widget.onAvatarEnabled?.call();
  }

  Future<void> _disable() async {
    final store = _store;
    if (store == null || _busy) return;
    setState(() {
      _busy = true;
      _keptErrors = const [];
    });
    var errors = const <String>[];
    try {
      await store.clearActive();
    } catch (_) {
      errors = const ['无法停用，请重试。'];
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _keptErrors = errors;
    });
    if (errors.isEmpty) widget.onAvatarEnabled?.call();
  }

  Future<void> _delete(Live2DStoredModel model) async {
    final store = _store;
    if (store == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('live2d-delete-dialog'),
        title: const Text('删除此模型？'),
        content: Text('将从本机删除「${model.displayName}」的模型文件和映射，无法恢复。'),
        actions: [
          TextButton(
            key: const Key('live2d-delete-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('live2d-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _busy) return;
    setState(() {
      _busy = true;
      // The preview of a deleted model goes first.
      if (_keptId == model.id) _closeKept();
      _keptErrors = const [];
    });
    var errors = const <String>[];
    try {
      await store.delete(model.id);
    } catch (_) {
      errors = const ['无法删除，请重试。'];
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _keptErrors = errors;
    });
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
    final theme = Theme.of(context);
    final errorStyle = TextStyle(color: theme.colorScheme.error);
    final session = _session;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('从本机选择模型包，仅准备临时预览文件，不会上传。'),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('live2d-select-zip'),
          onPressed: widget.enabled && !_busy && session == null ? _open : null,
          icon: const Icon(Icons.folder_open_outlined),
          label: const Text('选择 Live2D ZIP'),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(semanticsLabel: '正在处理本机模型包'),
          ),
        if (session != null) ...[
          // Hidden while the files are cleaned, so the view goes first.
          if (_previewDirectory case final directory? when !_cleaning) ...[
            const SizedBox(height: 4),
            Card(
              key: const Key('live2d-import-preview'),
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                height: 280,
                child: Live2DPreviewView(
                  directory: directory,
                  onReady: (controller) {
                    if (mounted) setState(() => _previewReady = controller);
                  },
                ),
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
          Wrap(
            spacing: 8,
            children: [
              if (_previewDirectory != null &&
                  _store != null &&
                  session.readFiles != null &&
                  _previewReady != null &&
                  _sessionKeptId == null)
                FilledButton(
                  key: const Key('live2d-keep'),
                  onPressed: widget.enabled && !_busy ? _keep : null,
                  child: const Text('保留此模型'),
                ),
              TextButton(
                key: const Key('live2d-release-zip'),
                onPressed: _busy ? null : _release,
                child: const Text('清理临时文件'),
              ),
            ],
          ),
        ],
        if (_error case final error?)
          Semantics(liveRegion: true, child: Text(error, style: errorStyle)),
        if (_android) ..._keptSection(theme, errorStyle),
      ],
    );
  }

  List<Widget> _keptSection(ThemeData theme, TextStyle errorStyle) {
    final store = _store;
    final keptId = _keptId;
    final kept = keptId == null ? null : store?.model(keptId);
    return [
      const Divider(height: 24),
      Text('本机保存的模型', style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      const Text('仅保存在本机，不会上传。启用的形象会显示在聊天页，暂不显示在世界场景中。'),
      if (store == null)
        if (_storeError case final error?)
          Row(
            children: [
              Expanded(
                child: Text(
                  error,
                  key: const Key('live2d-store-error'),
                  style: errorStyle,
                ),
              ),
              TextButton(
                key: const Key('live2d-store-retry'),
                onPressed: () {
                  setState(() => _storeError = null);
                  unawaited(_openStore());
                },
                child: const Text('重试'),
              ),
            ],
          )
        else
          const Text('正在读取本机保存的模型…', key: Key('live2d-store-loading'))
      else ...[
        if (store.models.isEmpty)
          const Text('还没有保存的模型。', key: Key('live2d-kept-empty')),
        for (final model in store.models) _keptRow(theme, store, model),
        if (_session != null && store.models.isNotEmpty)
          const Text('先保留或清理临时预览，才能预览已保存的模型。', key: Key('live2d-kept-blocked')),
        if (_keptErrors.isNotEmpty)
          Semantics(
            liveRegion: true,
            child: Column(
              key: const Key('live2d-kept-errors'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in _keptErrors) Text(line, style: errorStyle),
              ],
            ),
          ),
        if (kept != null) ..._keptPreview(store, kept),
      ],
    ];
  }

  Widget _keptRow(
    ThemeData theme,
    Live2DFileStore store,
    Live2DStoredModel model,
  ) {
    final id = model.id;
    final active = store.activeModelId == id;
    final mapped = store.profile(id) != null;
    final can = widget.enabled && !_busy;
    // A kept preview next to a temporary one would show two previews.
    final canPreview = can && _session == null;
    return Padding(
      key: Key('live2d-kept-$id'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(model.displayName, overflow: TextOverflow.ellipsis),
          Text(
            active
                ? '已启用'
                : mapped
                ? '已保存映射'
                : '未设置映射',
            key: Key('live2d-kept-state-$id'),
            style: theme.textTheme.bodySmall,
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                key: Key('live2d-map-$id'),
                onPressed: canPreview ? () => _map(id) : null,
                child: const Text('设置映射'),
              ),
              if (active)
                TextButton(
                  key: Key('live2d-disable-$id'),
                  onPressed: can ? _disable : null,
                  child: const Text('停用'),
                )
              else
                TextButton(
                  key: Key('live2d-enable-$id'),
                  onPressed: canPreview && mapped ? () => _enable(id) : null,
                  child: const Text('启用'),
                ),
              TextButton(
                key: Key('live2d-delete-$id'),
                onPressed: can ? () => _delete(model) : null,
                child: const Text('删除'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _keptPreview(Live2DFileStore store, Live2DStoredModel model) {
    final id = model.id;
    final controller = _keptReady;
    return [
      const SizedBox(height: 8),
      Text('预览：${model.displayName}', overflow: TextOverflow.ellipsis),
      const SizedBox(height: 4),
      Card(
        key: const Key('live2d-kept-preview'),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 280,
          child: Live2DPreviewView(
            key: ValueKey<String>(id),
            directory: store.modelDirectory(id),
            modelId: id,
            model3File: model.model3,
            kept: true,
            onReady: (controller) => _onKeptReady(id, controller),
          ),
        ),
      ),
      if (_enableWhenReady)
        const Text('预览就绪后启用此形象。', key: Key('live2d-kept-enabling')),
      TextButton(
        key: const Key('live2d-kept-close'),
        onPressed: _busy ? null : () => setState(_closeKept),
        child: const Text('关闭预览'),
      ),
      if (_wizard)
        if (controller != null)
          Live2DMappingWizard(
            key: ObjectKey(controller),
            store: store,
            modelId: id,
            info: _keptInfo,
            infoError: _keptInfoError,
            groups: _groups[id] ?? const <Live2DModelGroup>[],
            setParameter: controller.setParameter,
            clearParameter: controller.clearParameter,
            setExpression: controller.setExpression,
            clearExpression: controller.clearExpression,
            playMotion: controller.playMotion,
            blink: controller.blink,
            speak: controller.speak,
            onClose: () => setState(() => _wizard = false),
            onChanged: () {
              setState(() {});
              widget.onAvatarEnabled?.call();
            },
          )
        else
          const Text('预览就绪后即可设置映射。', key: Key('live2d-wizard-waiting')),
    ];
  }
}
