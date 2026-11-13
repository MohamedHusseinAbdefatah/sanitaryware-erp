import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/dates.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/search_text.dart';
import '../../core/services/purchase_order_service.dart';
import '../../core/services/sales_order_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/list_kit.dart';
import '../purchases/purchase_orders_dialog.dart';
import 'sales_orders_dialog.dart';

final _salesOrdersProvider =
    StreamProvider.autoDispose<List<SoDetail>>((ref) => ref.watch(salesOrderServiceProvider).watchAll());
final _purchaseOrdersProvider =
    StreamProvider.autoDispose<List<PoDetail>>((ref) => ref.watch(purchaseOrderServiceProvider).watchAll());

Widget soPill(String s) => switch (s) {
      SoStatus.delivered => StatusPill.good(soStatusLabel(s)),
      SoStatus.cancelled => StatusPill.bad(soStatusLabel(s)),
      SoStatus.draft || SoStatus.quotation => StatusPill.warn(soStatusLabel(s)),
      _ => StatusPill(soStatusLabel(s)),
    };

Widget poPill(String s) => switch (s) {
      PoStatus.received => StatusPill.good(poStatusLabel(s)),
      PoStatus.cancelled => StatusPill.bad(poStatusLabel(s)),
      PoStatus.draft => StatusPill.warn(poStatusLabel(s)),
      _ => StatusPill(poStatusLabel(s)),
    };

/// Quotations and sales orders: what is open and still to deliver, by stage.
class SalesOrdersScreen extends ConsumerStatefulWidget {
  const SalesOrdersScreen({super.key});

  @override
  ConsumerState<SalesOrdersScreen> createState() => _SalesOrdersScreenState();
}

class _SalesOrdersScreenState extends ConsumerState<SalesOrdersScreen> {
  String _search = '';
  String? _status;

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(_salesOrdersProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'أوامر البيع وعروض الأسعار',
          actions: [
            TextButton.icon(
              onPressed: () => context.go('/sales'),
              icon: const Icon(Icons.arrow_forward),
              label: const Text(Strings.sales),
            ),
            SearchBox(hint: 'بحث برقم الأمر أو العميل', onChanged: (v) => setState(() => _search = v)),
            OutlinedButton.icon(
              onPressed: () => showNewSalesOrder(context, quotation: true),
              icon: const Icon(Icons.request_quote_outlined),
              label: const Text('عرض سعر جديد'),
            ),
            FilledButton.icon(
              onPressed: () => showNewSalesOrder(context),
              icon: const Icon(Icons.add),
              label: const Text('أمر جديد'),
            ),
          ],
        ),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (all) {
              final searched = all.where((o) => matchesSearch(_search, [o.order.number, o.customerName])).toList();
              int count(String s) => searched.where((o) => o.order.status == s).length;
              final shown = _status == null ? searched : searched.where((o) => o.order.status == _status).toList();
              final open = searched.where((o) =>
                  o.order.status == SoStatus.confirmed || o.order.status == SoStatus.partlyDelivered);
              final toDeliver = open.fold(0, (s, o) => s + o.remainingValue);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SummaryStrip(items: [
                    SummaryItem('أوامر مفتوحة', '${open.length}', icon: Icons.assignment_outlined),
                    SummaryItem('قيمة لم تُسلّم', formatMoney(toDeliver),
                        icon: Icons.local_shipping_outlined, tone: toDeliver > 0 ? AppColors.warn : null),
                    SummaryItem('عروض أسعار', '${count(SoStatus.quotation)}', icon: Icons.request_quote_outlined),
                    SummaryItem('مسودات', '${count(SoStatus.draft)}', icon: Icons.edit_note),
                    SummaryItem('تم تسليمها', '${count(SoStatus.delivered)}', icon: Icons.done_all, tone: AppColors.good),
                  ]),
                  CountChips<String?>(
                    selected: _status,
                    onSelected: (v) => setState(() => _status = v),
                    options: [
                      (null, Strings.all, searched.length),
                      for (final s in [
                        SoStatus.quotation,
                        SoStatus.draft,
                        SoStatus.confirmed,
                        SoStatus.partlyDelivered,
                        SoStatus.delivered,
                        SoStatus.cancelled,
                      ])
                        (s, soStatusLabel(s), count(s)),
                    ],
                  ),
                  Expanded(
                    child: DataList<SoDetail>(
                      rows: shown,
                      emptyText: 'لا توجد أوامر بيع',
                      onTap: (o) => showSalesOrder(context, o.order.id),
                      rowColor: (o) => o.order.status == SoStatus.cancelled ? AppColors.canvas : null,
                      columns: [
                        DataListColumn('الرقم', flex: 2,
                            (o) => Text(o.order.number, style: const TextStyle(fontWeight: FontWeight.w700))),
                        DataListColumn(Strings.date, flex: 2, (o) => Text(formatDate(o.order.orderDate))),
                        DataListColumn(Strings.customer, flex: 3, (o) => InkWell(
                              onTap: () => context.go('/customers/${o.order.customerId}'),
                              child: Text(o.customerName,
                                  style: const TextStyle(color: AppColors.brand, fontWeight: FontWeight.w600)),
                            )),
                        DataListColumn('القناة', flex: 2, (o) => Text(SaleChannel.label(o.order.channel))),
                        DataListColumn('المطلوب', flex: 2, numeric: true, (o) => Text(formatMoney(o.orderedValue))),
                        DataListColumn('المسلّم', flex: 2, numeric: true, (o) => Text(formatMoney(o.deliveredValue))),
                        DataListColumn('المتبقي', flex: 2, numeric: true, (o) => Text(formatMoney(o.remainingValue),
                            style: o.remainingValue > 0 ? const TextStyle(fontWeight: FontWeight.w700) : null)),
                        DataListColumn(Strings.status, flex: 2, numeric: true, (o) => soPill(o.order.status)),
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

/// Purchase orders: what is open and still to receive, by stage.
class PurchaseOrdersScreen extends ConsumerStatefulWidget {
  const PurchaseOrdersScreen({super.key});

  @override
  ConsumerState<PurchaseOrdersScreen> createState() => _PurchaseOrdersScreenState();
}

class _PurchaseOrdersScreenState extends ConsumerState<PurchaseOrdersScreen> {
  String _search = '';
  String? _status;

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(_purchaseOrdersProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'أوامر الشراء',
          actions: [
            TextButton.icon(
              onPressed: () => context.go('/purchases'),
              icon: const Icon(Icons.arrow_forward),
              label: const Text(Strings.purchases),
            ),
            SearchBox(hint: 'بحث برقم الأمر أو المورد', onChanged: (v) => setState(() => _search = v)),
            FilledButton.icon(
              onPressed: () => showNewPurchaseOrder(context),
              icon: const Icon(Icons.add),
              label: const Text('أمر شراء جديد'),
            ),
          ],
        ),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (all) {
              final searched = all.where((o) => matchesSearch(_search, [o.order.number, o.supplierName])).toList();
              int count(String s) => searched.where((o) => o.order.status == s).length;
              final shown = _status == null ? searched : searched.where((o) => o.order.status == _status).toList();
              final open = searched.where((o) =>
                  o.order.status == PoStatus.approved || o.order.status == PoStatus.partlyReceived);
              final toReceive = open.fold(0, (s, o) => s + o.remainingValue);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SummaryStrip(items: [
                    SummaryItem('أوامر تنتظر الاستلام', '${open.length}', icon: Icons.assignment_outlined),
                    SummaryItem('قيمة لم تُستلم', formatMoney(toReceive),
                        icon: Icons.inventory_outlined, tone: toReceive > 0 ? AppColors.warn : null),
                    SummaryItem('مسودات تحتاج اعتماد', '${count(PoStatus.draft)}',
                        icon: Icons.edit_note, tone: count(PoStatus.draft) > 0 ? AppColors.warn : null),
                    SummaryItem('تم استلامها', '${count(PoStatus.received)}', icon: Icons.done_all, tone: AppColors.good),
                  ]),
                  CountChips<String?>(
                    selected: _status,
                    onSelected: (v) => setState(() => _status = v),
                    options: [
                      (null, Strings.all, searched.length),
                      for (final s in [
                        PoStatus.draft,
                        PoStatus.approved,
                        PoStatus.partlyReceived,
                        PoStatus.received,
                        PoStatus.cancelled,
                      ])
                        (s, poStatusLabel(s), count(s)),
                    ],
                  ),
                  Expanded(
                    child: DataList<PoDetail>(
                      rows: shown,
                      emptyText: 'لا توجد أوامر شراء',
                      onTap: (o) => showPurchaseOrder(context, o.order.id),
                      rowColor: (o) => o.order.status == PoStatus.cancelled ? AppColors.canvas : null,
                      columns: [
                        DataListColumn('الرقم', flex: 2,
                            (o) => Text(o.order.number, style: const TextStyle(fontWeight: FontWeight.w700))),
                        DataListColumn(Strings.date, flex: 2, (o) => Text(formatDate(o.order.orderDate))),
                        DataListColumn(Strings.supplier, flex: 3, (o) => InkWell(
                              onTap: () => context.go('/suppliers/${o.order.supplierId}'),
                              child: Text(o.supplierName,
                                  style: const TextStyle(color: AppColors.brand, fontWeight: FontWeight.w600)),
                            )),
                        DataListColumn('متوقع', flex: 2,
                            (o) => Text(o.order.expectedDate == null ? '' : formatDate(o.order.expectedDate!))),
                        DataListColumn('المطلوب', flex: 2, numeric: true, (o) => Text(formatMoney(o.orderedValue))),
                        DataListColumn('المستلم', flex: 2, numeric: true, (o) => Text(formatMoney(o.receivedValue))),
                        DataListColumn('المتبقي', flex: 2, numeric: true, (o) => Text(formatMoney(o.remainingValue),
                            style: o.remainingValue > 0 ? const TextStyle(fontWeight: FontWeight.w700) : null)),
                        DataListColumn(Strings.status, flex: 2, numeric: true, (o) => poPill(o.order.status)),
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
