import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/quantity.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/profile_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../payments/payments_screen.dart';

/// The status of an invoice as a coloured label.
Widget invoiceStatus(InvoiceSummary i) {
  if (i.cancelled) return const StatusPill.bad('ملغاة');
  if (i.remaining <= 0) return const StatusPill.good('مدفوعة');
  if (i.dueDate != null && i.dueDate!.isBefore(DateTime.now())) return const StatusPill.bad('متأخرة');
  if (i.paid > 0) return const StatusPill.warn('مدفوعة جزئياً');
  return const StatusPill('غير مدفوعة');
}

/// A party's invoices; a click opens the invoice.
class InvoicesTab extends StatelessWidget {
  const InvoicesTab({super.key, required this.invoices, required this.basePath, this.showSupplierNo = false});

  final List<InvoiceSummary> invoices;
  final String basePath;
  final bool showSupplierNo;

  @override
  Widget build(BuildContext context) {
    return DataList<InvoiceSummary>(
      rows: invoices,
      emptyText: 'لا توجد فواتير',
      onTap: (i) => context.go('$basePath/${i.id}'),
      rowColor: (i) => i.cancelled ? AppColors.canvas : null,
      columns: [
        DataListColumn('الرقم', flex: 2, (i) => Text(i.number)),
        DataListColumn(Strings.date, flex: 2, (i) => Text(formatDate(i.date))),
        if (showSupplierNo) DataListColumn('رقم فاتورة المورد', flex: 2, (i) => Text(i.extra ?? '')),
        DataListColumn(Strings.total, flex: 2, numeric: true, (i) => Text(formatMoney(i.total))),
        DataListColumn(Strings.paid, flex: 2, numeric: true, (i) => Text(formatMoney(i.paid))),
        DataListColumn(Strings.remaining, flex: 2, numeric: true,
            (i) => Text(formatMoney(i.remaining), style: i.remaining > 0 ? const TextStyle(fontWeight: FontWeight.w700) : null)),
        DataListColumn('الاستحقاق', flex: 2, (i) => Text(i.dueDate == null ? '' : formatDate(i.dueDate!))),
        DataListColumn(Strings.status, flex: 2, numeric: true, invoiceStatus),
      ],
    );
  }
}

/// A party's payments, with the cheque state for a cheque.
class PaymentsTab extends StatelessWidget {
  const PaymentsTab({super.key, required this.payments});

  final List<PaymentSummary> payments;

  @override
  Widget build(BuildContext context) {
    return DataList<PaymentSummary>(
      rows: payments,
      emptyText: 'لا توجد مدفوعات',
      rowColor: (p) => p.payment.status == DocStatus.cancelled ? AppColors.canvas : null,
      columns: [
        DataListColumn('الرقم', flex: 2, (p) => Text(p.payment.number)),
        DataListColumn(Strings.date, flex: 2, (p) => Text(formatDate(p.payment.date))),
        DataListColumn('الطريقة', flex: 2, (p) => Text(paymentMethodLabel(p.payment.method))),
        DataListColumn('الشيك', flex: 3, (p) => Text(p.cheque == null
            ? ''
            : '${p.cheque!.chequeNo} · ${formatDate(p.cheque!.dueDate)} · ${chequeStatusLabel(p.cheque!.status)}')),
        DataListColumn('على', flex: 3, (p) => Text(_ref(p.payment))),
        DataListColumn('المبلغ', flex: 2, numeric: true,
            (p) => Text(formatMoney(p.payment.amount), style: const TextStyle(fontWeight: FontWeight.w700))),
        DataListColumn(Strings.status, flex: 2, numeric: true,
            (p) => p.payment.status == DocStatus.cancelled ? const StatusPill.bad('ملغاة') : const StatusPill.good('سارية')),
      ],
    );
  }

  static String _ref(Payment p) => switch (p.invoiceRefType) {
        RefType.salesInvoice || RefType.purchaseInvoice => 'فاتورة',
        RefType.returnDoc => 'مرتجع',
        RefType.supplierAdvance => 'دفعة مقدمة بسعر قائمة',
        RefType.purchaseOrder => 'مقدم أمر شراء',
        RefType.salesOrder => 'مقدم أمر بيع',
        _ => 'تحت الحساب',
      };
}

class ReturnsTab extends StatelessWidget {
  const ReturnsTab({super.key, required this.returns});

  final List<ReturnDoc> returns;

  @override
  Widget build(BuildContext context) {
    return DataList<ReturnDoc>(
      rows: returns,
      emptyText: 'لا توجد مرتجعات',
      rowColor: (r) => r.status == DocStatus.cancelled ? AppColors.canvas : null,
      columns: [
        DataListColumn('الرقم', flex: 2, (r) => Text(r.number)),
        DataListColumn(Strings.date, flex: 2, (r) => Text(formatDate(r.date))),
        DataListColumn(Strings.total, flex: 2, numeric: true, (r) => Text(formatMoney(r.total))),
        DataListColumn('المردود نقداً', flex: 2, numeric: true, (r) => Text(formatMoney(r.refundAmount))),
        DataListColumn(Strings.notes, flex: 4, (r) => Text(r.notes ?? '', overflow: TextOverflow.ellipsis)),
        DataListColumn(Strings.status, flex: 2, numeric: true,
            (r) => r.status == DocStatus.cancelled ? const StatusPill.bad('ملغى') : const StatusPill.good('ساري')),
      ],
    );
  }
}

/// What a party bought or sold most, by value; a click opens the product.
class TopProductsTab extends StatelessWidget {
  const TopProductsTab({super.key, required this.products});

  final List<ProductTotal> products;

  @override
  Widget build(BuildContext context) {
    final top = products.isEmpty ? 1 : products.first.value;
    return DataList<ProductTotal>(
      rows: products,
      emptyText: 'لا توجد أصناف بعد',
      onTap: (p) => context.go('/products/${p.productId}'),
      columns: [
        DataListColumn(Strings.productName, flex: 5, (p) => Text(p.name)),
        DataListColumn(Strings.qty, flex: 2, numeric: true, (p) => Text(formatQty(p.qty))),
        DataListColumn('القيمة', flex: 2, numeric: true, (p) => Text(formatMoney(p.value))),
        DataListColumn('', flex: 4, (p) => ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: top == 0 ? 0 : p.value / top,
                minHeight: 8,
                backgroundColor: AppColors.canvas,
              ),
            )),
      ],
    );
  }
}
