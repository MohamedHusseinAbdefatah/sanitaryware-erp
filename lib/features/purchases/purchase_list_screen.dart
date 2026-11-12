import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/dates.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/search_text.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/purchase_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/list_kit.dart';

enum _Range { month, quarter, all }

/// Purchase invoices: the period's figures, a filter by where each invoice
/// stands with its money (overdue first in mind), and the list.
class PurchaseListScreen extends ConsumerStatefulWidget {
  const PurchaseListScreen({super.key});

  @override
  ConsumerState<PurchaseListScreen> createState() => _PurchaseListScreenState();
}

class _PurchaseListScreenState extends ConsumerState<PurchaseListScreen> {
  String _search = '';
  _Range _range = _Range.all;
  PayState? _state;

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(_purchasesProvider(_range));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: Strings.purchases,
          actions: [
            SearchBox(hint: Strings.searchPurchases, onChanged: (v) => setState(() => _search = v)),
            SegmentedButton<_Range>(
              segments: const [
                ButtonSegment(value: _Range.month, label: Text(Strings.thisMonth)),
                ButtonSegment(value: _Range.quarter, label: Text('3 شهور')),
                ButtonSegment(value: _Range.all, label: Text(Strings.all)),
              ],
              selected: {_range},
              onSelectionChanged: (s) => setState(() => _range = s.single),
            ),
            OutlinedButton.icon(
              onPressed: () => context.go('/purchases/orders'),
              icon: const Icon(Icons.assignment_outlined),
              label: const Text('أوامر الشراء'),
            ),
            FilledButton.icon(
              onPressed: () => context.go('/purchases/new'),
              icon: const Icon(Icons.add),
              label: const Text(Strings.newPurchase),
            ),
          ],
        ),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (all) {
              PayState stateOf(PurchaseInvoiceRow r) => payStateOf(
                  total: r.invoice.total, paid: r.paid, status: r.invoice.status, dueDate: r.invoice.dueDate);
              final searched = all
                  .where((r) =>
                      matchesSearch(_search, [r.invoice.number, r.invoice.supplierInvoiceNo, r.supplierName]))
                  .toList();
              final active = searched.where((r) => r.invoice.status == DocStatus.active).toList();
              int count(PayState s) => searched.where((r) => stateOf(r) == s).length;
              final shown = _state == null ? searched : searched.where((r) => stateOf(r) == _state).toList();
              final total = active.fold(0, (s, r) => s + r.invoice.total);
              final paid = active.fold(0, (s, r) => s + r.paid);
              final overdue = active
                  .where((r) => stateOf(r) == PayState.overdue)
                  .fold(0, (s, r) => s + r.invoice.total - r.paid);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SummaryStrip(items: [
                    SummaryItem('إجمالي المشتريات', formatMoney(total), icon: Icons.shopping_cart_outlined),
                    SummaryItem('عدد الفواتير', '${active.length}', icon: Icons.receipt_long_outlined),
                    SummaryItem('المدفوع', formatMoney(paid), icon: Icons.payments_outlined, tone: AppColors.good),
                    SummaryItem('المتبقي للموردين', formatMoney(total - paid),
                        icon: Icons.pending_actions_outlined, tone: total > paid ? AppColors.warn : null),
                    SummaryItem('متأخر السداد', formatMoney(overdue),
                        icon: Icons.alarm_outlined, tone: overdue > 0 ? AppColors.bad : null),
                  ]),
                  CountChips<PayState?>(
                    selected: _state,
                    onSelected: (v) => setState(() => _state = v),
                    options: [
                      (null, Strings.all, searched.length),
                      (PayState.overdue, payStateLabel(PayState.overdue), count(PayState.overdue)),
                      (PayState.unpaid, payStateLabel(PayState.unpaid), count(PayState.unpaid)),
                      (PayState.partial, payStateLabel(PayState.partial), count(PayState.partial)),
                      (PayState.paid, payStateLabel(PayState.paid), count(PayState.paid)),
                      (PayState.cancelled, payStateLabel(PayState.cancelled), count(PayState.cancelled)),
                    ],
                  ),
                  Expanded(
                    child: DataList<PurchaseInvoiceRow>(
                      rows: shown,
                      emptyText: Strings.noInvoices,
                      onTap: (r) => context.go('/purchases/${r.invoice.id}'),
                      rowColor: (r) => r.invoice.status == DocStatus.cancelled ? AppColors.canvas : null,
                      columns: [
                        DataListColumn(Strings.invoiceNo, flex: 2, (r) => Text(r.invoice.number,
                            style: const TextStyle(fontWeight: FontWeight.w700))),
                        DataListColumn(Strings.supplierInvoiceNo, flex: 2, (r) => Text(r.invoice.supplierInvoiceNo ?? '')),
                        DataListColumn(Strings.date, flex: 2, (r) => Text(formatDate(r.invoice.date))),
                        DataListColumn(Strings.supplier, flex: 3, (r) => InkWell(
                              onTap: () => context.go('/suppliers/${r.invoice.supplierId}'),
                              child: Text(r.supplierName,
                                  style: const TextStyle(color: AppColors.brand, fontWeight: FontWeight.w600)),
                            )),
                        DataListColumn(Strings.total, flex: 2, numeric: true, (r) => Text(formatMoney(r.invoice.total))),
                        DataListColumn(Strings.remaining, flex: 2, numeric: true, (r) {
                          final left = r.invoice.status == DocStatus.cancelled ? 0 : r.invoice.total - r.paid;
                          return Text(formatMoney(left),
                              style: left > 0 ? const TextStyle(fontWeight: FontWeight.w700) : null);
                        }),
                        DataListColumn('الاستحقاق', flex: 2, (r) => Text(r.invoice.dueDate == null ? '' : formatDate(r.invoice.dueDate!))),
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

final _purchasesProvider = StreamProvider.autoDispose.family<List<PurchaseInvoiceRow>, _Range>((ref, range) {
  final now = DateTime.now();
  final from = switch (range) {
    _Range.month => DateTime(now.year, now.month),
    _Range.quarter => DateTime(now.year, now.month - 2),
    _Range.all => null,
  };
  return ref.watch(purchaseServiceProvider).watchList(from: from, to: from == null ? null : now);
});
