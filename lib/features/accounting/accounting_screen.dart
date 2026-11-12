import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/services/ledger_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/charts.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/record_page.dart';
import 'accounting_books.dart';
import 'accounting_kit.dart';
import 'accounting_reports.dart';

/// The accounts: an overview with charts, the chart of accounts, the
/// journal, and the statements. Admin only (the section is).
class AccountingScreen extends StatefulWidget {
  const AccountingScreen({super.key, this.tab});

  final String? tab;

  static const tabs = <(String, String, IconData)>[
    ('overview', 'نظرة عامة', Icons.insights_outlined),
    ('accounts', 'دليل الحسابات', Icons.account_tree_outlined),
    ('journal', 'القيود', Icons.menu_book_outlined),
    ('trial', 'ميزان المراجعة', Icons.balance_outlined),
    ('pl', 'قائمة الدخل', Icons.trending_up),
    ('bs', 'الميزانية', Icons.account_balance_outlined),
    ('cash', 'التدفقات النقدية', Icons.waves_outlined),
    ('vat', 'الضريبة', Icons.percent),
    ('aging', 'أعمار الديون', Icons.hourglass_bottom),
    ('closing', 'إقفال الفترات', Icons.lock_outline),
  ];

  @override
  State<AccountingScreen> createState() => _AccountingScreenState();
}

class _AccountingScreenState extends State<AccountingScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    final i = AccountingScreen.tabs.indexWhere((t) => t.$1 == widget.tab);
    _tabs = TabController(length: AccountingScreen.tabs.length, vsync: this, initialIndex: i < 0 ? 0 : i);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const PageHeader(title: 'المحاسبة'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            for (final (_, label, icon) in AccountingScreen.tabs)
              Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 18), const SizedBox(width: 6), Text(label)])),
          ],
        ),
      ),
      const Divider(height: 1),
      const SizedBox(height: 12),
      Expanded(
        child: TabBarView(
          controller: _tabs,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            OverviewTab(onOpen: (key) => _tabs.animateTo(AccountingScreen.tabs.indexWhere((t) => t.$1 == key))),
            const ChartOfAccountsTab(),
            const JournalTab(),
            const TrialBalanceTab(),
            const ProfitLossTab(),
            const BalanceSheetTab(),
            const CashFlowTab(),
            const VatTab(),
            const AgingTab(),
            const ClosingTab(),
          ],
        ),
      ),
    ]);
  }
}

class _Overview {
  const _Overview(this.balances, this.month, this.monthly, this.aging, this.payables);

  final Map<String, int> balances;
  final ProfitAndLoss month;
  final List<(DateTime, int, int, int)> monthly;
  final List<AgingRow> aging;
  final List<AgingRow> payables;
}

const _months = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];

class OverviewTab extends ConsumerWidget {
  const OverviewTab({super.key, required this.onOpen});

  final void Function(String tab) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LedgerBuilder<_Overview>(
      load: (l) async {
        final rows = await l.balances();
        final now = DateTime.now();
        return _Overview(
          {for (final r in rows) if (r.account.systemKey != null) r.account.systemKey!: r.natural},
          await l.profitAndLoss(from: DateTime(now.year, now.month), to: now),
          await l.monthly(months: 12),
          await l.aging(customers: true),
          await l.aging(customers: false),
        );
      },
      builder: (context, o) {
        int b(String k) => o.balances[k] ?? 0;
        final overdue = o.aging.fold(0, (s, r) => s + r.buckets[3] + r.buckets[4]);
        final tiles = [
          StatTile('الخزنة', formatMoney(b('cash')), icon: Icons.point_of_sale),
          StatTile('البنك', formatMoney(b('bank')), icon: Icons.account_balance),
          StatTile('شيكات تحت التحصيل', formatMoney(b('cheques_in')), icon: Icons.receipt_outlined),
          StatTile('مستحق لنا من العملاء', formatMoney(b('ar')),
              icon: Icons.call_received, hint: overdue > 0 ? 'منها ${formatMoney(overdue)} أكثر من 60 يوم' : null,
              tone: overdue > 0 ? AppColors.warn : null),
          StatTile('مستحق علينا للموردين', formatMoney(b('ap')), icon: Icons.call_made),
          StatTile('قيمة المخزون', formatMoney(b('inventory')), icon: Icons.warehouse_outlined),
          StatTile('صافي ربح الشهر', formatMoney(o.month.netProfit),
              icon: Icons.trending_up, tone: o.month.netProfit < 0 ? AppColors.bad : AppColors.good,
              hint: 'هامش ${percentBp(o.month.netMarginBp)}'),
          StatTile('ضريبة مخرجات مستحقة', formatMoney(b('vat_out') - b('vat_in')), icon: Icons.percent),
        ];
        return ReportPage(maxWidth: 1400, children: [
          Wrap(spacing: 12, runSpacing: 12, children: [for (final t in tiles) _Tile(t)]),
          PanelCard(
            title: 'المبيعات والتكاليف والربح — آخر 12 شهر',
            action: TextButton(onPressed: () => onOpen('pl'), child: const Text('قائمة الدخل')),
            child: BarChart(
              labels: [for (final m in o.monthly) _months[m.$1.month - 1]],
              series: [
                ChartSeries('صافي المبيعات', AppColors.brand, [for (final m in o.monthly) m.$2]),
                ChartSeries('التكاليف والمصروفات', const Color(0xFF9DB4B8), [for (final m in o.monthly) m.$3]),
                ChartSeries('صافي الربح', AppColors.good, [for (final m in o.monthly) m.$4]),
              ],
            ),
          ),
          LayoutBuilder(builder: (context, box) {
            final cards = [
              PanelCard(
                title: 'مصروفات الشهر',
                child: RankBars(
                  color: const Color(0xFFD9822B),
                  rows: [for (final (a, v) in o.month.operating.rows) (a.nameAr, v)],
                ),
              ),
              PanelCard(
                title: 'أكبر المدينين',
                action: TextButton(onPressed: () => onOpen('aging'), child: const Text('أعمار الديون')),
                child: RankBars(rows: [for (final r in o.aging) (r.name, r.total)]),
              ),
              PanelCard(
                title: 'أكبر الدائنين',
                child: RankBars(color: AppColors.info, rows: [for (final r in o.payables) (r.name, r.total)]),
              ),
            ];
            if (box.maxWidth < 1000) {
              return Column(children: [for (final c in cards) Padding(padding: const EdgeInsets.only(bottom: 16), child: c)]);
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const SizedBox(width: 16),
                Expanded(child: cards[i]),
              ],
            ]);
          }),
          PanelCard(
            title: 'أعمار ديون العملاء',
            child: SplitBar(parts: [
              ('غير مستحق', o.aging.fold(0, (s, r) => s + r.buckets[0]), AppColors.good),
              ('1-30', o.aging.fold(0, (s, r) => s + r.buckets[1]), AppColors.info),
              ('31-60', o.aging.fold(0, (s, r) => s + r.buckets[2]), AppColors.warn),
              ('61-90', o.aging.fold(0, (s, r) => s + r.buckets[3]), const Color(0xFFD9822B)),
              ('+90', o.aging.fold(0, (s, r) => s + r.buckets[4]), AppColors.bad),
            ]),
          ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (key, label, icon) in AccountingScreen.tabs.skip(1))
              ActionChip(avatar: Icon(icon, size: 16), label: Text(label), onPressed: () => onOpen(key)),
            ActionChip(
              avatar: const Icon(Icons.add, size: 16),
              label: const Text('قيد يدوي'),
              onPressed: () => showDialog<void>(context: context, builder: (_) => const ManualEntryDialog()),
            ),
            ActionChip(
              avatar: const Icon(Icons.work_outline, size: 16),
              label: const Text('المشروعات'),
              onPressed: () => context.go('/projects'),
            ),
          ]),
        ]);
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.t);

  final StatTile t;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(color: (t.tone ?? AppColors.brand).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
          child: Icon(t.icon, color: t.tone ?? AppColors.brand, size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.label, style: const TextStyle(color: AppColors.muted, fontSize: 12), overflow: TextOverflow.ellipsis),
            Text(t.value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
            if (t.hint != null) Text(t.hint!, style: const TextStyle(color: AppColors.muted, fontSize: 11), overflow: TextOverflow.ellipsis),
          ]),
        ),
      ]),
    );
  }
}
