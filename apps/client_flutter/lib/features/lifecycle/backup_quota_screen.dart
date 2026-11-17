import 'package:material_ui/material_ui.dart';

import '../../net/lifecycle_api.dart';

/// Read-only current-account quota/disk and lifecycle object-count view.
///
/// This screen never uploads, cleans, deletes or changes consent. A present
/// configuration is only metadata from the host, not proof a model/worker is
/// available or authorized. When no loader is available (offline/unbound) it
/// reports an honest unknown state instead of inventing values.
class BackupQuotaScreen extends StatefulWidget {
  const BackupQuotaScreen({super.key, this.loadQuota, this.loadSurvey});

  final Future<LifecycleQuotaStatus> Function()? loadQuota;
  final Future<LifecycleDepartureSurvey> Function()? loadSurvey;

  @override
  State<BackupQuotaScreen> createState() => _BackupQuotaScreenState();
}

class _BackupQuotaScreenState extends State<BackupQuotaScreen> {
  LifecycleQuotaStatus? _quota;
  LifecycleDepartureSurvey? _survey;
  bool _loading = true;
  bool _unknown = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final quota = widget.loadQuota;
    final survey = widget.loadSurvey;
    if (quota == null || survey == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _unknown = true;
        });
      }
      return;
    }
    try {
      final q = await quota();
      final s = await survey();
      if (!mounted) return;
      setState(() {
        _quota = q;
        _survey = s;
        _loading = false;
        _unknown = false;
      });
    } catch (_) {
      // Malformed/HTTP/transport failures are not configuration; stay unknown.
      if (!mounted) return;
      setState(() {
        _quota = null;
        _survey = null;
        _loading = false;
        _unknown = true;
      });
    }
  }

  static String _bytes(int value) {
    const kib = 1024, mib = 1024 * 1024, gib = 1024 * 1024 * 1024;
    if (value >= gib) {
      return '${(value / gib).toStringAsFixed(1)} GiB';
    }
    if (value >= mib) {
      return '${(value / mib).toStringAsFixed(1)} MiB';
    }
    if (value >= kib) {
      return '${(value / kib).toStringAsFixed(1)} KiB';
    }
    return '$value B';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('配额与生命周期状态')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('只读：以下为宿主返回的当前账号配额与生命周期对象清点，不代表可用、已授权或已清理；本页不会上传、清理、删除或授权。'),
        const SizedBox(height: 12),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (_unknown)
          Card(
            key: const Key('lifecycle-unknown'),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Text('状态未知：宿主暂不可用，或响应无法验证。不会自动重试或推测配置。'),
            ),
          ),
        if (!_loading && !_unknown && _quota != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('配额与磁盘', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text('已用：${_bytes(_quota!.usedBytes)}'),
                  Text('配额：${_bytes(_quota!.quotaBytes)}'),
                  Text(
                    '磁盘可用：${_bytes(_quota!.diskFreeBytes)} / ${_bytes(_quota!.diskTotalBytes)}',
                  ),
                  const SizedBox(height: 4),
                  const Text('配额与磁盘均为只读计数，不触发清理或上传。'),
                ],
              ),
            ),
          ),
        if (!_loading && !_unknown && _survey != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '生命周期对象清点',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  for (final entry in _survey!.objectCounts.entries)
                    Text('${entry.key}：${entry.value}'),
                  Text('待匿名化动态：${_survey!.momentsToAnonymize}'),
                  Text('对象合计：${_survey!.totalObjects}'),
                  const SizedBox(height: 4),
                  const Text('宿主未提供独立“清理状态”接口；此处为离开/清理前的对象清点，本页不会执行删除。'),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
