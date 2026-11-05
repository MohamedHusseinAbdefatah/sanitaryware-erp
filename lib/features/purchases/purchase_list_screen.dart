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
import '../../core/widgets/data_list.dart';
import 'purchase_orders_dialog.dart';

class PurchaseListScreen extends ConsumerStatefulWidget {
  const PurchaseListScreen({super.key});

  @override
  ConsumerState<PurchaseListScreen> createState() => _PurchaseListScreenState();
}

class _PurchaseListScreenState extends ConsumerState<PurchaseListScreen> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(_purchasesProvider);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: Strings.purchases,
          actions: [
            SearchBox(hint: Strings.searchPurchases, onChanged: (v) => setState(() => _search = v)),
            OutlinedButton.icon(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const PurchaseOrdersDialog(),
              ),
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
            data: (all) => DataList<PurchaseInvoiceRow>(
              rows: all
                  .where((r) => matchesSearch(
                      _search, [r.invoice.number, r.invoice.supplierInvoiceNo, r.supplierName]))
                  .toList(),
              emptyText: Strings.noInvoices,
              onTap: (r) => context.go('/purchases/${r.invoice.id}'),
              rowColor: (r) => r.invoice.status == DocStatus.cancelled
                  ? scheme.errorContainer.withValues(alpha: 0.3)
                  : null,
              columns: [
                DataListColumn(Strings.invoiceNo, (r) => Text(r.invoice.number)),
                DataListColumn(Strings.supplierInvoiceNo, (r) => Text(r.invoice.supplierInvoiceNo ?? '')),
                DataListColumn(Strings.date, flex: 2, (r) => Text(formatDateTime(r.invoice.date))),
                DataListColumn(Strings.supplier, flex: 3, (r) => Text(r.supplierName)),
                DataListColumn(Strings.total, numeric: true, (r) => Text(formatMoney(r.invoice.total))),
                DataListColumn(Strings.paid, numeric: true, (r) => Text(formatMoney(r.paid))),
                DataListColumn(Strings.remaining, numeric: true,
                    (r) => Text(formatMoney(r.invoice.total - r.paid))),
                DataListColumn(Strings.status, numeric: true, (r) => Text(
                      r.invoice.status == DocStatus.cancelled ? Strings.cancelled : '',
                      style: TextStyle(color: scheme.error),
                    )),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

final _purchasesProvider = StreamProvider.autoDispose<List<PurchaseInvoiceRow>>(
  (ref) => ref.watch(purchaseServiceProvider).watchList(),
);
