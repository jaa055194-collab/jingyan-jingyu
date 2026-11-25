import 'package:material_ui/material_ui.dart';

import '../../net/creative_api.dart';

/// Read-only presentation of the report carried by the selected list row.
class CreativeReportDetail extends StatelessWidget {
  const CreativeReportDetail({super.key, required this.report});

  final CreativeReport report;

  static const _scopeLabels = {
    'privateChat': '私聊',
    'groupChat': '群聊',
    'moments': '朋友圈',
  };

  String get _generatedAt {
    final iso = report.generatedAt.toUtc().toIso8601String();
    final time = iso.substring(0, iso.length - 1).replaceFirst('T', ' ');
    return '${time.endsWith('.000') ? time.substring(0, time.length - 4) : time} UTC';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final moods = report.moodCurve.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final scopes = report.sourceScopes.map(
      (scope) => _scopeLabels[scope] ?? scope,
    );
    final busiestDay = report.busiestDay;

    Widget section(String label, Widget body) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(label, style: theme.textTheme.titleSmall),
          ),
          const SizedBox(height: 4),
          body,
        ],
      ),
    );

    Widget entries(Iterable<String> values, String emptyLabel) => values.isEmpty
        ? Text(emptyLabel)
        : Wrap(
            spacing: 24,
            runSpacing: 4,
            children: [for (final value in values) Text(value)],
          );

    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 804),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('统计区间：${report.windowStartDay} 至 ${report.windowEndDay}'),
              Text('生成时间：$_generatedAt'),
              const SizedBox(height: 8),
              entries([
                '完成的约定：${report.completedAgreements} 项',
                '打卡天数：${report.checkinDays} 天',
              ], ''),
              section(
                '共同话题',
                entries(
                  report.commonTopics.map(
                    (topic) => '${topic.label} · ${topic.count} 次',
                  ),
                  '暂无共同话题',
                ),
              ),
              section(
                '心情记录（按日）',
                entries(
                  moods.map((entry) => '${entry.key}：${entry.value}'),
                  '暂无心情记录',
                ),
              ),
              if (report.kind == 'annual') ...[
                section(
                  '年度关键词',
                  Text(
                    report.keywords.isEmpty
                        ? '暂无年度关键词'
                        : report.keywords.join('、'),
                  ),
                ),
                section(
                  '年度里程碑',
                  report.milestones.isEmpty
                      ? const Text('暂无年度里程碑')
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final milestone in report.milestones)
                              Text(milestone),
                          ],
                        ),
                ),
                const SizedBox(height: 8),
                Text(
                  '最热闹的一天：${busiestDay == null || busiestDay.trim().isEmpty ? '未记录' : busiestDay}',
                ),
              ],
              section(
                '报告信',
                Text(report.letter.trim().isEmpty ? '未附信件' : report.letter),
              ),
              section(
                '来源范围',
                Text(scopes.isEmpty ? '未记录来源范围' : scopes.join('、')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
