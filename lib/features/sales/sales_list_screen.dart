import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/dates.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/search_text.dart';
import '../../core/services/sales_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/list_kit.dart';

enum _Range { today, week, month, all }

/// Sales invoices: the period's figures, a filter by where each invoice
/// stands with its money, and the list.
class SalesListScreen extends ConsumerStatefulWidget {
  const SalesListScreen({super.key});

  @override
  ConsumerState<SalesListScreen> createState() => _SalesListScreenState();
}

class _SalesListScreenState extends ConsumerState<SalesListScreen> {
  _Range _range = _Range.today;
  String _search = '';
  PayState? _state;

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(_salesListProvider(_range));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: Strings.sales,
          actions: [
            SearchBox(hint: Strings.searchInvoices, onChanged: (v) => setState(() => _search = v)),
            SegmentedButton<_Range>(
              segments: const [
                ButtonSegment(value: _Range.today, label: Text(Strings.today)),
                ButtonSegment(value: _Range.week, label: Text('7 أيام')),
                ButtonSegment(value: _Range.month, label: Text(Strings.thisMonth)),
                ButtonSegment(value: _Range.all, label: Text(Strings.all)),
              ],
              selected: {_range},
              onSelectionChanged: (s) => setState(() => _range = s.single),
            ),
            OutlinedButton.icon(
              onPressed: () => context.go('/sales/orders'),
              icon: const Icon(Icons.assignment_outlined),
              label: const Text('أوامر البيع'),
            ),
            OutlinedButton.icon(
              onPressed: () => context.go('/sales/deliveries'),
              icon: const Icon(Icons.local_shipping_outlined),
              label: const Text('التوصيلات'),
            ),
            FilledButton.icon(
              onPressed: () => context.go('/sales/new'),
              icon: const Icon(Icons.add),
              label: const Text(Strings.newInvoice),
            ),
          ],
        ),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (all) {
              PayState stateOf(SalesInvoiceRow r) =>
                  payStateOf(total: r.invoice.total, paid: r.paid, status: r.invoice.status);
              final searched =
                  all.where((r) => matchesSearch(_search, [r.invoice.number, r.customerName])).toList();
              final active = searched.where((r) => r.invoice.status == DocStatus.active).toList();
              int count(PayState s) => searched.where((r) => stateOf(r) == s).length;
              final shown = _state == null ? searched : searched.where((r) => stateOf(r) == _state).toList();
              final total = active.fold(0, (s, r) => s + r.invoice.total);
              final paid = active.fold(0, (s, r) => s + r.paid);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SummaryStrip(items: [
                    SummaryItem(Strings.totalSales, formatMoney(total), icon: Icons.point_of_sale),
                    SummaryItem('عدد الفواتير', '${active.length}', icon: Icons.receipt_long_outlined),
                    SummaryItem('المحصّل', formatMoney(paid), icon: Icons.payments_outlined, tone: AppColors.good),
                    SummaryItem('المتبقي على العملاء', formatMoney(total - paid),
                        icon: Icons.pending_actions_outlined, tone: total > paid ? AppColors.warn : null),
                    SummaryItem('متوسط الفاتورة', formatMoney(active.isEmpty ? 0 : total ~/ active.length),
                        icon: Icons.functions),
                  ]),
                  CountChips<PayState?>(
                    selected: _state,
                    onSelected: (v) => setState(() => _state = v),
                    options: [
                      (null, Strings.all, searched.length),
                      (PayState.paid, payStateLabel(PayState.paid), count(PayState.paid)),
                      (PayState.partial, payStateLabel(PayState.partial), count(PayState.partial)),
                      (PayState.unpaid, payStateLabel(PayState.unpaid), count(PayState.unpaid)),
                      (PayState.cancelled, payStateLabel(PayState.cancelled), count(PayState.cancelled)),
                    ],
                  ),
                  Expanded(
                    child: DataList<SalesInvoiceRow>(
                      rows: shown,
                      emptyText: Strings.noInvoices,
                      onTap: (r) => context.go('/sales/${r.invoice.id}'),
                      rowColor: (r) => r.invoice.status == DocStatus.cancelled ? AppColors.canvas : null,
                      columns: [
                        DataListColumn(Strings.invoiceNo, flex: 2, (r) => Text(r.invoice.number,
                            style: const TextStyle(fontWeight: FontWeight.w700))),
                        DataListColumn(Strings.date, flex: 2, (r) => Text(formatDateTime(r.invoice.date))),
                        DataListColumn(Strings.customer, flex: 3, (r) => r.invoice.customerId == null
                            ? const Text(Strings.cashCustomer, style: TextStyle(color: AppColors.muted))
                            : InkWell(
                                onTap: () => context.go('/customers/${r.invoice.customerId}'),
                                child: Text(r.customerName ?? '',
                                    style: const TextStyle(color: AppColors.brand, fontWeight: FontWeight.w600)),
                              )),
                        DataListColumn(Strings.total, flex: 2, numeric: true, (r) => Text(formatMoney(r.invoice.total))),
                        DataListColumn(Strings.paid, flex: 2, numeric: true, (r) => Text(formatMoney(r.paid))),
                        DataListColumn(Strings.remaining, flex: 2, numeric: true, (r) {
                          final left = r.invoice.status == DocStatus.cancelled ? 0 : r.invoice.total - r.paid;
                          return Text(formatMoney(left),
                              style: left > 0 ? const TextStyle(fontWeight: FontWeight.w700) : null);
                        }),
                        DataListColumn(Strings.status, flex: 2, numeric: true, (r) => payStatePill(stateOf(r))),
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

final _salesListProvider = StreamProvider.autoDispose.family<List<SalesInvoiceRow>, _Range>((ref, range) {
  final now = DateTime.now();
  final (from, to) = switch (range) {
    _Range.today => (now, now),
    _Range.week => (now.subtract(const Duration(days: 6)), now),
    _Range.month => (DateTime(now.year, now.month), now),
    _Range.all => (null, null),
  };
  return ref.watch(salesServiceProvider).watchList(from: from, to: to);
});
