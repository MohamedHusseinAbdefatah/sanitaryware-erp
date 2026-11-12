import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/printing/print_actions.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/db/database.dart';
import '../../core/services/sales_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/document_view.dart';
import '../payments/payment_dialog.dart';
import '../payments/payments_screen.dart';
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
  late Future<(SalesInvoiceDetail, List<Payment>)> _detail = _load();

  Future<(SalesInvoiceDetail, List<Payment>)> _load() async => (
        await ref.read(salesServiceProvider).detail(widget.invoiceId),
        await ref.read(paymentServiceProvider).onInvoice(RefType.salesInvoice, widget.invoiceId),
      );

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
    return FutureBuilder<(SalesInvoiceDetail, List<Payment>)>(
      future: _detail,
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('${snap.error}'));
        final data = snap.data;
        if (data == null) return const Center(child: CircularProgressIndicator());
        final (d, payments) = data;
        final inv = d.invoice;
        final cancelled = inv.status == DocStatus.cancelled;
        final remaining = inv.total - d.paid;
        return DocumentView(
          backLabel: Strings.sales,
          backPath: '/sales',
          kind: Strings.salesInvoice,
          number: inv.number,
          cancelled: cancelled,
          steps: const ['صادرة', 'مدفوعة جزئياً', 'مدفوعة'],
          step: remaining <= 0 ? 2 : (d.paid > 0 ? 1 : 0),
          partyLabel: Strings.customer,
          partyName: d.customer?.name ?? Strings.cashCustomer,
          partyPath: d.customer == null ? null : '/customers/${d.customer!.id}',
          partyDetail: d.customer?.phone,
          facts: [
            (Strings.date, formatDateTime(inv.date)),
            if (d.createdByName != null) (Strings.createdBy, d.createdByName!),
          ],
          columns: const [
            DocColumn('#'),
            DocColumn(Strings.productName, flex: 6),
            DocColumn(Strings.qty, flex: 2, numeric: true),
            DocColumn(Strings.price, flex: 2, numeric: true),
            DocColumn(Strings.discount, flex: 2, numeric: true),
            DocColumn(Strings.lineTotal, flex: 2, numeric: true),
          ],
          rows: [
            for (var i = 0; i < d.lines.length; i++)
              [
                Text('${i + 1}', style: const TextStyle(color: AppColors.muted)),
                InkWell(
                  onTap: () => context.go('/products/${d.lines[i].item.productId}'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.lines[i].productName, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(d.lines[i].productCode, style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                    ],
                  ),
                ),
                Text('${formatQty(d.lines[i].item.qty)} ${d.lines[i].unitName ?? ''}'),
                Text(formatMoney(d.lines[i].item.unitPrice)),
                Text(d.lines[i].item.discount == 0 ? '' : formatMoney(d.lines[i].item.discount)),
                Text(formatMoney(d.lines[i].item.lineTotal), style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
          ],
          totals: [
            (Strings.subtotal, inv.subtotal, false),
            if (inv.discount != 0) (Strings.invoiceDiscount, inv.discount, false),
            (Strings.total, inv.total, true),
            (Strings.paid, d.paid, false),
            (Strings.remaining, cancelled ? 0 : remaining, true),
            if (d.customerBalance != null) (Strings.customerBalanceNow, d.customerBalance!, false),
          ],
          notes: inv.notes,
          payments: [for (final p in payments) PaymentLine.of(p, paymentMethodLabel(p.method))],
          actions: [
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
                FilledButton.tonalIcon(
                  onPressed: () => printSalesInvoice(context, ref, d.invoice.id),
                  icon: const Icon(Icons.print_outlined),
                  label: const Text(Strings.print),
                ),
                FilledButton.icon(
                  onPressed: () => context.go('/sales/new'),
                  icon: const Icon(Icons.add),
                  label: const Text(Strings.newInvoice),
                ),
          ],
        );
      },
    );
  }
}
