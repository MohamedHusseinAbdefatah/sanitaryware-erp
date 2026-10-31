import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/sales_service.dart';
import '../../core/widgets/feedback.dart';

/// A posted invoice, read-only. Posted invoices are never edited: the admin
/// cancels and the invoice is entered again.
class SaleViewScreen extends ConsumerStatefulWidget {
  const SaleViewScreen({super.key, required this.invoiceId});

  final int invoiceId;

  @override
  ConsumerState<SaleViewScreen> createState() => _SaleViewScreenState();
}

class _SaleViewScreenState extends ConsumerState<SaleViewScreen> {
  late Future<SalesInvoiceDetail> _detail = _load();

  Future<SalesInvoiceDetail> _load() => ref.read(salesServiceProvider).detail(widget.invoiceId);

  Future<void> _cancel(SalesInvoiceDetail d) async {
    final reason = await askReason(context, title: '${Strings.cancelInvoice} ${d.invoice.number}');
    if (reason == null || !mounted) return;
    final ok = await runGuarded(context, () async {
      await ref
          .read(salesServiceProvider)
          .cancel(d.invoice.id, reason: reason, user: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true && mounted) {
      showToast(context, Strings.invoiceCancelled);
      setState(() => _detail = _load());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(currentUserProvider)?.isAdmin ?? false;
    final theme = Theme.of(context);
    return FutureBuilder<SalesInvoiceDetail>(
      future: _detail,
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('${snap.error}'));
        final d = snap.data;
        if (d == null) return const Center(child: CircularProgressIndicator());
        final inv = d.invoice;
        final cancelled = inv.status == DocStatus.cancelled;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: Strings.back,
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: () => context.go('/sales'),
                ),
                Text('${Strings.salesInvoice} ${inv.number}', style: theme.textTheme.headlineSmall),
                const SizedBox(width: 12),
                if (cancelled)
                  Chip(
                    label: const Text(Strings.cancelled),
                    backgroundColor: theme.colorScheme.errorContainer,
                  ),
                const Spacer(),
                if (isAdmin && !cancelled)
                  OutlinedButton.icon(
                    onPressed: () => _cancel(d),
                    icon: const Icon(Icons.block),
                    label: const Text(Strings.cancelInvoice),
                    style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                  ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => context.go('/sales/new'),
                  icon: const Icon(Icons.add),
                  label: const Text(Strings.newInvoice),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 32,
              runSpacing: 8,
              children: [
                Text('${Strings.date}: ${formatDateTime(inv.date)}'),
                Text('${Strings.customer}: ${d.customer?.name ?? Strings.cashCustomer}'),
                if (d.createdByName != null) Text('${Strings.createdBy}: ${d.createdByName}'),
              ],
            ),
            const SizedBox(height: 16),
            Card(
              clipBehavior: Clip.antiAlias,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('#')),
                  DataColumn(label: Text(Strings.code)),
                  DataColumn(label: Text(Strings.productName)),
                  DataColumn(label: Text(Strings.qty), numeric: true),
                  DataColumn(label: Text(Strings.unit)),
                  DataColumn(label: Text(Strings.price), numeric: true),
                  DataColumn(label: Text(Strings.discount), numeric: true),
                  DataColumn(label: Text(Strings.lineTotal), numeric: true),
                ],
                rows: [
                  for (var i = 0; i < d.lines.length; i++)
                    DataRow(cells: [
                      DataCell(Text('${i + 1}')),
                      DataCell(Text(d.lines[i].productCode)),
                      DataCell(Text(d.lines[i].productName)),
                      DataCell(Text(formatQty(d.lines[i].item.qty))),
                      DataCell(Text(d.lines[i].unitName ?? '')),
                      DataCell(Text(formatMoney(d.lines[i].item.unitPrice))),
                      DataCell(Text(d.lines[i].item.discount == 0 ? '' : formatMoney(d.lines[i].item.discount))),
                      DataCell(Text(formatMoney(d.lines[i].item.lineTotal))),
                    ]),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: SizedBox(
                width: 320,
                child: Column(
                  children: [
                    _TotalRow(Strings.subtotal, inv.subtotal),
                    if (inv.discount != 0) _TotalRow(Strings.invoiceDiscount, inv.discount),
                    _TotalRow(Strings.total, inv.total, bold: true),
                    _TotalRow(Strings.paid, inv.paidAmount),
                    _TotalRow(Strings.remaining, inv.total - inv.paidAmount, bold: true),
                  ],
                ),
              ),
            ),
            if (inv.notes != null) ...[
              const SizedBox(height: 16),
              Text('${Strings.notes}: ${inv.notes}'),
            ],
          ],
        );
      },
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow(this.label, this.amount, {this.bold = false});

  final String label;
  final int amount;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 16) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(label, style: style),
          const Spacer(),
          Text(formatMoney(amount), style: style),
        ],
      ),
    );
  }
}
