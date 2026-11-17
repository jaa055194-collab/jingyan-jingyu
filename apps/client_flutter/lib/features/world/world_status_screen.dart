import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../net/host_connection.dart';
import '../../net/world_api.dart';

/// Honest, read-only status of one host world. No 3D rendering, no model bytes,
/// no paths and no secrets are shown; every section is reported independently.
enum WorldReadStatus { present, missing, denied, unknown, unconfigured }

class WorldSection {
  const WorldSection(this.title, this.status, this.lines);

  final String title;
  final WorldReadStatus status;
  final List<String> lines;
}

class WorldStatusSnapshot {
  const WorldStatusSnapshot(this.spaceId, this.sections);

  final String spaceId;
  final List<WorldSection> sections;
}

/// Read-only "世界状态" screen.
///
/// Layout and presence are queried for the space id the developer enters; no
/// default space is invented. Avatars are fetched independently of the space.
/// A failed/malformed section is reported as missing/denied/unknown without
/// leaking transport details and without blocking the other sections.
class WorldStatusScreen extends StatefulWidget {
  const WorldStatusScreen({
    super.key,
    this.initialSpaceId = '',
    this.load,
    this.title = '世界状态',
  });

  final String initialSpaceId;
  final Future<WorldStatusSnapshot> Function(String spaceId)? load;
  final String title;

  /// Sequential GET-only projection. Each section fails independently.
  static Future<WorldStatusSnapshot> loadFrom(
    WorldApi api,
    String spaceId,
  ) async {
    final id = spaceId.trim();
    final sections = <WorldSection>[];
    if (id.isEmpty) {
      sections.add(
        const WorldSection('世界布局', WorldReadStatus.unconfigured, [
          '未指定空间标识；世界布局按空间查询，不做默认推断',
        ]),
      );
      sections.add(
        const WorldSection('在场', WorldReadStatus.unconfigured, [
          '未指定空间标识；不展示任何在场推断',
        ]),
      );
    } else {
      try {
        final layout = await api.layout(id);
        sections.add(
          WorldSection('世界布局', WorldReadStatus.present, [
            '空间：${layout.spaceId} · 版本 ${layout.version}',
            '风格：${layout.style}',
            if (layout.mainColor != null) '主色：${layout.mainColor}',
            '房间 ${layout.rooms.length} 个',
            for (final room in layout.rooms)
              '· ${room.name}（${room.furniture.length} 件家具）',
            '更新：${layout.updatedAt.toIso8601String()}',
          ]),
        );
      } catch (error) {
        sections.add(_errorSection('世界布局', error));
      }
      try {
        final presence = await api.presence(id);
        sections.add(
          WorldSection('在场', WorldReadStatus.present, [
            if (presence.isEmpty) '当前没有在场记录',
            for (final record in presence.take(20))
              '${record.residentId} · ${_motionLabel(record.motion)} · '
                  '(${record.x.toStringAsFixed(1)}, '
                  '${record.y.toStringAsFixed(1)}, '
                  '${record.z.toStringAsFixed(1)})',
            if (presence.length > 20) '…共 ${presence.length} 条',
          ]),
        );
      } catch (error) {
        sections.add(_errorSection('在场', error));
      }
    }
    try {
      final avatars = await api.avatars();
      sections.add(
        WorldSection('形象', WorldReadStatus.present, [
          if (avatars.isEmpty) '当前账号没有已注册形象',
          for (final avatar in avatars.take(20))
            '${avatar.avatarId} · ${avatar.kind} · ${avatar.modelId} · '
                'rev ${avatar.profileRev} · owner ${avatar.ownerId}',
          if (avatars.length > 20) '…共 ${avatars.length} 条',
        ]),
      );
    } catch (error) {
      sections.add(_errorSection('形象', error));
    }
    return WorldStatusSnapshot(id, sections);
  }

  static WorldSection _errorSection(String title, Object error) {
    if (error is HostRequestException) {
      final code = error.failure.code;
      if (code == FailureCode.notFound) {
        return WorldSection(title, WorldReadStatus.missing, ['未找到（可能不存在或不可见）']);
      }
      if (code == FailureCode.forbidden ||
          code == FailureCode.unauthenticated) {
        return WorldSection(title, WorldReadStatus.denied, ['未认证或无权限']);
      }
    }
    return WorldSection(title, WorldReadStatus.unknown, ['读取失败或结果未知；不会自动重试']);
  }

  static String _motionLabel(String motion) => switch (motion) {
    'idle' => '静止',
    'walk' => '行走',
    'sit' => '坐下',
    'wave' => '挥手',
    _ => motion,
  };

  @override
  State<WorldStatusScreen> createState() => _WorldStatusScreenState();
}

class _WorldStatusScreenState extends State<WorldStatusScreen> {
  late final TextEditingController _space;
  WorldStatusSnapshot? _snapshot;
  bool _loading = true;
  bool _unknown = false;

  @override
  void initState() {
    super.initState();
    _space = TextEditingController(text: widget.initialSpaceId);
    _space.addListener(_onSpaceChanged);
    _load();
  }

  void _onSpaceChanged() {
    // Display-only rebuild so the empty/unconfigured hint tracks the field.
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _space.removeListener(_onSpaceChanged);
    _space.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final load = widget.load;
    if (load == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _unknown = true;
      });
      return;
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _unknown = false;
      });
    }
    try {
      final snapshot = await load(_space.text.trim());
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        _unknown = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _snapshot = null;
        _loading = false;
        _unknown = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          '只读世界状态：展示宿主已返回的安全元数据；不做 3D 渲染、不读取模型字节、文件路径或任何密钥。'
          '世界布局与在场按空间查询，需显式填写空间标识；未找到/无权限/未知均如实标注，未知≠错误。',
          key: Key('world-help'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('world-space-id'),
          controller: _space,
          decoration: const InputDecoration(
            labelText: '空间标识（需显式填写）',
            helperText: '留空则不读取世界布局/在场（形象仍按当前账号读取）；不填不做默认推断',
          ),
          onSubmitted: (_) => _load(),
        ),
        if (widget.load != null && !_loading && _space.text.trim().isEmpty)
          const Padding(
            key: Key('world-space-unconfigured'),
            padding: EdgeInsets.only(top: 4),
            child: Text('未填写空间标识：布局/在场为空不读取，形象仍按当前账号读取。未知≠错误，不代表未配置。'),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const Key('world-status-refresh'),
            onPressed: _loading || widget.load == null ? null : _load,
            child: Text(_loading ? '加载中…' : '刷新/加载'),
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_unknown)
          Padding(
            key: const Key('world-status-unknown'),
            padding: const EdgeInsets.only(top: 8),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('状态未知（未知≠错误）：未连接宿主或读取失败；不会自动重试。'),
                SizedBox(height: 4),
                Text('未知不代表已配置，也不代表未配置；这不是错误，也不是权限判定。'),
              ],
            ),
          ),
        if (_snapshot case final snapshot?)
          for (final section in snapshot.sections) _SectionCard(section),
      ],
    ),
  );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard(this.section);

  final WorldSection section;

  static String _label(WorldReadStatus status) => switch (status) {
    WorldReadStatus.present => '已读取',
    WorldReadStatus.missing => '未找到',
    WorldReadStatus.denied => '无权限',
    WorldReadStatus.unknown => '未知',
    WorldReadStatus.unconfigured => '未指定',
  };

  @override
  Widget build(BuildContext context) => Card(
    key: Key('world-section-${section.title}'),
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  section.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(_label(section.status)),
            ],
          ),
          const SizedBox(height: 8),
          for (final line in section.lines) Text(line),
        ],
      ),
    ),
  );
}
