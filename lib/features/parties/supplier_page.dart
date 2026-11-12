import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/dates.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/services/buying_policy_service.dart';
import '../../core/services/doc_types.dart';
import '../../core/services/profile_service.dart';
import '../../core/services/purchase_order_service.dart';
import '../../core/services/supplier_advance_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/record_page.dart';
import '../payments/payment_dialog.dart';
import '../purchases/purchase_orders_dialog.dart';
import '../purchases/supplier_advances_dialog.dart';
import 'party_form_dialog.dart';
import 'party_tabs.dart';
import 'statement_dialog.dart';

final supplierProfileProvider = FutureProvider.autoDispose.family<SupplierProfile, int>(
    (ref, id) => ProfileService(ref.watch(databaseProvider)).supplier(id));

String _pct(int bp) => '${(bp / 100).toStringAsFixed(bp % 100 == 0 ? 0 : 1)}%';

/// One supplier: what we owe, every purchase, payment, order, return and
/// advance, the products bought most and the agreed discounts.
class SupplierPage extends ConsumerWidget {
  const SupplierPage({super.key, required this.supplierId});

  final int supplierId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(supplierProfileProvider(supplierId));
    void refresh() => ref.invalidate(supplierProfileProvider(supplierId));
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (p) {
        final s = p.supplier;
        final advancesLeft = p.advances.where((a) => a.open).fold(0, (sum, a) => sum + a.remaining);
        return RecordPage(
          backLabel: Strings.suppliers,
          backPath: '/suppliers',
          title: s.name,
          subtitle: [if (s.phone != null) s.phone!, if (s.address != null) s.address!].join('  ·  '),
          leading: InitialsAvatar(s.name),
          onRefresh: refresh,
          pills: [
            if (!s.isActive) const StatusPill.bad('موقوف') else const StatusPill.good('نشط'),
            if (p.balance > 0) StatusPill.warn('له علينا ${formatMoney(p.balance)}'),
            if (p.balance < 0) StatusPill('لنا عنده ${formatMoney(-p.balance)}'),
            if (p.overdue > 0) StatusPill.bad('متأخر ${formatMoney(p.overdue)}'),
          ],
          actions: [
            FilledButton.icon(
              onPressed: () => context.go('/purchases/new?supplier=${s.id}'),
              icon: const Icon(Icons.add_shopping_cart),
              label: const Text('فاتورة شراء'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                if (await showPaymentDialog(context, partyType: PartyType.supplier, partyId: s.id)) refresh();
              },
              icon: const Icon(Icons.payments_outlined),
              label: const Text('دفع للمورد'),
            ),
            OutlinedButton.icon(
              onPressed: () => showStatement(context, partyType: PartyType.supplier, partyId: s.id),
              icon: const Icon(Icons.receipt_long_outlined),
              label: const Text(Strings.statement),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                await showSupplierAdvances(context, s);
                refresh();
              },
              icon: const Icon(Icons.lock_clock_outlined),
              label: const Text('دفعة مقدمة'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                await showSupplierForm(context, existing: s);
                refresh();
              },
              icon: const Icon(Icons.edit_outlined),
              label: const Text(Strings.edit),
            ),
          ],
          stats: [
            StatTile('الرصيد', formatMoney(p.balance),
                icon: Icons.account_balance_wallet_outlined,
                hint: p.balance > 0 ? 'مستحق للمورد' : (p.balance < 0 ? 'رصيد لنا عنده' : 'لا يوجد رصيد'),
                tone: p.balance > 0 ? AppColors.warn : (p.balance < 0 ? AppColors.good : null)),
            StatTile('إجمالي المشتريات', formatMoney(p.invoicedTotal),
                icon: Icons.shopping_cart_outlined, hint: '${p.active.length} فاتورة'),
            StatTile('المدفوع له', formatMoney(p.paidTotal), icon: Icons.payments_outlined),
            StatTile('فواتير مفتوحة', '${p.open.length}',
                icon: Icons.pending_actions_outlined,
                hint: formatMoney(p.open.fold(0, (sum, i) => sum + i.remaining)),
                tone: p.open.isEmpty ? null : AppColors.warn),
            StatTile('دفعات مقدمة متبقية', formatMoney(advancesLeft), icon: Icons.lock_clock_outlined),
            StatTile('آخر شراء', p.lastInvoice == null ? '—' : formatDate(p.lastInvoice!), icon: Icons.event_outlined),
          ],
          tabs: [
            RecordTab('فواتير الشراء', InvoicesTab(invoices: p.invoices, basePath: '/purchases', showSupplierNo: true),
                count: p.invoices.length, icon: Icons.receipt_long_outlined),
            RecordTab('المدفوعات', PaymentsTab(payments: p.payments), count: p.payments.length, icon: Icons.payments_outlined),
            RecordTab('أوامر الشراء', _OrdersTab(orders: p.orders, onChanged: refresh),
                count: p.orders.length, icon: Icons.assignment_outlined),
            RecordTab('الدفعات المقدمة', _AdvancesTab(advances: p.advances),
                count: p.advances.length, icon: Icons.lock_clock_outlined),
            RecordTab('المرتجعات', ReturnsTab(returns: p.returns), count: p.returns.length, icon: Icons.assignment_return_outlined),
            RecordTab('أكثر الأصناف', TopProductsTab(products: p.topProducts), icon: Icons.leaderboard_outlined),
            RecordTab('الخصومات المتفق عليها', _PoliciesTab(policies: p.policies),
                count: p.policies.length, icon: Icons.percent),
            RecordTab('البيانات', _Details(rows: [
              (Strings.name, s.name),
              (Strings.phone, s.phone ?? ''),
              (Strings.address, s.address ?? ''),
              ('رصيد أول المدة', formatMoney(s.openingBalance)),
              (Strings.notes, s.notes ?? ''),
            ]), icon: Icons.info_outline),
          ],
        );
      },
    );
  }
}

class _OrdersTab extends StatelessWidget {
  const _OrdersTab({required this.orders, required this.onChanged});

  final List<PoDetail> orders;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return DataList<PoDetail>(
      rows: orders,
      emptyText: 'لا توجد أوامر شراء',
      onTap: (o) async {
        await showPurchaseOrder(context, o.order.id);
        onChanged();
      },
      columns: [
        DataListColumn('الرقم', flex: 2, (o) => Text(o.order.number)),
        DataListColumn(Strings.date, flex: 2, (o) => Text(formatDate(o.order.orderDate))),
        DataListColumn('المطلوب', flex: 2, numeric: true, (o) => Text(formatMoney(o.orderedValue))),
        DataListColumn('المستلم', flex: 2, numeric: true, (o) => Text(formatMoney(o.receivedValue))),
        DataListColumn('المتبقي', flex: 2, numeric: true, (o) => Text(formatMoney(o.remainingValue))),
        DataListColumn(Strings.status, flex: 2, numeric: true, (o) => _poPill(o.order.status)),
      ],
    );
  }

  static Widget _poPill(String s) => switch (s) {
        PoStatus.received => StatusPill.good(poStatusLabel(s)),
        PoStatus.cancelled => StatusPill.bad(poStatusLabel(s)),
        PoStatus.draft => StatusPill.warn(poStatusLabel(s)),
        _ => StatusPill(poStatusLabel(s)),
      };
}

class _AdvancesTab extends StatelessWidget {
  const _AdvancesTab({required this.advances});

  final List<AdvanceRow> advances;

  @override
  Widget build(BuildContext context) {
    return DataList<AdvanceRow>(
      rows: advances,
      emptyText: 'لا توجد دفعات مقدمة بسعر قائمة',
      rowColor: (a) => a.advance.status == DocStatus.cancelled ? AppColors.canvas : null,
      columns: [
        DataListColumn('الرقم', flex: 2, (a) => Text(a.advance.number)),
        DataListColumn(Strings.date, flex: 2, (a) => Text(formatDate(a.advance.date))),
        DataListColumn('مثبتة على', flex: 4, (a) => Text(
            a.lists.map((l) => '${l.brandName} PL-${l.list.id} V${l.list.versionNo}').join('، '),
            overflow: TextOverflow.ellipsis)),
        DataListColumn('المبلغ', flex: 2, numeric: true, (a) => Text(formatMoney(a.advance.amount))),
        DataListColumn('المسحوب', flex: 2, numeric: true, (a) => Text(formatMoney(a.used))),
        DataListColumn('المتبقي', flex: 2, numeric: true,
            (a) => Text(formatMoney(a.remaining), style: const TextStyle(fontWeight: FontWeight.w700))),
        DataListColumn(Strings.status, flex: 2, numeric: true, (a) => a.advance.status == DocStatus.cancelled
            ? const StatusPill.bad('ملغاة')
            : (a.remaining > 0 ? const StatusPill.good('متاحة') : const StatusPill('مستهلكة'))),
      ],
    );
  }
}

class _PoliciesTab extends StatelessWidget {
  const _PoliciesTab({required this.policies});

  final List<BuyingPolicyRow> policies;

  @override
  Widget build(BuildContext context) {
    return DataList<BuyingPolicyRow>(
      rows: policies,
      emptyText: 'لا توجد خصومات مسجلة لهذا المورد. تُضاف من قوائم الأسعار ثم سياسات الشراء.',
      rowColor: (r) => r.policy.isActive ? null : AppColors.canvas,
      columns: [
        DataListColumn(Strings.brand, flex: 2, (r) => Text(r.brandName ?? '')),
        DataListColumn('القائمة', flex: 2, (r) => Text(r.listLabel ?? '')),
        DataListColumn('الأصناف', flex: 3, (r) => Text(
            '${PolicyScope.label(r.policy.scope)}${r.targetName.isEmpty ? '' : ' — ${r.targetName}'}')),
        DataListColumn('الخصم', flex: 2, numeric: true, (r) => Text(r.policy.extraDiscountBp == 0
            ? _pct(r.policy.baseDiscountBp)
            : '${_pct(r.policy.baseDiscountBp)} + ${_pct(r.policy.extraDiscountBp)}')),
        DataListColumn(Strings.status, flex: 2, numeric: true,
            (r) => r.policy.isActive ? const StatusPill.good('مفعّلة') : const StatusPill.bad('موقوفة')),
      ],
    );
  }
}

/// A record's plain fields, label beside value.
class _Details extends StatelessWidget {
  const _Details({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) => RecordDetails(rows: rows);
}
