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
import '../../core/widgets/amounts.dart';
import '../payments/payment_dialog.dart';
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
      setState(() {
        _detail = _load();
      });
    }
  }

  Future<void> _receive(SalesInvoiceDetail d) async {
    final saved = await showPaymentDialog(
      context,
      partyType: PartyType.customer,
      partyId: d.customer!.id,
      invoiceId: d.invoice.id,
    );
    if (saved && mounted) {
      setState(() {
        _detail = _load();
      });
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
            // Wraps the buttons onto a second line in a narrow window.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IconButton(
                  tooltip: Strings.back,
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: () => context.go('/sales'),
                ),
                Text('${Strings.salesInvoice} ${inv.number}', style: theme.textTheme.headlineSmall),
                if (cancelled)
                  Chip(
                    label: const Text(Strings.cancelled),
                    backgroundColor: theme.colorScheme.errorContainer,
                  ),
                const SizedBox(width: 16),
                if (!cancelled && d.customer != null && inv.total > d.paid)
                  OutlinedButton.icon(
                    onPressed: () => _receive(d),
                    icon: const Icon(Icons.payments_outlined),
                    label: const Text(Strings.receivePayment),
                  ),
                if (!cancelled)
                  OutlinedButton.icon(
                    onPressed: () => context.go('/returns/new?kind=sale&invoice=${inv.id}'),
                    icon: const Icon(Icons.assignment_return_outlined),
                    label: const Text(Strings.saleReturn),
                  ),
                if (isAdmin && !cancelled)
                  OutlinedButton.icon(
                    onPressed: () => _cancel(d),
                    icon: const Icon(Icons.block),
                    label: const Text(Strings.cancelInvoice),
                    style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                  ),
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
                    TotalRow(Strings.subtotal, inv.subtotal),
                    if (inv.discount != 0) TotalRow(Strings.invoiceDiscount, inv.discount),
                    TotalRow(Strings.total, inv.total, bold: true),
                    TotalRow(Strings.paid, d.paid),
                    TotalRow(Strings.remaining, inv.total - d.paid, bold: true),
                    if (d.customerBalance != null) ...[
                      const Divider(),
                      TotalRow(Strings.customerBalanceNow, d.customerBalance!),
                    ],
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
