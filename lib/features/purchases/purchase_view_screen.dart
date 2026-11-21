import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/printing/print_actions.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/purchase_service.dart';
import '../../core/services/supplier_advance_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/document_view.dart';
import '../../core/widgets/feedback.dart';
import '../payments/payment_dialog.dart';
import '../payments/payments_screen.dart';

/// "20%" or "20% + 2%".
String _pct(int base, int extra) {
  String p(int bp) => '${(bp / 100).toStringAsFixed(bp % 100 == 0 ? 0 : 1)}%';
  return extra == 0 ? p(base) : '${p(base)} + ${p(extra)}';
}

/// A posted purchase invoice as a document: supplier, lines with list price,
/// discount and cost in stock, totals, and the payments made on it.
class PurchaseViewScreen extends ConsumerStatefulWidget {
  const PurchaseViewScreen({super.key, required this.invoiceId});

  final int invoiceId;

  @override
  ConsumerState<PurchaseViewScreen> createState() => _PurchaseViewScreenState();
}

class _PurchaseViewScreenState extends ConsumerState<PurchaseViewScreen> {
  late Future<(PurchaseInvoiceDetail, List<Payment>, List<AllocationRow>, AdvanceBalance)> _detail = _load();

  Future<(PurchaseInvoiceDetail, List<Payment>, List<AllocationRow>, AdvanceBalance)> _load() async {
    final d = await ref.read(purchaseServiceProvider).detail(widget.invoiceId);
    final advances = ref.read(supplierAdvanceServiceProvider);
    return (
      d,
      await ref.read(paymentServiceProvider).onInvoice(RefType.purchaseInvoice, widget.invoiceId),
      await advances.allocations(invoiceId: widget.invoiceId),
      await advances.balance(d.supplier.id),
    );
  }

  /// Pays part of the invoice from the supplier's advance balance.
  Future<void> _fromAdvance(PurchaseInvoiceDetail d, AdvanceBalance b) async {
    final left = d.invoice.total - d.paid;
    final most = left < b.remaining ? left : b.remaining;
    final amount = await askAmount(
      context,
      title: 'خصم من الدفعات المقدمة على ${d.invoice.number}',
      hint: 'المتاح ${formatMoney(b.remaining)} · المتبقي على الفاتورة ${formatMoney(left)}',
      initial: most,
    );
    if (amount == null || !mounted) return;
    final ok = await runGuarded(context, () async {
      await ref
          .read(supplierAdvanceServiceProvider)
          .allocate(invoiceId: d.invoice.id, amount: amount, user: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true && mounted) _reload();
  }

  /// Owner: changes how much the invoice takes from advances.
  Future<void> _correctAdvance(PurchaseInvoiceDetail d) async {
    final amount = await askAmount(
      context,
      title: 'تصحيح المخصوم من الدفعات المقدمة',
      hint: 'الحالي ${formatMoney(d.invoice.advanceUsed)} — اكتب المبلغ الصحيح (0 لإلغائه)',
      initial: d.invoice.advanceUsed,
      allowZero: true,
    );
    if (amount == null || !mounted) return;
    final reason = await askReason(context, title: 'سبب التصحيح');
    if (reason == null || !mounted) return;
    final ok = await runGuarded(context, () async {
      await ref.read(supplierAdvanceServiceProvider).correctInvoiceAllocation(
          d.invoice.id, amount, reason: reason, user: ref.read(currentUserProvider)!);
      return true;
    });
    if (ok == true && mounted) _reload();
  }

  void _reload() => setState(() {
        _detail = _load();
      });

  Future<void> _cancel(PurchaseInvoiceDetail d) async {
    final reason = await askReason(context, title: '${Strings.cancelInvoice} ${d.invoice.number}');
    if (reason == null || !mounted) return;
    final ok = await runGuarded(context, () async {
      await ref.read(purchaseServiceProvider).cancel(d.invoice.id, reason: reason, user: ref.read(currentUserProvider)!);
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
    final owner = ref.watch(currentUserProvider)?.isAdmin ?? false;
    return FutureBuilder<(PurchaseInvoiceDetail, List<Payment>, List<AllocationRow>, AdvanceBalance)>(
      future: _detail,
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('${snap.error}'));
        final data = snap.data;
        if (data == null) return const Center(child: CircularProgressIndicator());
        final (d, payments, allocations, advanceBalance) = data;
        final activeAllocations = allocations.where((a) => a.active).toList();
        final inv = d.invoice;
        final cancelled = inv.status == DocStatus.cancelled;
        final remaining = inv.total - d.paid;
        final overdue = !cancelled && remaining > 0 && inv.dueDate != null && inv.dueDate!.isBefore(DateTime.now());
        return DocumentView(
          backLabel: Strings.purchases,
          backPath: '/purchases',
          kind: Strings.purchaseInvoice,
          number: inv.number,
          cancelled: cancelled,
          steps: [overdue ? 'متأخرة' : 'مستلمة', 'مدفوعة جزئياً', 'مدفوعة'],
          step: remaining <= 0 ? 2 : (d.paid > 0 ? 1 : 0),
          partyLabel: Strings.supplier,
          partyName: d.supplier.name,
          partyPath: '/suppliers/${d.supplier.id}',
          partyDetail: d.supplier.phone,
          facts: [
            (Strings.date, formatDateTime(inv.date)),
            if (inv.supplierInvoiceNo != null) (Strings.supplierInvoiceNo, inv.supplierInvoiceNo!),
            if (inv.dueDate != null) ('يستحق الباقي', formatDate(inv.dueDate!)),
            if (activeAllocations.isNotEmpty)
              (
                'من الدفعات المقدمة',
                activeAllocations.map((a) => '${a.advanceNumber}: ${formatMoney(a.allocation.amount)}').join(' · ')
              ),
          ],
          columns: const [
            DocColumn('#'),
            DocColumn(Strings.productName, flex: 5),
            DocColumn(Strings.qty, flex: 2, numeric: true),
            DocColumn('سعر القائمة', flex: 2, numeric: true),
            DocColumn('الخصم', flex: 2, numeric: true),
            DocColumn(Strings.unitCost, flex: 2, numeric: true),
            DocColumn(Strings.lineTotal, flex: 2, numeric: true),
            DocColumn('التكلفة في المخزون', flex: 2, numeric: true),
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
                Text(d.lines[i].item.listPrice == null ? '—' : formatMoney(d.lines[i].item.listPrice!)),
                Text(d.lines[i].item.listPrice == null
                    ? '—'
                    : _pct(d.lines[i].item.baseDiscountBp, d.lines[i].item.extraDiscountBp)),
                Text(formatMoney(d.lines[i].item.unitCost)),
                Text(formatMoney(d.lines[i].item.lineTotal), style: const TextStyle(fontWeight: FontWeight.w700)),
                // Net of the invoice discount, plus its share of the transport.
                Text(formatMoney(
                    ((d.lines[i].item.netTotal + d.lines[i].item.extraCostShare) * qtyScale / d.lines[i].item.qty)
                        .round())),
              ],
          ],
          totals: [
            (Strings.subtotal, inv.subtotal, false),
            if (inv.discount != 0)
              (
                inv.discountBp == null
                    ? '${Strings.invoiceDiscount} (مبلغ)'
                    : '${Strings.invoiceDiscount} (${(inv.discountBp! / 100).toStringAsFixed(inv.discountBp! % 100 == 0 ? 0 : 2)}%)',
                inv.discount,
                false
              ),
            if (inv.extraCosts != 0)
              (inv.extraCostsOnSupplier ? 'نقل وتحميل (على المورد)' : 'نقل وتحميل (لجهة أخرى، خارج الإجمالي)',
                  inv.extraCosts, false),
            (Strings.total, inv.total, true),
            if (inv.advanceUsed != 0) ('منها من الدفعات المقدمة', inv.advanceUsed, false),
            (Strings.paid, d.paid, false),
            (Strings.remaining, cancelled ? 0 : remaining, true),
          ],
          notes: inv.notes,
          payments: [for (final p in payments) PaymentLine.of(p, paymentMethodLabel(p.method))],
          actions: [
            if (!cancelled && remaining > 0)
              FilledButton.icon(
                onPressed: () => _pay(d),
                icon: const Icon(Icons.payments_outlined),
                label: const Text(Strings.payToSupplier),
              ),
            if (!cancelled && remaining > 0 && advanceBalance.remaining > 0)
              FilledButton.tonalIcon(
                onPressed: () => _fromAdvance(d, advanceBalance),
                icon: const Icon(Icons.account_balance_wallet_outlined),
                label: Text('خصم من الدفعات المقدمة (${formatMoney(advanceBalance.remaining)})'),
              ),
            if (!cancelled && owner && !inv.isDirect)
              OutlinedButton.icon(
                onPressed: () => context.go('/purchases/new?correct=${inv.id}'),
                icon: const Icon(Icons.edit_note),
                label: const Text('تصحيح الفاتورة'),
              ),
            if (!cancelled && owner && inv.advanceUsed > 0)
              OutlinedButton.icon(
                onPressed: () => _correctAdvance(d),
                icon: const Icon(Icons.tune),
                label: const Text('تصحيح المخصوم من الدفعات'),
              ),
            if (!cancelled)
              OutlinedButton.icon(
                onPressed: () => context.go('/returns/new?kind=purchase&invoice=${inv.id}'),
                icon: const Icon(Icons.assignment_return_outlined),
                label: const Text(Strings.purchaseReturn),
              ),
            OutlinedButton.icon(
              onPressed: () => printPurchaseInvoice(context, ref, inv.id),
              icon: const Icon(Icons.print_outlined),
              label: const Text(Strings.print),
            ),
            if (!cancelled)
              OutlinedButton.icon(
                onPressed: () => _cancel(d),
                icon: const Icon(Icons.block),
                label: const Text(Strings.cancelInvoice),
                style: OutlinedButton.styleFrom(foregroundColor: theme.colorScheme.error),
              ),
          ],
        );
      },
    );
  }
}
