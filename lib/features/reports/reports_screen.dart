import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/printing/documents.dart';
import '../../core/printing/print_actions.dart';
import '../../core/providers.dart';
import '../../core/reports/report_excel.dart';
import '../../core/reports/report_service.dart';
import '../../core/reports/report_table.dart';
import '../../core/theme.dart';
import '../../core/widgets/charts.dart';
import '../../core/widgets/date_range_bar.dart';
import '../../core/widgets/list_kit.dart';
import '../../core/widgets/report_view.dart';

IconData _groupIcon(String g) => switch (g) {
      ReportGroup.sales => Icons.point_of_sale_outlined,
      ReportGroup.profit => Icons.trending_up,
      ReportGroup.purchases => Icons.shopping_cart_outlined,
      ReportGroup.stock => Icons.warehouse_outlined,
      ReportGroup.parties => Icons.people_outline,
      _ => Icons.payments_outlined,
    };

/// Admin only (the section is). The report catalogue on the side, grouped
/// and searchable; the chosen report with its filters, key figures, a chart,
/// the table with totals, Excel export and printing.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  ReportKind _kind = ReportKind.dailySales;
  DayRange _range = DayRange.thisMonth();
  int? _categoryId;
  late Future<ReportTable> _table = _build();
  List<Category> _categories = const [];
  String _find = '';
  bool _showChart = false;

  @override
  void initState() {
    super.initState();
    ref.read(catalogServiceProvider).watchCategories().first.then((c) {
      if (mounted) setState(() => _categories = c);
    });
  }

  Future<ReportTable> _build() => ref.read(reportServiceProvider).build(
        _kind,
        from: _kind.dated ? _range.from : null,
        to: _kind.dated ? _range.to : null,
        categoryId: _kind.byCategory ? _categoryId : null,
      );

  void _refresh() => setState(() {
        _table = _build();
      });

  Future<void> _export(ReportTable table) async {
    final company = await ref.read(settingsServiceProvider).company();
    if (!mounted) return;
    final bytes = reportToExcel(
      table,
      from: _kind.dated ? _range.from : null,
      to: _kind.dated ? _range.to : null,
      companyName: company.name,
    );
    await saveExcelFile(context, bytes, table.title);
  }

  bool _found(ReportKind k) {
    final q = _find.trim();
    return q.isEmpty || k.title.contains(q) || k.description.contains(q);
  }

  Widget _catalogue() {
    return Container(
      width: 270,
      color: AppColors.surface,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 18, 16, 8),
          child: Text(Strings.reports, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: TextField(
            onChanged: (v) => setState(() => _find = v),
            decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search), hintText: 'ابحث عن تقرير'),
          ),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.only(bottom: 16), children: [
            for (final g in ReportGroup.all) ...[
              if (ReportKind.values.any((k) => k.group == g && _found(k)))
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(children: [
                    Icon(_groupIcon(g), size: 16, color: AppColors.brand),
                    const SizedBox(width: 6),
                    Text(g, style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.brand, fontSize: 13)),
                  ]),
                ),
              for (final k in ReportKind.values)
                if (k.group == g && _found(k))
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                    child: Material(
                      color: k == _kind ? AppColors.infoBg : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () {
                          _kind = k;
                          _refresh();
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(k.title,
                                style: TextStyle(
                                    fontWeight: k == _kind ? FontWeight.w800 : FontWeight.w600,
                                    color: k == _kind ? AppColors.info : AppColors.ink)),
                            Text(k.description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11.5, color: AppColors.muted)),
                          ]),
                        ),
                      ),
                    ),
                  ),
            ],
          ]),
        ),
      ]),
    );
  }

  /// The added-up columns as figures on top (the profit report shows its
  /// key lines instead).
  List<SummaryItem> _figures(ReportTable t) {
    if (_kind == ReportKind.profit) {
      return [
        for (final r in t.rows)
          if (const ['صافي المبيعات', 'مجمل الربح', 'المصروفات', 'صافي الربح'].contains(r[0]))
            SummaryItem(r[0] as String, formatMoney(r[1] as int),
                icon: Icons.insights_outlined,
                tone: r[0] == 'صافي الربح' ? ((r[1] as int) < 0 ? AppColors.bad : AppColors.good) : null),
      ];
    }
    final out = <SummaryItem>[SummaryItem('عدد السطور', '${t.rows.length}', icon: Icons.format_list_numbered)];
    final totals = t.totals;
    for (var i = 0; i < t.columns.length && out.length < 5; i++) {
      final c = t.columns[i];
      if (!c.sum) continue;
      final v = totals[i] as int;
      out.add(SummaryItem(
        c.title,
        c.type == ColumnType.money ? formatMoney(v) : '$v',
        icon: c.type == ColumnType.money ? Icons.payments_outlined : Icons.tag,
        tone: c.title.contains('ربح') ? (v < 0 ? AppColors.bad : AppColors.good) : null,
      ));
    }
    return out;
  }

  int _col(ReportTable t, List<String> titles, {ColumnType? type}) {
    for (final title in titles) {
      final i = t.columns.indexWhere((c) => c.title == title);
      if (i >= 0) return i;
    }
    return type == null ? -1 : t.columns.indexWhere((c) => c.type == type);
  }

  Widget? _chart(ReportTable t) {
    if (_kind.chart == ReportChart.none || t.rows.isEmpty) return null;
    if (_kind.chart == ReportChart.trend) {
      final rows = t.rows.length > 31 ? t.rows.sublist(t.rows.length - 31) : t.rows;
      String label(Object? v) => v is DateTime ? '${v.day}/${v.month}' : '$v';
      final net = _col(t, ['الصافي'], type: ColumnType.money);
      final profit = _col(t, ['مجمل الربح']);
      if (net < 0) return null;
      return PanelCard(
        title: 'الاتجاه',
        child: BarChart(
          height: 180,
          labels: [for (final r in rows) label(r[0])],
          series: [
            ChartSeries(t.columns[net].title, AppColors.brand, [for (final r in rows) r[net] as int]),
            if (profit >= 0) ChartSeries('مجمل الربح', AppColors.good, [for (final r in rows) r[profit] as int]),
          ],
        ),
      );
    }
    final labelCol = _col(t, ['الصنف', 'العميل', 'المورد', 'التصنيف', 'الماركة', 'المستخدم', 'المشروع', 'البند'],
        type: ColumnType.text);
    final valueCol = _col(t, ['الصافي', 'صافي المبيعات', 'القيمة بالتكلفة', 'الرصيد', 'مفوتر', 'القيمة', 'المبلغ'],
        type: ColumnType.money);
    if (labelCol < 0 || valueCol < 0) return null;
    return PanelCard(
      title: 'الأعلى حسب ${t.columns[valueCol].title}',
      child: RankBars(max: 6, rows: [for (final r in t.rows) ('${r[labelCol] ?? ''}', (r[valueCol] as int?) ?? 0)]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _catalogue(),
      const VerticalDivider(width: 1),
      Expanded(
        child: FutureBuilder<ReportTable>(
          future: _table,
          builder: (context, snap) {
            final t = snap.connectionState == ConnectionState.done ? snap.data : null;
            final chart = t == null || !_showChart ? null : _chart(t);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 4),
                child: Row(children: [
                  Container(
                    width: 4,
                    height: 26,
                    decoration: BoxDecoration(color: AppColors.brand, borderRadius: BorderRadius.circular(2)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_kind.title, style: Theme.of(context).textTheme.headlineSmall),
                      Text(_kind.description, style: const TextStyle(color: AppColors.muted)),
                    ]),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
                child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  if (_kind.dated)
                    DateRangeBar(
                      value: _range,
                      onChanged: (r) {
                        _range = r;
                        _refresh();
                      },
                    ),
                  if (_kind.byCategory)
                    SizedBox(
                      width: 220,
                      child: DropdownButtonFormField<int?>(
                        key: ValueKey('cat-${_categories.length}'),
                        initialValue: _categoryId,
                        isDense: true,
                        decoration: const InputDecoration(labelText: Strings.category, isDense: true),
                        items: [
                          const DropdownMenuItem(value: null, child: Text(Strings.all)),
                          for (final c in _categories) DropdownMenuItem(value: c.id, child: Text(c.nameAr)),
                        ],
                        onChanged: (v) {
                          _categoryId = v;
                          _refresh();
                        },
                      ),
                    ),
                  if (_kind.chart != ReportChart.none)
                    SegmentedButton<bool>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(visualDensity: VisualDensity.compact),
                      segments: const [
                        ButtonSegment(value: false, icon: Icon(Icons.table_rows_outlined), label: Text('جدول')),
                        ButtonSegment(value: true, icon: Icon(Icons.bar_chart), label: Text('رسم')),
                      ],
                      selected: {_showChart},
                      onSelectionChanged: (s) => setState(() => _showChart = s.first),
                    ),
                  IconButton(tooltip: Strings.refresh, onPressed: _refresh, icon: const Icon(Icons.refresh)),
                  FilledButton.tonalIcon(
                    onPressed: t == null ? null : () => _export(t),
                    icon: const Icon(Icons.table_view),
                    label: const Text(Strings.exportExcel),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: t == null
                        ? null
                        : () => printDocument(
                              context,
                              ref,
                              name: t.title,
                              build: (company, fonts) => tablePdf(
                                t,
                                company,
                                fonts,
                                from: _kind.dated ? _range.from : null,
                                to: _kind.dated ? _range.to : null,
                              ),
                            ),
                    icon: const Icon(Icons.print_outlined),
                    label: const Text(Strings.print),
                  ),
                ]),
              ),
              const SizedBox(height: 10),
              if (snap.hasError)
                Expanded(child: Center(child: SelectableText('${snap.error}')))
              else if (t == null)
                const Expanded(child: Center(child: CircularProgressIndicator()))
              else ...[
                _Figures(_figures(t)),
                Expanded(
                  child: chart != null
                      ? SingleChildScrollView(padding: const EdgeInsets.fromLTRB(24, 0, 24, 16), child: chart)
                      : ReportView(table: t),
                ),
              ],
            ]);
          },
        ),
      ),
    ]);
  }
}

/// The report's key figures in one compact line.
class _Figures extends StatelessWidget {
  const _Figures(this.items);

  final List<SummaryItem> items;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final i in items)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (i.icon != null) ...[Icon(i.icon, size: 16, color: i.tone ?? AppColors.brand), const SizedBox(width: 6)],
              Text('${i.label}: ', style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
              Text(i.value, style: TextStyle(fontWeight: FontWeight.w800, color: i.tone ?? AppColors.ink)),
            ]),
          ),
      ]),
    );
  }
}
