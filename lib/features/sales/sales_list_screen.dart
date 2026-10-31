import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/dates.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/search_text.dart';
import '../../core/services/sales_service.dart';
import '../../core/widgets/data_list.dart';

enum _Range { today, month, all }

class SalesListScreen extends ConsumerStatefulWidget {
  const SalesListScreen({super.key});

  @override
  ConsumerState<SalesListScreen> createState() => _SalesListScreenState();
}

class _SalesListScreenState extends ConsumerState<SalesListScreen> {
  _Range _range = _Range.today;
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(_salesListProvider(_range));
    final scheme = Theme.of(context).colorScheme;
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
                ButtonSegment(value: _Range.month, label: Text(Strings.thisMonth)),
                ButtonSegment(value: _Range.all, label: Text(Strings.all)),
              ],
              selected: {_range},
              onSelectionChanged: (s) => setState(() => _range = s.single),
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
              final list = all
                  .where((r) => matchesSearch(_search, [r.invoice.number, r.customerName]))
                  .toList();
              final active = list.where((r) => r.invoice.status == DocStatus.active);
              final total = active.fold(0, (s, r) => s + r.invoice.total);
              return Column(
                children: [
                  Expanded(
                    child: DataList<SalesInvoiceRow>(
                      rows: list,
                      emptyText: Strings.noInvoices,
                      onTap: (r) => context.go('/sales/${r.invoice.id}'),
                      rowColor: (r) => r.invoice.status == DocStatus.cancelled
                          ? scheme.errorContainer.withValues(alpha: 0.3)
                          : null,
                      columns: [
                        DataListColumn(Strings.invoiceNo, (r) => Text(r.invoice.number)),
                        DataListColumn(Strings.date, flex: 2, (r) => Text(formatDateTime(r.invoice.date))),
                        DataListColumn(Strings.customer, flex: 3,
                            (r) => Text(r.customerName ?? Strings.cashCustomer)),
                        DataListColumn(Strings.total, numeric: true, (r) => Text(formatMoney(r.invoice.total))),
                        DataListColumn(Strings.paid, numeric: true, (r) => Text(formatMoney(r.invoice.paidAmount))),
                        DataListColumn(Strings.remaining, numeric: true,
                            (r) => Text(formatMoney(r.invoice.total - r.invoice.paidAmount))),
                        DataListColumn(Strings.status, numeric: true, (r) => Text(
                              r.invoice.status == DocStatus.cancelled ? Strings.cancelled : '',
                              style: TextStyle(color: scheme.error),
                            )),
                      ],
                    ),
                  ),
                  Container(
                    color: scheme.surfaceContainerHigh,
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                    child: Row(
                      children: [
                        Text('${Strings.invoiceCount}: ${active.length}'),
                        const Spacer(),
                        Text(
                          '${Strings.totalSales}: ${formatMoney(total)}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
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

final _salesListProvider = StreamProvider.autoDispose.family<List<SalesInvoiceRow>, _Range>((ref, range) {
  final now = DateTime.now();
  final (from, to) = switch (range) {
    _Range.today => (now, now),
    _Range.month => (DateTime(now.year, now.month), now),
    _Range.all => (null, null),
  };
  return ref.watch(salesServiceProvider).watchList(from: from, to: to);
});
