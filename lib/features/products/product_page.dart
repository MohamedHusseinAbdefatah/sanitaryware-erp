import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/pricing_math.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/price_list_service.dart';
import '../../core/services/profile_service.dart';
import '../../core/services/reservation_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/record_page.dart';
import 'product_form_dialog.dart';
import 'product_image.dart';
import 'stock_dialogs.dart';
import 'stock_price_dialog.dart';

final productProfileProvider = FutureProvider.autoDispose.family<ProductProfile, int>(
    (ref, id) => ProfileService(ref.watch(databaseProvider)).product(id));

final _historyProvider = FutureProvider.autoDispose.family<List<PriceHistoryRow>, int>(
    (ref, id) => ref.watch(priceListServiceProvider).history(id));

final _placeNamesProvider = StreamProvider.autoDispose<Map<int, String>>((ref) => ref
    .watch(locationServiceProvider)
    .watchAll()
    .map((all) => {for (final l in all) l.id: l.name}));

/// One product: its photo and stock, where it is, what it costs and sells
/// for, every movement, purchase and sale, its reservations and its prices
/// over time.
class ProductPage extends ConsumerWidget {
  const ProductPage({super.key, required this.productId});

  final int productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(productProfileProvider(productId));
    final user = ref.watch(currentUserProvider);
    final isAdmin = user?.seesCost ?? false;
    final canEdit = user?.can(Perm.catalog) ?? false;
    final canStock = user?.can(Perm.stock) ?? false;
    final hasPhoto = ref.watch(productThumbsProvider).valueOrNull?.containsKey(productId) ?? false;
    void refresh() {
      ref.invalidate(productProfileProvider(productId));
      ref.invalidate(_historyProvider(productId));
    }

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (p) {
        final r = p.row;
        final pr = r.product;
        final unit = r.unitName ?? '';
        final available = r.sellableStock - p.reserved;
        final split = p.byPrice;
        final lastCost = p.purchases.isEmpty ? null : p.purchases.first.unitPrice;
        return RecordPage(
          backLabel: Strings.products,
          backPath: '/products',
          title: pr.nameAr,
          subtitle: 'رقم الصنف ${pr.code}  ·  كود الشركة ${pr.manufacturerCode}'
              '${pr.variant == null ? '' : '  ·  ${pr.variant}'}',
          leading: hasPhoto
              ? SizedBox(width: 72, height: 72, child: ProductThumb(productId: pr.id, size: 72))
              : const InitialsAvatar('', size: 72, icon: Icons.inventory_2_outlined),
          onRefresh: refresh,
          pills: [
            if (!pr.isActive) const StatusPill.bad('موقوف'),
            if (r.brandName != null) StatusPill(r.brandName!),
            if (r.categoryName != null) StatusPill(r.categoryName!),
            if (r.isLowStock) const StatusPill.bad('تحت حد الطلب'),
            if (p.quotes.isEmpty) const StatusPill.warn('بدون سعر معتمد'),
          ],
          actions: [
            if (canEdit)
              FilledButton.icon(
                onPressed: () async {
                  await showProductForm(context, existing: r);
                  refresh();
                },
                icon: const Icon(Icons.edit_outlined),
                label: const Text('تعديل والصورة'),
              ),
            if (canStock)
              OutlinedButton.icon(
                onPressed: () async {
                  await showStockAdjust(context, r);
                  refresh();
                },
                icon: const Icon(Icons.tune),
                label: const Text(Strings.stockAdjust),
              ),
            OutlinedButton.icon(
              onPressed: () => showStockByPrice(context, r),
              icon: const Icon(Icons.price_change_outlined),
              label: const Text('المخزون حسب السعر'),
            ),
          ],
          stats: [
            StatTile('الرصيد', '${formatQty(r.stock)} $unit',
                icon: Icons.inventory_2_outlined, tone: r.isLowStock ? AppColors.bad : null,
                hint: pr.minStock > 0 ? 'حد الطلب ${formatQty(pr.minStock)}' : null),
            StatTile('المتاح للبيع', '${formatQty(available)} $unit',
                icon: Icons.storefront_outlined, hint: p.reserved > 0 ? 'محجوز ${formatQty(p.reserved)}' : 'لا حجوزات'),
            StatTile('جديد / قديم',
                split == null ? '—' : '${formatQty(split.current)} / ${formatQty(split.old)}',
                icon: Icons.compare_arrows,
                hint: split != null && split.unknown != 0 ? 'غير محدد ${formatQty(split.unknown)}' : 'بالسعر الجديد / القديم'),
            StatTile('سعر القائمة',
                p.quotes.isEmpty ? '—' : formatMoney(p.quotes.first.price),
                icon: Icons.sell_outlined,
                hint: p.quotes.isEmpty ? 'لا توجد قائمة سارية' : (p.quotes.length > 1 ? '${p.quotes.length} قوائم سارية' : p.quotes.first.label)),
            if (isAdmin)
              StatTile('آخر تكلفة شراء', lastCost == null ? '—' : formatMoney(lastCost),
                  icon: Icons.local_shipping_outlined,
                  hint: p.purchases.isEmpty ? null : '${p.purchases.first.party} · ${formatDate(p.purchases.first.date)}'),
            StatTile('المباع', '${formatQty(p.soldQty)} $unit', icon: Icons.trending_up, hint: '${p.sales.length} فاتورة'),
          ],
          tabs: [
            RecordTab('الأماكن والأسعار', _StockTab(profile: p), icon: Icons.warehouse_outlined),
            RecordTab('حركة المخزون', _MovementsTab(productId: pr.id), icon: Icons.swap_vert),
            if (isAdmin)
              RecordTab('المشتريات', _MovesTab(moves: p.purchases, basePath: '/purchases', partyLabel: 'المورد', priceLabel: 'التكلفة'),
                  count: p.purchases.length, icon: Icons.shopping_cart_outlined),
            RecordTab('المبيعات', _MovesTab(moves: p.sales, basePath: '/sales', partyLabel: 'العميل', priceLabel: 'السعر'),
                count: p.sales.length, icon: Icons.receipt_long_outlined),
            RecordTab('الحجوزات', _ReservationsTab(rows: p.reservations),
                count: p.reservations.length, icon: Icons.bookmark_outline),
            RecordTab('سجل الأسعار', _HistoryTab(productId: pr.id), icon: Icons.history),
            RecordTab('البيانات', RecordDetails(rows: [
              ('رقم الصنف', pr.code),
              ('كود الشركة', pr.manufacturerCode),
              (Strings.productName, pr.nameAr),
              ('الوصف', pr.description ?? ''),
              (Strings.brand, r.brandName ?? ''),
              (Strings.category, r.categoryName ?? ''),
              ('السلسلة', pr.series ?? ''),
              ('اللون', pr.variant ?? ''),
              ('التشطيب', pr.finish ?? ''),
              ('المقاسات', pr.dimensions ?? ''),
              (Strings.unit, unit),
              ('الباركود', pr.barcode ?? ''),
              ('المواصفات الفنية', pr.technicalSpecs ?? ''),
              ('حد الطلب', pr.minStock == 0 ? '' : formatQty(pr.minStock)),
              (Strings.notes, pr.notes ?? ''),
            ]), icon: Icons.info_outline),
          ],
        );
      },
    );
  }
}

class _StockTab extends StatelessWidget {
  const _StockTab({required this.profile});

  final ProductProfile profile;

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final total = p.places.fold(0, (s, x) => s + x.$2);
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('المخزون حسب المكان', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (p.places.isEmpty) const Text('لا يوجد مخزون', style: TextStyle(color: AppColors.muted)),
                for (final (name, qty) in p.places)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        SizedBox(width: 180, child: Text(name)),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: total <= 0 ? 0 : (qty / total).clamp(0, 1).toDouble(),
                              minHeight: 10,
                              backgroundColor: AppColors.canvas,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 110,
                          child: Text(formatQty(qty), textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('الأسعار السارية اليوم', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (p.quotes.isEmpty)
                  const Text('لا توجد قائمة أسعار سارية لهذا الصنف', style: TextStyle(color: AppColors.muted)),
                for (final q in p.quotes)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Expanded(child: Text(q.label)),
                        Text('${VatStatus.label(q.priceList.vatStatus)}  ',
                            style: const TextStyle(color: AppColors.muted, fontSize: 12)),
                        Text(formatMoney(q.price), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MovementsTab extends ConsumerWidget {
  const _MovementsTab({required this.productId});

  final int productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final places = ref.watch(_placeNamesProvider).valueOrNull ?? const <int, String>{};
    return StreamBuilder<List<StockMovement>>(
      stream: ref.watch(stockServiceProvider).watchMovements(productId),
      builder: (context, snap) {
        final list = snap.data;
        if (list == null) return const Center(child: CircularProgressIndicator());
        // The balance after each movement, worked out oldest first.
        final after = <int, int>{};
        var running = 0;
        for (final m in list.reversed) {
          running += m.qty;
          after[m.id] = running;
        }
        return DataList<StockMovement>(
          rows: list,
          emptyText: Strings.noMovements,
          columns: [
            DataListColumn(Strings.date, flex: 3, (m) => Text(formatDateTime(m.date))),
            DataListColumn(Strings.movementType, flex: 3, (m) => Text(movementTypeLabel(m.type))),
            DataListColumn('المكان', flex: 3, (m) => Text(places[m.locationId] ?? '')),
            DataListColumn(Strings.qty, flex: 2, numeric: true, (m) => Text(
                  m.qty > 0 ? '+${formatQty(m.qty)}' : formatQty(m.qty),
                  textDirection: TextDirection.ltr,
                  style: TextStyle(color: m.qty > 0 ? AppColors.good : AppColors.bad, fontWeight: FontWeight.w700),
                )),
            DataListColumn(Strings.balanceAfter, flex: 2, numeric: true, (m) => Text(formatQty(after[m.id] ?? 0))),
            DataListColumn(Strings.notes, flex: 4, (m) => Text(m.note ?? '', overflow: TextOverflow.ellipsis)),
          ],
        );
      },
    );
  }
}

class _MovesTab extends StatelessWidget {
  const _MovesTab({required this.moves, required this.basePath, required this.partyLabel, required this.priceLabel});

  final List<ProductMove> moves;
  final String basePath;
  final String partyLabel;
  final String priceLabel;

  @override
  Widget build(BuildContext context) {
    return DataList<ProductMove>(
      rows: moves,
      emptyText: 'لا توجد فواتير بعد',
      onTap: (m) => context.go('$basePath/${m.invoiceId}'),
      columns: [
        DataListColumn('الفاتورة', flex: 2, (m) => Text(m.number)),
        DataListColumn(Strings.date, flex: 2, (m) => Text(formatDate(m.date))),
        DataListColumn(partyLabel, flex: 4, (m) => Text(m.party, overflow: TextOverflow.ellipsis)),
        DataListColumn(Strings.qty, flex: 2, numeric: true, (m) => Text(formatQty(m.qty))),
        DataListColumn('سعر القائمة', flex: 2, numeric: true, (m) => Text(m.listPrice == null ? '—' : formatMoney(m.listPrice!))),
        DataListColumn(priceLabel, flex: 2, numeric: true,
            (m) => Text(formatMoney(m.unitPrice), style: const TextStyle(fontWeight: FontWeight.w700))),
        DataListColumn('الإجمالي', flex: 2, numeric: true, (m) => Text(formatMoney(lineAmount(m.qty, m.unitPrice)))),
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
      emptyText: 'لا توجد حجوزات لهذا الصنف',
      onTap: (r) => r.reservation.customerId == null ? null : context.go('/customers/${r.reservation.customerId}'),
      columns: [
        DataListColumn(Strings.customer, flex: 4, (r) => Text(r.customerName ?? '')),
        DataListColumn('أمر البيع', flex: 2, (r) => Text(r.orderNumber ?? '')),
        DataListColumn(Strings.qty, flex: 2, numeric: true, (r) => Text(formatQty(r.reservation.qty))),
        DataListColumn(Strings.date, flex: 2, (r) => Text(formatDate(r.reservation.createdAt))),
      ],
    );
  }
}

class _HistoryTab extends ConsumerWidget {
  const _HistoryTab({required this.productId});

  final int productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(_historyProvider(productId)).valueOrNull;
    if (rows == null) return const Center(child: CircularProgressIndicator());
    return DataList<PriceHistoryRow>(
      rows: rows,
      emptyText: 'لم يظهر الصنف في أي قائمة أسعار بعد',
      columns: [
        DataListColumn('القائمة', flex: 4, (h) => Text('${h.brandName ?? ''} ${h.list.listType} V${h.list.versionNo} (PL-${h.list.id})')),
        DataListColumn('من', flex: 2, (h) => Text(formatDate(h.list.effectiveFrom))),
        DataListColumn('إلى', flex: 2, (h) => Text(h.list.effectiveTo == null ? 'مفتوحة' : formatDate(h.list.effectiveTo!))),
        DataListColumn('اللون', flex: 2, (h) => Text(h.item.variant ?? '')),
        DataListColumn('السعر', flex: 2, numeric: true,
            (h) => Text(h.item.price == null ? '—' : formatMoney(h.item.price!), style: const TextStyle(fontWeight: FontWeight.w700))),
        DataListColumn(Strings.status, flex: 2, numeric: true, (h) => PriceListService.inForce(h.list, DateTime.now())
            ? const StatusPill.good('سارية')
            : StatusPill(h.list.status == PriceListStatus.withdrawn ? 'مسحوبة' : 'منتهية')),
      ],
    );
  }
}
