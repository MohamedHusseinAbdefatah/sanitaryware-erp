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
import '../../core/services/doc_types.dart';
import '../../core/services/profile_service.dart';
import '../../core/services/reservation_service.dart';
import '../../core/services/sales_order_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/record_page.dart';
import '../payments/payment_dialog.dart';
import '../sales/sales_orders_dialog.dart';
import 'party_form_dialog.dart';
import 'party_tabs.dart';
import 'statement_dialog.dart';

final customerProfileProvider = FutureProvider.autoDispose.family<CustomerProfile, int>(
    (ref, id) => ProfileService(ref.watch(databaseProvider)).customer(id));

String _pct(int bp) => '${(bp / 100).toStringAsFixed(bp % 100 == 0 ? 0 : 1)}%';

/// One customer: what they owe, their category and credit, every invoice,
/// payment, order, return and reservation, and what they buy most.
class CustomerPage extends ConsumerWidget {
  const CustomerPage({super.key, required this.customerId});

  final int customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(customerProfileProvider(customerId));
    final isAdmin = ref.watch(currentUserProvider)?.seesCost ?? false;
    void refresh() => ref.invalidate(customerProfileProvider(customerId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (p) {
        final c = p.customer;
        final limit = c.creditLimit;
        final over = limit > 0 && p.balance > limit;
        return RecordPage(
          backLabel: Strings.customers,
          backPath: '/customers',
          title: c.name,
          subtitle: [if (c.phone != null) c.phone!, if (c.address != null) c.address!].join('  ·  '),
          leading: InitialsAvatar(c.name),
          onRefresh: refresh,
          pills: [
            if (!c.isActive) const StatusPill.bad('موقوف') else const StatusPill.good('نشط'),
            StatusPill(p.categoryName),
            if (c.discountBp > 0) StatusPill('خصم إضافي ${_pct(c.discountBp)}'),
            if (over) const StatusPill.bad('تجاوز حد الائتمان'),
          ],
          actions: [
            FilledButton.icon(
              onPressed: () => context.go('/sales/new?customer=${c.id}'),
              icon: const Icon(Icons.point_of_sale),
              label: const Text('فاتورة بيع'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                if (await showPaymentDialog(context, partyType: PartyType.customer, partyId: c.id)) refresh();
              },
              icon: const Icon(Icons.payments_outlined),
              label: const Text(Strings.receivePayment),
            ),
            OutlinedButton.icon(
              onPressed: () => showStatement(context, partyType: PartyType.customer, partyId: c.id),
              icon: const Icon(Icons.receipt_long_outlined),
              label: const Text(Strings.statement),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                await showCustomerForm(context, existing: c);
                refresh();
              },
              icon: const Icon(Icons.edit_outlined),
              label: const Text(Strings.edit),
            ),
          ],
          stats: [
            StatTile('الرصيد', formatMoney(p.balance),
                icon: Icons.account_balance_wallet_outlined,
                hint: p.balance > 0 ? 'مستحق على العميل' : (p.balance < 0 ? 'رصيد له عندنا' : 'لا يوجد رصيد'),
                tone: p.balance > 0 ? AppColors.warn : (p.balance < 0 ? AppColors.good : null)),
            StatTile('حد الائتمان', limit == 0 ? 'بدون حد' : formatMoney(limit),
                icon: Icons.credit_score_outlined,
                hint: limit == 0 ? null : 'المتاح ${formatMoney(limit - p.balance)}',
                tone: over ? AppColors.bad : null),
            StatTile('إجمالي المشتريات', formatMoney(p.invoicedTotal),
                icon: Icons.receipt_long_outlined, hint: '${p.active.length} فاتورة'),
            StatTile('المدفوع', formatMoney(p.paidTotal), icon: Icons.payments_outlined),
            StatTile('فواتير مفتوحة', '${p.open.length}',
                icon: Icons.pending_actions_outlined,
                hint: formatMoney(p.open.fold(0, (sum, i) => sum + i.remaining)),
                tone: p.open.isEmpty ? null : AppColors.warn),
            StatTile('آخر شراء', p.lastInvoice == null ? '—' : formatDate(p.lastInvoice!), icon: Icons.event_outlined),
          ],
          tabs: [
            RecordTab('فواتير البيع', InvoicesTab(invoices: p.invoices, basePath: '/sales'),
                count: p.invoices.length, icon: Icons.receipt_long_outlined),
            RecordTab('المدفوعات', PaymentsTab(payments: p.payments), count: p.payments.length, icon: Icons.payments_outlined),
            RecordTab('أوامر البيع', _OrdersTab(orders: p.orders, onChanged: refresh),
                count: p.orders.length, icon: Icons.assignment_outlined),
            RecordTab('الحجوزات', _ReservationsTab(rows: p.reservations),
                count: p.reservations.length, icon: Icons.bookmark_outline),
            RecordTab('المرتجعات', ReturnsTab(returns: p.returns), count: p.returns.length, icon: Icons.assignment_return_outlined),
            RecordTab('أكثر الأصناف', TopProductsTab(products: p.topProducts), icon: Icons.leaderboard_outlined),
            RecordTab('البيانات', RecordDetails(rows: [
              (Strings.name, c.name),
              (Strings.phone, c.phone ?? ''),
              (Strings.address, c.address ?? ''),
              ('الفئة', p.categoryName),
              ('خصم إضافي لهذا العميل', c.discountBp == 0 ? '' : _pct(c.discountBp)),
              if (isAdmin) ('حد الائتمان', limit == 0 ? 'بدون حد' : formatMoney(limit)),
              if (isAdmin) ('رصيد أول المدة', formatMoney(c.openingBalance)),
              (Strings.notes, c.notes ?? ''),
            ]), icon: Icons.info_outline),
          ],
        );
      },
    );
  }
}

class _OrdersTab extends StatelessWidget {
  const _OrdersTab({required this.orders, required this.onChanged});

  final List<SoDetail> orders;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return DataList<SoDetail>(
      rows: orders,
      emptyText: 'لا توجد أوامر بيع',
      onTap: (o) async {
        await showSalesOrder(context, o.order.id);
        onChanged();
      },
      columns: [
        DataListColumn('الرقم', flex: 2, (o) => Text(o.order.number)),
        DataListColumn(Strings.date, flex: 2, (o) => Text(formatDate(o.order.orderDate))),
        DataListColumn('القناة', flex: 2, (o) => Text(SaleChannel.label(o.order.channel))),
        DataListColumn('المطلوب', flex: 2, numeric: true, (o) => Text(formatMoney(o.orderedValue))),
        DataListColumn('المسلّم', flex: 2, numeric: true, (o) => Text(formatMoney(o.deliveredValue))),
        DataListColumn('المتبقي', flex: 2, numeric: true, (o) => Text(formatMoney(o.remainingValue))),
        DataListColumn(Strings.status, flex: 2, numeric: true, (o) => switch (o.order.status) {
              SoStatus.delivered => StatusPill.good(soStatusLabel(o.order.status)),
              SoStatus.cancelled => StatusPill.bad(soStatusLabel(o.order.status)),
              SoStatus.draft || SoStatus.quotation => StatusPill.warn(soStatusLabel(o.order.status)),
              _ => StatusPill(soStatusLabel(o.order.status)),
            }),
      ],
    );
  }
}

class _ReservationsTab extends StatelessWidget {
  const _ReservationsTab({required this.rows});

  final List<ReservationRow> rows;

  @override
  Widget build(BuildContext context) {
    return DataList<ReservationRow>(
      rows: rows,
      emptyText: 'لا يوجد مخزون محجوز لهذا العميل',
      onTap: (r) => context.go('/products/${r.reservation.productId}'),
      columns: [
        DataListColumn(Strings.productName, flex: 5, (r) => Text(r.productName)),
        DataListColumn(Strings.qty, flex: 2, numeric: true, (r) => Text(formatQty(r.reservation.qty))),
        DataListColumn('أمر البيع', flex: 2, (r) => Text(r.orderNumber ?? '')),
        DataListColumn(Strings.date, flex: 2, (r) => Text(formatDate(r.reservation.createdAt))),
      ],
    );
  }
}
