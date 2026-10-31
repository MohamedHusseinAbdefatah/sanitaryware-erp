import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/purchase_service.dart';
import '../../core/widgets/amounts.dart';
import '../../core/widgets/feedback.dart';
import '../payments/payment_dialog.dart';

class PurchaseViewScreen extends ConsumerStatefulWidget {
  const PurchaseViewScreen({super.key, required this.invoiceId});

  final int invoiceId;

  @override
  ConsumerState<PurchaseViewScreen> createState() => _PurchaseViewScreenState();
}

class _PurchaseViewScreenState extends ConsumerState<PurchaseViewScreen> {
  late Future<PurchaseInvoiceDetail> _detail = _load();

  Future<PurchaseInvoiceDetail> _load() => ref.read(purchaseServiceProvider).detail(widget.invoiceId);

  void _reload() => setState(() {
        _detail = _load();
      });

  Future<void> _cancel(PurchaseInvoiceDetail d) async {
    final reason = await askReason(context, title: '${Strings.cancelInvoice} ${d.invoice.number}');
    if (reason == null || !mounted) return;
    final ok = await runGuarded(context, () async {
      await ref
          .read(purchaseServiceProvider)
          .cancel(d.invoice.id, reason: reason, user: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true && mounted) {
      showToast(context, Strings.invoiceCancelled);
      _reload();
    }
  }

  Future<void> _pay(PurchaseInvoiceDetail d) async {
    final saved = await showPaymentDialog(
      context,
      partyType: PartyType.supplier,
      partyId: d.supplier.id,
      invoiceId: d.invoice.id,
    );
    if (saved && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<PurchaseInvoiceDetail>(
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
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IconButton(
                  tooltip: Strings.back,
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: () => context.go('/purchases'),
                ),
                Text('${Strings.purchaseInvoice} ${inv.number}', style: theme.textTheme.headlineSmall),
                if (cancelled)
                  Chip(label: const Text(Strings.cancelled), backgroundColor: theme.colorScheme.errorContainer),
                const SizedBox(width: 24),
                if (!cancelled && inv.total > d.paid)
                  OutlinedButton.icon(
                    onPressed: () => _pay(d),
                    icon: const Icon(Icons.payments_outlined),
                    label: const Text(Strings.payToSupplier),
                  ),
                if (!cancelled)
                  OutlinedButton.icon(
                    onPressed: () => context.go('/returns/new?kind=purchase&invoice=${inv.id}'),
                    icon: const Icon(Icons.assignment_return_outlined),
                    label: const Text(Strings.purchaseReturn),
                  ),
                if (!cancelled)
                  OutlinedButton.icon(
                    onPressed: () => _cancel(d),
                    icon: const Icon(Icons.block),
                    label: const Text(Strings.cancelInvoice),
                    style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 32,
              runSpacing: 8,
              children: [
                Text('${Strings.date}: ${formatDateTime(inv.date)}'),
                Text('${Strings.supplier}: ${d.supplier.name}'),
                if (inv.supplierInvoiceNo != null) Text('${Strings.supplierInvoiceNo}: ${inv.supplierInvoiceNo}'),
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
                  DataColumn(label: Text(Strings.unitCost), numeric: true),
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
                      DataCell(Text(formatMoney(d.lines[i].item.unitCost))),
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
