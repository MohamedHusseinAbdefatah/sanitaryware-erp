import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/reports/report_table.dart';
import '../../core/services/ledger_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/charts.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/date_range_bar.dart';
import '../../core/widgets/feedback.dart';
import '../../core/widgets/list_kit.dart';
import 'accounting_kit.dart';

void _openAccount(BuildContext context, Account a) => context.go('/accounting/accounts/${a.id}');

Widget _toolbar(List<Widget> children) => Padding(
  padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
  child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: children),
);

Widget _excelButton(VoidCallback onPressed) =>
    OutlinedButton.icon(onPressed: onPressed, icon: const Icon(Icons.table_view), label: const Text('تصدير Excel'));

/// The same number of days just before [r].
DayRange previousOf(DayRange r) {
  if (r.from == null || r.to == null) return const DayRange(null, null);
  final days = r.to!.difference(r.from!).inDays + 1;
  final end = r.from!.subtract(const Duration(days: 1));
  return DayRange(end.subtract(Duration(days: days - 1)), end);
}

// ------------------------------------------------------------ trial balance

class TrialBalanceTab extends ConsumerStatefulWidget {
  const TrialBalanceTab({super.key});

  @override
  ConsumerState<TrialBalanceTab> createState() => _TrialBalanceTabState();
}

class _TrialBalanceTabState extends ConsumerState<TrialBalanceTab> {
  DayRange _range = DayRange.thisYear();

  @override
  Widget build(BuildContext context) {
    return LedgerBuilder<List<AccountBalance>>(
      reloadKey: _range,
      load: (l) => l.balances(from: _range.from, to: _range.to),
      builder: (context, all) {
        final rows = all.where((r) => !r.account.isGroup && (r.opening != 0 || r.debit != 0 || r.credit != 0)).toList();
        int pos(int v) => v > 0 ? v : 0;
        final od = rows.fold(0, (s, r) => s + pos(r.opening));
        final oc = rows.fold(0, (s, r) => s + pos(-r.opening));
        final d = rows.fold(0, (s, r) => s + r.debit);
        final c = rows.fold(0, (s, r) => s + r.credit);
        final cd = rows.fold(0, (s, r) => s + pos(r.closing));
        final cc = rows.fold(0, (s, r) => s + pos(-r.closing));
        final ok = od == oc && d == c && cd == cc;
        ReportTable table() => ReportTable(
          title: 'ميزان المراجعة',
          columns: const [
            ReportColumn('الكود', ColumnType.text),
            ReportColumn('الحساب', ColumnType.text),
            ReportColumn('أول المدة مدين', ColumnType.money, sum: true),
            ReportColumn('أول المدة دائن', ColumnType.money, sum: true),
            ReportColumn('حركة مدين', ColumnType.money, sum: true),
            ReportColumn('حركة دائن', ColumnType.money, sum: true),
            ReportColumn('رصيد مدين', ColumnType.money, sum: true),
            ReportColumn('رصيد دائن', ColumnType.money, sum: true),
          ],
          rows: [
            for (final r in rows)
              [
                r.account.code,
                r.account.nameAr,
                pos(r.opening),
                pos(-r.opening),
                r.debit,
                r.credit,
                pos(r.closing),
                pos(-r.closing),
              ],
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _toolbar([
              DateRangeBar(value: _range, onChanged: (r) => setState(() => _range = r)),
              ok ? StatusPill.good('الميزان متوازن') : StatusPill.bad('الميزان غير متوازن'),
              _excelButton(() => exportTable(context, ref, table(), from: _range.from, to: _range.to)),
            ]),
            SummaryStrip(
              items: [
                SummaryItem('حركة مدين', formatMoney(d), icon: Icons.add),
                SummaryItem('حركة دائن', formatMoney(c), icon: Icons.remove),
                SummaryItem('أرصدة مدينة', formatMoney(cd), icon: Icons.call_received),
                SummaryItem('أرصدة دائنة', formatMoney(cc), icon: Icons.call_made),
              ],
            ),
            Expanded(
              child: DataList<AccountBalance>(
                rows: rows,
                emptyText: 'لا حركة في هذه الفترة',
                onTap: (r) => _openAccount(context, r.account),
                columns: [
                  DataListColumn('الكود', width: 80, (r) => Text(r.account.code)),
                  DataListColumn('الحساب', flex: 3, (r) => Text(r.account.nameAr)),
                  DataListColumn('أول المدة', numeric: true, (r) => Text(formatMoney(r.opening))),
                  DataListColumn('مدين', numeric: true, (r) => Text(formatMoney(r.debit))),
                  DataListColumn('دائن', numeric: true, (r) => Text(formatMoney(r.credit))),
                  DataListColumn(
                    'رصيد مدين',
                    numeric: true,
                    (r) => Text(
                      r.closing > 0 ? formatMoney(r.closing) : '',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  DataListColumn(
                    'رصيد دائن',
                    numeric: true,
                    (r) => Text(
                      r.closing < 0 ? formatMoney(-r.closing) : '',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(color: AppColors.canvas, borderRadius: BorderRadius.circular(10)),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('الإجمالي', style: TextStyle(fontWeight: FontWeight.w900)),
                  ),
                  Text(
                    'مدين ${formatMoney(cd)}    دائن ${formatMoney(cc)}',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------- profit and loss

class ProfitLossTab extends ConsumerStatefulWidget {
  const ProfitLossTab({super.key});

  @override
  ConsumerState<ProfitLossTab> createState() => _ProfitLossTabState();
}

class _ProfitLossTabState extends ConsumerState<ProfitLossTab> {
  DayRange _range = DayRange.thisMonth();
  bool _compare = true;

  @override
  Widget build(BuildContext context) {
    final prev = previousOf(_range);
    final canCompare = _compare && prev.from != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar([
          DateRangeBar(value: _range, onChanged: (r) => setState(() => _range = r)),
          FilterChip(
            label: const Text('مقارنة بالفترة السابقة'),
            selected: _compare,
            onSelected: (v) => setState(() => _compare = v),
          ),
        ]),
        Expanded(
          child: LedgerBuilder<(ProfitAndLoss, ProfitAndLoss?)>(
            reloadKey: (_range, canCompare),
            load: (l) async => (
              await l.profitAndLoss(from: _range.from, to: _range.to),
              canCompare ? await l.profitAndLoss(from: prev.from, to: prev.to) : null,
            ),
            builder: (context, data) {
              final (p, b) = data;
              int? cmp(int Function(ProfitAndLoss) f) => b == null ? null : f(b);
              int? rowCmp(StatementSection Function(ProfitAndLoss) s, Account a) =>
                  b == null ? null : s(b).rows.where((r) => r.$1.id == a.id).fold<int>(0, (x, r) => x + r.$2);
              List<Widget> section(StatementSection Function(ProfitAndLoss) s, {bool minus = false}) => [
                for (final (a, v) in s(p).rows)
                  StatementLine(
                    a.nameAr,
                    minus ? -v : v,
                    code: a.code,
                    level: 1,
                    compare: b == null ? null : (minus ? -rowCmp(s, a)! : rowCmp(s, a)),
                    onTap: () => _openAccount(context, a),
                  ),
              ];
              final table = ReportTable(
                title: 'قائمة الدخل',
                columns: const [ReportColumn('البند', ColumnType.text), ReportColumn('المبلغ', ColumnType.money)],
                rows: [
                  ['المبيعات', p.sales.total],
                  ['مرتجعات المبيعات', -p.returns.total],
                  ['صافي المبيعات', p.netSales],
                  ['تكلفة المبيعات', -p.cost.total],
                  ['مجمل الربح', p.grossProfit],
                  for (final (a, v) in p.operating.rows) [a.nameAr, -v],
                  ['ربح التشغيل', p.operatingProfit],
                  ['إيرادات أخرى', p.otherIncome.total],
                  ['مصروفات أخرى', -p.otherExpense.total],
                  ['صافي الربح', p.netProfit],
                ],
              );
              return ReportPage(
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _Kpi('صافي المبيعات', p.netSales, cmp((x) => x.netSales)),
                      _Kpi(
                        'مجمل الربح',
                        p.grossProfit,
                        cmp((x) => x.grossProfit),
                        hint: 'هامش ${percentBp(p.grossMarginBp)}',
                      ),
                      _Kpi(
                        'المصروفات التشغيلية',
                        p.operating.total,
                        cmp((x) => x.operating.total),
                        lowerIsBetter: true,
                      ),
                      _Kpi(
                        'صافي الربح',
                        p.netProfit,
                        cmp((x) => x.netProfit),
                        hint: 'هامش ${percentBp(p.netMarginBp)}',
                      ),
                    ],
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: _excelButton(() => exportTable(context, ref, table, from: _range.from, to: _range.to)),
                  ),
                  StatementCard(
                    children: [
                      StatementHeader(current: _range.label, compare: b == null ? null : prev.label),
                      StatementLine('المبيعات', p.sales.total, compare: cmp((x) => x.sales.total), strong: true),
                      if (p.returns.total != 0)
                        StatementLine(
                          'ناقص: مرتجعات المبيعات',
                          -p.returns.total,
                          compare: cmp((x) => -x.returns.total),
                          level: 1,
                        ),
                      StatementLine('صافي المبيعات', p.netSales, compare: cmp((x) => x.netSales), total: true),
                      StatementLine('تكلفة المبيعات', -p.cost.total, compare: cmp((x) => -x.cost.total), strong: true),
                      ...section((x) => x.cost, minus: true),
                      StatementLine(
                        'مجمل الربح',
                        p.grossProfit,
                        compare: cmp((x) => x.grossProfit),
                        total: true,
                        hint: percentBp(p.grossMarginBp),
                      ),
                      StatementLine(
                        'المصروفات التشغيلية',
                        -p.operating.total,
                        compare: cmp((x) => -x.operating.total),
                        strong: true,
                      ),
                      ...section((x) => x.operating, minus: true),
                      StatementLine(
                        'ربح التشغيل',
                        p.operatingProfit,
                        compare: cmp((x) => x.operatingProfit),
                        total: true,
                      ),
                      if (p.otherIncome.rows.isNotEmpty || (b?.otherIncome.rows.isNotEmpty ?? false)) ...[
                        StatementLine(
                          'إيرادات أخرى',
                          p.otherIncome.total,
                          compare: cmp((x) => x.otherIncome.total),
                          strong: true,
                        ),
                        ...section((x) => x.otherIncome),
                      ],
                      if (p.otherExpense.rows.isNotEmpty || (b?.otherExpense.rows.isNotEmpty ?? false)) ...[
                        StatementLine(
                          'مصروفات أخرى',
                          -p.otherExpense.total,
                          compare: cmp((x) => -x.otherExpense.total),
                          strong: true,
                        ),
                        ...section((x) => x.otherExpense, minus: true),
                      ],
                      StatementLine(
                        'صافي الربح',
                        p.netProfit,
                        compare: cmp((x) => x.netProfit),
                        total: true,
                        hint: percentBp(p.netMarginBp),
                      ),
                    ],
                  ),
                  const Text(
                    'المبيعات بدون ضريبة القيمة المضافة حين تكون الضريبة مؤكدة. التكلفة هي تكلفة الوارد أولاً يصرف أولاً الفعلية.',
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, this.before, {this.hint, this.lowerIsBetter = false});

  final String label;
  final int value;
  final int? before;
  final String? hint;
  final bool lowerIsBetter;

  @override
  Widget build(BuildContext context) {
    final change = before == null || before == 0 ? null : ((value - before!) * 100 / before!.abs());
    final good = change == null ? null : (lowerIsBetter ? change <= 0 : change >= 0);
    return Container(
      width: 225,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
          const SizedBox(height: 4),
          Text(
            formatMoney(value),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: value < 0 ? AppColors.bad : AppColors.ink,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (change != null)
                Text(
                  '${change >= 0 ? '▲' : '▼'} ${change.abs().toStringAsFixed(1)}%  ',
                  style: TextStyle(
                    color: good! ? AppColors.good : AppColors.bad,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              if (hint != null) Text(hint!, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ balance sheet

class BalanceSheetTab extends ConsumerStatefulWidget {
  const BalanceSheetTab({super.key});

  @override
  ConsumerState<BalanceSheetTab> createState() => _BalanceSheetTabState();
}

class _BalanceSheetTabState extends ConsumerState<BalanceSheetTab> {
  DateTime _asOf = DateTime.now();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar([
          OutlinedButton.icon(
            onPressed: () async {
              final d = await showDatePicker(
                context: context,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
                initialDate: _asOf,
              );
              if (d != null) setState(() => _asOf = d);
            },
            icon: const Icon(Icons.event),
            label: Text('في ${formatDate(_asOf)}'),
          ),
        ]),
        Expanded(
          child: LedgerBuilder<BalanceSheet>(
            reloadKey: _asOf,
            load: (l) => l.balanceSheet(asOf: _asOf),
            builder: (context, bs) {
              List<Widget> rows(StatementSection s) => [
                for (final (a, v) in s.rows)
                  StatementLine(a.nameAr, v, code: a.code, level: 1, onTap: () => _openAccount(context, a)),
              ];
              final table = ReportTable(
                title: 'الميزانية العمومية',
                subtitle: 'في ${formatDate(_asOf)}',
                columns: const [ReportColumn('البند', ColumnType.text), ReportColumn('المبلغ', ColumnType.money)],
                rows: [
                  for (final s in [bs.currentAssets, bs.fixedAssets]) ...[
                    for (final (a, v) in s.rows) [a.nameAr, v],
                  ],
                  ['إجمالي الأصول', bs.assets],
                  for (final s in [bs.currentLiabilities, bs.longLiabilities]) ...[
                    for (final (a, v) in s.rows) [a.nameAr, v],
                  ],
                  ['إجمالي الالتزامات', bs.liabilities],
                  for (final (a, v) in bs.equity.rows) [a.nameAr, v],
                  ['أرباح الفترة (لم تُرحّل)', bs.profitToDate],
                  ['إجمالي حقوق الملكية', bs.equityTotal],
                ],
              );
              return ReportPage(
                maxWidth: 1200,
                children: [
                  Row(
                    children: [
                      bs.balances
                          ? StatusPill.good('الأصول = الالتزامات + حقوق الملكية')
                          : StatusPill.bad(
                              'غير متوازنة: فرق ${formatMoney(bs.assets - bs.liabilities - bs.equityTotal)}',
                            ),
                      const Spacer(),
                      _excelButton(() => exportTable(context, ref, table)),
                    ],
                  ),
                  LayoutBuilder(
                    builder: (context, box) {
                      final assets = StatementCard(
                        children: [
                          const StatementHeader(current: 'المبلغ'),
                          StatementLine('الأصول المتداولة', null, strong: true),
                          ...rows(bs.currentAssets),
                          StatementLine('إجمالي الأصول المتداولة', bs.currentAssets.total, strong: true),
                          if (bs.fixedAssets.rows.isNotEmpty) ...[
                            StatementLine('الأصول الثابتة', null, strong: true),
                            ...rows(bs.fixedAssets),
                            StatementLine('صافي الأصول الثابتة', bs.fixedAssets.total, strong: true),
                          ],
                          StatementLine('إجمالي الأصول', bs.assets, total: true),
                        ],
                      );
                      final other = StatementCard(
                        children: [
                          const StatementHeader(current: 'المبلغ'),
                          StatementLine('الالتزامات المتداولة', null, strong: true),
                          ...rows(bs.currentLiabilities),
                          if (bs.longLiabilities.rows.isNotEmpty) ...[
                            StatementLine('التزامات طويلة الأجل', null, strong: true),
                            ...rows(bs.longLiabilities),
                          ],
                          StatementLine('إجمالي الالتزامات', bs.liabilities, strong: true),
                          StatementLine('حقوق الملكية', null, strong: true),
                          ...rows(bs.equity),
                          StatementLine('أرباح الفترة (لم تُرحّل)', bs.profitToDate, level: 1),
                          StatementLine('إجمالي حقوق الملكية', bs.equityTotal, strong: true),
                          StatementLine(
                            'إجمالي الالتزامات وحقوق الملكية',
                            bs.liabilities + bs.equityTotal,
                            total: true,
                          ),
                        ],
                      );
                      if (box.maxWidth < 900) return Column(children: [assets, const SizedBox(height: 16), other]);
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: assets),
                          const SizedBox(width: 16),
                          Expanded(child: other),
                        ],
                      );
                    },
                  ),
                  PanelCard(
                    title: 'مؤشرات',
                    child: Wrap(
                      spacing: 24,
                      runSpacing: 8,
                      children: [
                        _ratio(
                          'نسبة التداول',
                          bs.currentLiabilities.total == 0
                              ? null
                              : bs.currentAssets.total / bs.currentLiabilities.total,
                          'الأصول المتداولة ÷ الالتزامات المتداولة (الأفضل فوق 1.5)',
                        ),
                        _ratio(
                          'رأس المال العامل',
                          null,
                          formatMoney(bs.currentAssets.total - bs.currentLiabilities.total),
                        ),
                        _ratio(
                          'نسبة الديون',
                          bs.assets == 0 ? null : bs.liabilities / bs.assets,
                          'الالتزامات ÷ الأصول',
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _ratio(String label, double? v, String hint) => SizedBox(
    width: 280,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
        Text(
          v == null ? hint : v.toStringAsFixed(2),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
        if (v != null) Text(hint, style: const TextStyle(color: AppColors.muted, fontSize: 11)),
      ],
    ),
  );
}

// ---------------------------------------------------------------- cash flow

class CashFlowTab extends ConsumerStatefulWidget {
  const CashFlowTab({super.key});

  @override
  ConsumerState<CashFlowTab> createState() => _CashFlowTabState();
}

class _CashFlowTabState extends ConsumerState<CashFlowTab> {
  DayRange _range = DayRange.thisMonth();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar([DateRangeBar(value: _range, allowAll: false, onChanged: (r) => setState(() => _range = r))]),
        Expanded(
          child: LedgerBuilder<CashFlow>(
            reloadKey: _range,
            load: (l) => l.cashFlow(from: _range.from ?? DateTime(2000), to: _range.to ?? DateTime.now()),
            builder: (context, cf) {
              List<Widget> part(String title, List<(String, int)> rows, int total) => [
                StatementLine(title, null, strong: true),
                for (final (label, v) in rows) StatementLine(label, v, level: 1),
                if (rows.isEmpty) const StatementLine('لا حركة', 0, level: 1),
                StatementLine('صافي $title', total, strong: true),
              ];
              return ReportPage(
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _Kpi('النقدية أول الفترة', cf.opening, null),
                      _Kpi('صافي التدفق', cf.net, null),
                      _Kpi('النقدية آخر الفترة', cf.closing, null),
                    ],
                  ),
                  StatementCard(
                    children: [
                      const StatementHeader(current: 'المبلغ'),
                      StatementLine('النقدية والبنك والشيكات أول الفترة', cf.opening, strong: true),
                      ...part('التدفقات من التشغيل', cf.operating, cf.operatingTotal),
                      ...part('التدفقات من الاستثمار', cf.investing, cf.investingTotal),
                      ...part('التدفقات من التمويل', cf.financing, cf.financingTotal),
                      StatementLine('صافي التغير في النقدية', cf.net, total: true),
                      StatementLine('النقدية آخر الفترة', cf.closing, total: true),
                    ],
                  ),
                  const Text(
                    'تشمل النقدية: الخزنة والبنك والشيكات المحتسبة. الاستثمار: شراء وبيع الأصول الثابتة. التمويل: رأس المال والمسحوبات والقروض.',
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------- VAT

class VatTab extends ConsumerStatefulWidget {
  const VatTab({super.key});

  @override
  ConsumerState<VatTab> createState() => _VatTabState();
}

class _VatTabState extends ConsumerState<VatTab> {
  DayRange _range = DayRange.thisMonth();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar([DateRangeBar(value: _range, allowAll: false, onChanged: (r) => setState(() => _range = r))]),
        Expanded(
          child: LedgerBuilder<VatReport>(
            reloadKey: _range,
            load: (l) => l.vat(from: _range.from ?? DateTime(2000), to: _range.to ?? DateTime.now()),
            builder: (context, v) => ReportPage(
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _Kpi('ضريبة المخرجات (المبيعات)', v.outputVat, null),
                    _Kpi('ضريبة المدخلات (المشتريات)', v.inputVat, null),
                    _Kpi(v.payable >= 0 ? 'المستحق للمصلحة' : 'رصيد دائن لنا', v.payable.abs(), null),
                  ],
                ),
                StatementCard(
                  children: [
                    const StatementHeader(current: 'المبلغ'),
                    StatementLine('مبيعات خاضعة (بدون الضريبة)', v.salesBase),
                    StatementLine('ضريبة المخرجات', v.outputVat, strong: true),
                    StatementLine('ضريبة المدخلات القابلة للخصم', -v.inputVat),
                    StatementLine('صافي الضريبة المستحقة', v.payable, total: true),
                    StatementLine(
                      'مبيعات لم يُحسب عليها ضريبة',
                      v.unverifiedSales,
                      hint: 'أصناف حالة ضريبتها غير مؤكدة أو غير شاملة',
                    ),
                  ],
                ),
                const Text(
                  'تُحسب الضريبة فقط على الأصناف التي قائمة سعرها "شامل الضريبة" ونسبتها معروفة؛ لا يُفترض شيء غير ذلك. '
                  'ضريبة المدخلات تُسجل بقيد يدوي على حساب "ضريبة القيمة المضافة - مدخلات" من فواتير الموردين الضريبية.',
                  style: TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------------- aging

class AgingTab extends ConsumerStatefulWidget {
  const AgingTab({super.key});

  @override
  ConsumerState<AgingTab> createState() => _AgingTabState();
}

class _AgingTabState extends ConsumerState<AgingTab> {
  bool _customers = true;

  static const _buckets = ['غير مستحق', '1-30 يوم', '31-60 يوم', '61-90 يوم', 'أكثر من 90'];
  static const _colors = [AppColors.good, AppColors.info, AppColors.warn, Color(0xFFD9822B), AppColors.bad];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar([
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('العملاء'), icon: Icon(Icons.people_outline)),
              ButtonSegment(value: false, label: Text('الموردون'), icon: Icon(Icons.local_shipping_outlined)),
            ],
            selected: {_customers},
            onSelectionChanged: (s) => setState(() => _customers = s.first),
          ),
        ]),
        Expanded(
          child: LedgerBuilder<List<AgingRow>>(
            reloadKey: _customers,
            load: (l) => l.aging(customers: _customers),
            builder: (context, rows) {
              final totals = List<int>.generate(5, (i) => rows.fold(0, (s, r) => s + r.buckets[i]));
              final all = totals.fold(0, (s, v) => s + v);
              final table = ReportTable(
                title: _customers ? 'أعمار ديون العملاء' : 'أعمار مستحقات الموردين',
                columns: [
                  const ReportColumn('الاسم', ColumnType.text),
                  for (final b in _buckets) ReportColumn(b, ColumnType.money, sum: true),
                  const ReportColumn('الإجمالي', ColumnType.money, sum: true),
                ],
                rows: [
                  for (final r in rows) [r.name, ...r.buckets, r.total],
                ],
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                    child: PanelCard(
                      title: '${_customers ? 'مستحق لنا' : 'مستحق علينا'}: ${formatMoney(all)}',
                      action: _excelButton(() => exportTable(context, ref, table)),
                      child: SplitBar(parts: [for (var i = 0; i < 5; i++) (_buckets[i], totals[i], _colors[i])]),
                    ),
                  ),
                  Expanded(
                    child: DataList<AgingRow>(
                      rows: rows,
                      emptyText: 'لا أرصدة مفتوحة',
                      onTap: (r) => context.go('${_customers ? '/customers' : '/suppliers'}/${r.partyId}'),
                      columns: [
                        DataListColumn(
                          'الاسم',
                          flex: 3,
                          (r) => Text(r.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                        for (var i = 0; i < 5; i++)
                          DataListColumn(
                            _buckets[i],
                            numeric: true,
                            (r) => Text(
                              r.buckets[i] == 0 ? '' : formatMoney(r.buckets[i]),
                              style: TextStyle(color: i >= 3 && r.buckets[i] > 0 ? AppColors.bad : null),
                            ),
                          ),
                        DataListColumn(
                          'الإجمالي',
                          numeric: true,
                          (r) => Text(formatMoney(r.total), style: const TextStyle(fontWeight: FontWeight.w900)),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------- period closing

class ClosingTab extends ConsumerWidget {
  const ClosingTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LedgerBuilder<(DateTime?, DateTime?)>(
      load: (l) async => (await l.lockedUntil(), await l.softClosedUntil()),
      builder: (context, data) {
        final (until, soft) = data;
        return ReportPage(
          maxWidth: 760,
          children: [
            PanelCard(
              title: 'إقفال الفترات',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        until == null ? Icons.lock_open : Icons.lock,
                        color: until == null ? AppColors.muted : AppColors.good,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        until == null ? 'لا توجد فترة مقفلة' : 'الدفاتر مقفلة حتى ${formatDate(until)}',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'بعد الإقفال لا يمكن إضافة أو إلغاء أي فاتورة أو دفعة أو مرتجع أو مصروف أو تسوية أو قيد بتاريخ داخل الفترة المقفلة، '
                    'فتبقى الأرقام التي سلمتها للمحاسب أو للضرائب كما هي. يمكن للمدير إعادة الفتح مع ذكر السبب، ويُسجل ذلك في سجل التعديلات.',
                    style: TextStyle(color: AppColors.muted),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () async {
                          final now = DateTime.now();
                          final lastMonthEnd = DateTime(now.year, now.month, 0);
                          final d = await showDatePicker(
                            context: context,
                            helpText: 'إقفال حتى نهاية يوم',
                            firstDate: DateTime(2000),
                            lastDate: now,
                            initialDate: lastMonthEnd,
                          );
                          if (d == null || !context.mounted) return;
                          final ok = await runGuarded(context, () async {
                            await ref.read(ledgerServiceProvider).closeUntil(d, user: ref.read(currentUserProvider)!);
                            return true;
                          });
                          if (ok == true && context.mounted) {
                            ref.read(ledgerRevisionProvider.notifier).state++;
                            showToast(context, 'تم الإقفال حتى ${formatDate(d)}');
                          }
                        },
                        icon: const Icon(Icons.lock),
                        label: const Text('إقفال حتى تاريخ…'),
                      ),
                      if (until != null)
                        OutlinedButton.icon(
                          onPressed: () async {
                            final d = await showDatePicker(
                              context: context,
                              helpText: 'إعادة الفتح من يوم',
                              firstDate: DateTime(2000),
                              lastDate: until,
                              initialDate: DateTime(until.year, until.month, 1),
                            );
                            if (d == null || !context.mounted) return;
                            final reason = await askReason(context, title: 'سبب إعادة الفتح');
                            if (reason == null || !context.mounted) return;
                            final ok = await runGuarded(context, () async {
                              await ref
                                  .read(ledgerServiceProvider)
                                  .reopenFrom(d, reason: reason, user: ref.read(currentUserProvider)!);
                              return true;
                            });
                            if (ok == true && context.mounted) ref.read(ledgerRevisionProvider.notifier).state++;
                          },
                          icon: const Icon(Icons.lock_open),
                          label: const Text('إعادة فتح…'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            PanelCard(
              title: 'الإقفال المبدئي (للمراجعة)',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    soft == null ? 'لا يوجد إقفال مبدئي' : 'مقفل مبدئياً حتى ${formatDate(soft)}',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'أثناء مراجعة الشهر: لا يسجل أو يلغي مستندات بتاريخ داخل الفترة إلا المدير والمحاسب. '
                    'بعد المراجعة اعمل الإقفال النهائي بالأعلى.',
                    style: TextStyle(color: AppColors.muted),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          final now = DateTime.now();
                          final d = await showDatePicker(
                            context: context,
                            firstDate: DateTime(2000),
                            lastDate: now,
                            initialDate: DateTime(now.year, now.month, 0),
                          );
                          if (d == null || !context.mounted) return;
                          final ok = await runGuarded(context, () async {
                            await ref.read(ledgerServiceProvider).softClose(d, user: ref.read(currentUserProvider)!);
                            return true;
                          });
                          if (ok == true && context.mounted) ref.read(ledgerRevisionProvider.notifier).state++;
                        },
                        icon: const Icon(Icons.lock_clock_outlined),
                        label: const Text('إقفال مبدئي حتى تاريخ…'),
                      ),
                      if (soft != null)
                        TextButton(
                          onPressed: () async {
                            final ok = await runGuarded(context, () async {
                              await ref
                                  .read(ledgerServiceProvider)
                                  .softClose(null, user: ref.read(currentUserProvider)!);
                              return true;
                            });
                            if (ok == true && context.mounted) ref.read(ledgerRevisionProvider.notifier).state++;
                          },
                          child: const Text('إلغاء الإقفال المبدئي'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            PanelCard(
              title: 'مراجعة القيود',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'كل قيود المستندات تُبنى تلقائياً من المستندات نفسها. لو استرجعت نسخة احتياطية قديمة أو أردت التأكد، '
                    'أعد بناءها من المستندات؛ القيود اليدوية لا تتأثر.',
                    style: TextStyle(color: AppColors.muted),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final ok = await runGuarded(context, () async {
                          await ref.read(ledgerServiceProvider).rebuild();
                          return true;
                        });
                        if (ok == true && context.mounted) {
                          ref.read(ledgerRevisionProvider.notifier).state++;
                          showToast(context, 'تمت إعادة بناء القيود');
                        }
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('إعادة بناء القيود من المستندات'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
