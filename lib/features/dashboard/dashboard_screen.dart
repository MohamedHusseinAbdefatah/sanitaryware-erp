import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/backup/backup_actions.dart';
import '../../core/dates.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/reports/report_service.dart';
import '../../core/services/purchase_service.dart';
import '../../core/theme.dart';

final _supplierDuesProvider = StreamProvider.autoDispose<List<SupplierDue>>(
    (ref) => ref.watch(purchaseServiceProvider).watchDue());

/// Today and this month at a glance, with what needs attention. Money that
/// shows margins or what the shop owes is for the admin only. Tapping a card
/// opens the screen behind it.
class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late Future<DashboardSummary> _summary = _load();
  late final Future<ExternalBackupStatus> _backup = ref.read(backupActionsProvider).externalStatus();

  Future<DashboardSummary> _load() => ref.read(reportServiceProvider).dashboard();

  /// The plan's startup warning: the data lives on this computer only, so
  /// the admin is told when there is no recent copy elsewhere.
  String? _backupText(ExternalBackupStatus s) => switch (s.state) {
        ExternalBackupState.notSet => Strings.backupWarnNotSet,
        ExternalBackupState.unavailable => Strings.backupWarnUnavailable,
        ExternalBackupState.old =>
          s.ageDays == null ? Strings.backupWarnNone : '${Strings.backupWarnOld} ${s.ageDays} ${Strings.days}',
        ExternalBackupState.ok => null,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = ref.watch(currentUserProvider);
    final isAdmin = user?.isAdmin ?? false;
    final dues = isAdmin ? ref.watch(_supplierDuesProvider).valueOrNull ?? const <SupplierDue>[] : const <SupplierDue>[];
    final overdue = dues.where((x) => x.overdue).toList();
    return FutureBuilder<DashboardSummary>(
      future: _summary,
      builder: (context, snap) {
        final d = snap.data;
        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(Strings.dashboard, style: theme.textTheme.headlineSmall),
                      Text(
                        'أهلاً ${user?.fullName ?? ''}، هذا ملخص المحل حتى الآن',
                        style: const TextStyle(color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: Strings.refresh,
                  icon: const Icon(Icons.refresh),
                  onPressed: () => setState(() => _summary = _load()),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _QuickActions(isAdmin: isAdmin),
            const SizedBox(height: 16),
            if (snap.hasError) Text('${snap.error}'),
            if (d == null && !snap.hasError)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
            if (d != null) ...[
              _Attention(
                items: [
                  if (isAdmin)
                    _AttentionItem.async(_backup.then(_backupText), Icons.backup_outlined, '/settings', bad: true),
                  if (d.lowStockCount > 0)
                    _AttentionItem('${d.lowStockCount} صنف تحت حد الطلب', Icons.inventory_2_outlined, '/inventory'),
                  if (d.chequesInDue + d.chequesOutDue > 0)
                    _AttentionItem(
                        '${d.chequesInDue + d.chequesOutDue} شيك يستحق خلال أسبوع', Icons.event_note_outlined, '/payments'),
                  if (isAdmin && d.pendingPriceLists > 0)
                    _AttentionItem('${d.pendingPriceLists} قائمة أسعار تنتظر المراجعة', Icons.price_change_outlined,
                        '/price-lists'),
                  if (isAdmin && d.reviewRows > 0)
                    _AttentionItem('${d.reviewRows} صف أسعار متوقف للمراجعة', Icons.rule_outlined, '/price-lists'),
                  if (overdue.isNotEmpty)
                    _AttentionItem(
                        '${overdue.length} فاتورة مورد متأخرة السداد (${formatMoney(overdue.fold(0, (s, x) => s + x.remaining))})',
                        Icons.alarm_outlined,
                        '/purchases'),
                  if (isAdmin && d.unknownPriceStock > 0)
                    _AttentionItem('${d.unknownPriceStock} صنف مخزونه بقائمة غير محددة', Icons.help_outline,
                        '/inventory'),
                ],
              ),
              LayoutBuilder(builder: (context, c) {
                final perRow = c.maxWidth > 780 ? 4 : (c.maxWidth > 560 ? 3 : 2);
                final w = (c.maxWidth - 14 * (perRow - 1)) / perRow;
                final change = d.lastMonthSales == 0
                    ? null
                    : ((d.monthSales - d.lastMonthSales) * 100 / d.lastMonthSales).round();
                return Wrap(
                  spacing: 14,
                  runSpacing: 14,
                  children: [
                    _Kpi(
                      width: w,
                      icon: Icons.receipt_long_outlined,
                      title: Strings.todaySales,
                      value: formatMoney(d.todaySales),
                      detail: '${d.todayInvoices} ${Strings.invoicesWord}',
                      onTap: () => context.go('/sales'),
                    ),
                    _Kpi(
                      width: w,
                      icon: Icons.payments_outlined,
                      title: Strings.todayReceived,
                      value: formatMoney(d.todayReceived),
                      onTap: () => context.go('/payments'),
                    ),
                    _Kpi(
                      width: w,
                      icon: Icons.calendar_month_outlined,
                      title: 'مبيعات ${monthName(DateTime.now().month)}',
                      value: formatMoney(d.monthSales),
                      detail: change == null
                          ? '${d.monthInvoices} ${Strings.invoicesWord}'
                          : '${change >= 0 ? '+' : ''}$change% عن الشهر الماضي',
                      tone: change == null ? null : (change >= 0 ? AppColors.good : AppColors.bad),
                      onTap: () => context.go('/sales'),
                    ),
                    _Kpi(
                      width: w,
                      icon: Icons.account_balance_wallet_outlined,
                      title: 'مستحق على العملاء',
                      value: formatMoney(d.receivables),
                      onTap: () => context.go('/customers'),
                    ),
                    if (isAdmin) ...[
                      _Kpi(
                        width: w,
                        icon: Icons.trending_up,
                        title: 'مجمل ربح الشهر',
                        value: formatMoney(d.monthGrossProfit),
                        detail: 'بعد تكلفة FIFO وقبل المصروفات',
                        onTap: () => context.go('/reports'),
                      ),
                      _Kpi(
                        width: w,
                        icon: Icons.warehouse_outlined,
                        title: 'قيمة المخزون بالتكلفة',
                        value: formatMoney(d.stockValue),
                        onTap: () => context.go('/reports'),
                      ),
                      _Kpi(
                        width: w,
                        icon: Icons.local_shipping_outlined,
                        title: 'مستحق للموردين',
                        value: formatMoney(d.payables),
                        onTap: () => context.go('/suppliers'),
                      ),
                    ],
                    _Kpi(
                      width: w,
                      icon: Icons.event_note_outlined,
                      title: Strings.chequesDueWeek,
                      value: '${d.chequesInDue} ${Strings.chequeIn} — ${formatMoney(d.chequesInDueTotal)}',
                      detail: isAdmin ? '${d.chequesOutDue} ${Strings.chequeOut} — ${formatMoney(d.chequesOutDueTotal)}' : null,
                      onTap: () => context.go('/payments'),
                    ),
                  ],
                );
              }),
              const SizedBox(height: 16),
              LayoutBuilder(builder: (context, c) {
                final chart = _Panel(
                  title: 'المبيعات آخر 14 يوماً',
                  child: SizedBox(height: 190, child: _SalesBars(days: d.days)),
                );
                final top = _Panel(
                  title: 'الأكثر مبيعاً هذا الشهر',
                  child: _Bars(
                    empty: 'لا مبيعات هذا الشهر بعد',
                    rows: [for (final (n, v) in d.topProducts) (n, v, formatMoney(v))],
                  ),
                );
                if (c.maxWidth < 760) return Column(children: [chart, const SizedBox(height: 16), top]);
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [Expanded(flex: 3, child: chart), const SizedBox(width: 16), Expanded(flex: 2, child: top)],
                  ),
                );
              }),
              const SizedBox(height: 16),
              LayoutBuilder(builder: (context, c) {
                final low = _Panel(
                  title: Strings.lowStockItems,
                  child: d.lowStock.isEmpty
                      ? const _Empty('كل الأصناف فوق حد الطلب')
                      : Column(
                          children: [
                            for (final (name, stock, min) in d.lowStock)
                              _Line(
                                name,
                                '${formatQty(stock)} من ${formatQty(min)}',
                                color: stock <= 0 ? AppColors.bad : AppColors.warn,
                                onTap: () => context.go('/inventory'),
                              ),
                          ],
                        ),
                );
                final debtors = _Panel(
                  title: Strings.topDebtors,
                  child: d.topDebtors.isEmpty
                      ? const _Empty(Strings.noDebtors)
                      : Column(
                          children: [
                            for (final (name, balance) in d.topDebtors)
                              _Line(name, formatMoney(balance), onTap: () => context.go('/customers')),
                          ],
                        ),
                );
                if (c.maxWidth < 760) return Column(children: [low, const SizedBox(height: 16), debtors]);
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [Expanded(child: low), const SizedBox(width: 16), Expanded(child: debtors)],
                  ),
                );
              }),
              if (isAdmin) ...[
                const SizedBox(height: 16),
                _Panel(
                  title: 'مستحق للموردين خلال أسبوع',
                  child: dues.isEmpty
                      ? const _Empty('لا توجد فواتير موردين مستحقة خلال أسبوع')
                      : Column(
                          children: [
                            for (final x in dues.take(8))
                              _Line(
                                '${x.supplierName} · ${x.invoice.number} · '
                                '${x.overdue ? 'متأخرة منذ' : 'تستحق'} ${formatDate(x.invoice.dueDate!)}',
                                formatMoney(x.remaining),
                                color: x.overdue ? AppColors.bad : AppColors.warn,
                                onTap: () => context.go('/purchases/${x.invoice.id}'),
                              ),
                          ],
                        ),
                ),
              ],
            ],
          ],
        );
      },
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.isAdmin});

  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    Widget action(IconData icon, String label, String path, {bool primary = false}) => primary
        ? FilledButton.icon(onPressed: () => context.go(path), icon: Icon(icon, size: 18), label: Text(label))
        : OutlinedButton.icon(onPressed: () => context.go(path), icon: Icon(icon, size: 18), label: Text(label));
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        action(Icons.point_of_sale, 'فاتورة بيع سريعة', '/sales/new', primary: true),
        action(Icons.request_quote_outlined, 'استلام من عميل', '/payments'),
        action(Icons.assignment_return_outlined, 'مرتجع بيع', '/returns/new?kind=sale'),
        if (isAdmin) action(Icons.add_shopping_cart, 'فاتورة شراء جديدة', '/purchases/new'),
        if (isAdmin) action(Icons.bar_chart, 'فتح التقارير', '/reports'),
      ],
    );
  }
}

class _AttentionItem {
  _AttentionItem(String text, this.icon, this.path)
      : text = Future.value(text),
        bad = false;
  _AttentionItem.async(this.text, this.icon, this.path, {this.bad = false});

  /// Null = nothing to say.
  final Future<String?> text;
  final IconData icon;
  final String path;
  final bool bad;
}

/// What needs someone's attention, as a strip of tappable chips.
class _Attention extends StatelessWidget {
  const _Attention({required this.items});

  final List<_AttentionItem> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final it in items)
            FutureBuilder<String?>(
              future: it.text,
              builder: (context, snap) {
                final text = snap.data;
                if (text == null) return const SizedBox.shrink();
                final color = it.bad ? AppColors.bad : AppColors.warn;
                return Material(
                  color: it.bad ? AppColors.badBg : AppColors.warnBg,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => context.go(it.path),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(it.icon, size: 18, color: color),
                          const SizedBox(width: 8),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 520),
                            child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({
    required this.width,
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
    this.detail,
    this.tone,
  });

  final double width;
  final IconData icon;
  final String title;
  final String value;
  final String? detail;
  final Color? tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(color: AppColors.canvas, borderRadius: BorderRadius.circular(8)),
                      child: Icon(icon, size: 18, color: AppColors.brand),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(title, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.muted)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(value, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700)),
                ),
                if (detail != null)
                  Text(
                    detail!,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: tone ?? AppColors.muted, fontWeight: tone == null ? null : FontWeight.w700),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
      );
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.color, this.onTap});

  final String label;
  final String value;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
        child: Row(
          children: [
            Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
            Text(value, style: TextStyle(fontWeight: FontWeight.w700, color: color)),
          ],
        ),
      ),
    );
  }
}

/// Horizontal bars: label, value text, and a bar sized to the largest value.
class _Bars extends StatelessWidget {
  const _Bars({required this.rows, required this.empty});

  final List<(String, int, String)> rows;
  final String empty;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return _Empty(empty);
    final max = rows.map((r) => r.$2).fold<int>(1, (a, b) => b > a ? b : a);
    return Column(
      children: [
        for (final (label, value, text) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
                    Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: value <= 0 ? 0 : value / max,
                    minHeight: 6,
                    backgroundColor: AppColors.canvas,
                    color: AppColors.brand,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Columns for each of the last 14 days, oldest on the right (reading order).
class _SalesBars extends StatelessWidget {
  const _SalesBars({required this.days});

  final List<(DateTime, int)> days;

  @override
  Widget build(BuildContext context) {
    if (days.every((d) => d.$2 == 0)) return const Center(child: _Empty('لا مبيعات في آخر 14 يوماً'));
    final max = days.map((d) => d.$2).fold<int>(1, (a, b) => b > a ? b : a);
    final today = DateTime.now();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (day, total) in days)
          Expanded(
            child: Tooltip(
              message: '${formatDate(day)}: ${formatMoney(total)}',
              child: Column(
                children: [
                  // The bar takes its share of whatever height is left above the label.
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: total <= 0 ? .01 : total / max,
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color: day.day == today.day && day.month == today.month
                                ? AppColors.brand
                                : AppColors.brand.withValues(alpha: .45),
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('${day.day}/${day.month}', style: const TextStyle(fontSize: 10, color: AppColors.muted, height: 1.1)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
