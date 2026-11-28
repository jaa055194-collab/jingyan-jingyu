import 'package:material_ui/material_ui.dart';

import '../../net/creative_api.dart';
import '../../ui/ui.dart';

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
    final palette = JyPalette.of(context);
    final text = Theme.of(context).textTheme;
    final moods = report.moodCurve.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final scopes = report.sourceScopes
        .map((scope) => _scopeLabels[scope] ?? scope)
        .toList();
    final busiestDay = report.busiestDay;

    Widget section(String label, Widget body) => Padding(
      padding: const EdgeInsets.only(top: JySpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              label,
              style: text.labelMedium?.copyWith(
                color: palette.text2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: JySpace.xs),
          body,
        ],
      ),
    );

    Widget pill(String value) => Container(
      decoration: ShapeDecoration(
        color: palette.raised,
        shape: JyShapes.rounded(JyRadius.pill),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: JySpace.md,
        vertical: JySpace.xs,
      ),
      child: Text(value, style: text.bodySmall?.copyWith(color: palette.text2)),
    );

    Widget pills(Iterable<String> values, String emptyLabel) => values.isEmpty
        ? Text(
            emptyLabel,
            style: text.bodyMedium?.copyWith(color: palette.text2),
          )
        : Wrap(
            spacing: JySpace.sm,
            runSpacing: JySpace.sm,
            children: [for (final value in values) pill(value)],
          );

    Widget miniSlab(String value) => Container(
      decoration: ShapeDecoration(
        color: palette.raised,
        shape: JyShapes.rounded(JyRadius.md),
      ),
      padding: const EdgeInsets.all(JySpace.md),
      child: Text(
        value,
        style: text.bodyMedium?.copyWith(color: palette.text1),
      ),
    );

    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 804),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
            JySpace.lg,
            0,
            JySpace.lg,
            JySpace.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '统计区间：${report.windowStartDay} 至 ${report.windowEndDay}',
                style: text.bodySmall?.copyWith(
                  color: palette.text3,
                  fontFeatures: JyTypography.tabularFigures,
                ),
              ),
              Text(
                '生成时间：$_generatedAt',
                style: text.bodySmall?.copyWith(
                  color: palette.text3,
                  fontFeatures: JyTypography.tabularFigures,
                ),
              ),
              const SizedBox(height: JySpace.sm),
              Wrap(
                spacing: JySpace.sm,
                runSpacing: JySpace.sm,
                children: [
                  miniSlab('完成的约定：${report.completedAgreements} 项'),
                  miniSlab('打卡天数：${report.checkinDays} 天'),
                ],
              ),
              section(
                '共同话题',
                pills(
                  report.commonTopics.map(
                    (topic) => '${topic.label} · ${topic.count} 次',
                  ),
                  '暂无共同话题',
                ),
              ),
              section(
                '心情记录（按日）',
                pills(
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
                    style: text.bodyMedium?.copyWith(color: palette.text1),
                  ),
                ),
                section(
                  '年度里程碑',
                  report.milestones.isEmpty
                      ? Text(
                          '暂无年度里程碑',
                          style: text.bodyMedium?.copyWith(
                            color: palette.text2,
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final milestone in report.milestones)
                              Text(
                                milestone,
                                style: text.bodyMedium?.copyWith(
                                  color: palette.text1,
                                ),
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: JySpace.sm),
                Text(
                  '最热闹的一天：${busiestDay == null || busiestDay.trim().isEmpty ? '未记录' : busiestDay}',
                  style: text.bodyMedium?.copyWith(color: palette.text1),
                ),
              ],
              section(
                '报告信',
                Container(
                  decoration: ShapeDecoration(
                    color: palette.raised,
                    shape: JyShapes.rounded(JyRadius.md),
                  ),
                  padding: const EdgeInsets.all(JySpace.md),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: ExcludeSemantics(
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: palette.ember,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: JySpace.sm),
                      Expanded(
                        child: Text(
                          report.letter.trim().isEmpty ? '未附信件' : report.letter,
                          style: text.bodyMedium?.copyWith(
                            color: palette.text1,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              section(
                '来源范围',
                Text(
                  scopes.isEmpty ? '未记录来源范围' : scopes.join('、'),
                  style: text.bodySmall?.copyWith(color: palette.text3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
