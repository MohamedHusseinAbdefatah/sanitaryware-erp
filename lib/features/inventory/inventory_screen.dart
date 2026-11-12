import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/inventory_service.dart';
import '../../core/services/stock_price_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/list_kit.dart';
import '../products/locations_dialog.dart';
import 'stock_count_dialog.dart';
import '../products/product_image.dart';
import '../products/products_screen.dart';
import '../products/reservations_dialog.dart';
import '../products/stock_dialogs.dart';
import '../products/stock_price_dialog.dart';

enum _Show { inStock, low, old, unknown, out }

/// What the shop holds: only products that came into stock, never the whole
/// catalogue loaded from the price lists.
class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  String _search = '';
  int? _categoryId;
  int? _brandId;
  _Show _show = _Show.inStock;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final isAdmin = user?.seesCost ?? false;
    final canStock = user?.can(Perm.stock) ?? false;
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const <Category>[];
    final brands = ref.watch(brandsProvider).valueOrNull ?? const <Brand>[];
    final all = ref.watch(_inventoryProvider((search: _search, categoryId: _categoryId, brandId: _brandId)));
    final byPrice = ref.watch(_stockByPriceProvider).valueOrNull ?? const <int, StockPriceSummary>{};

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(title: Strings.inventory, actions: [
        SearchBox(hint: 'بحث بالكود أو الاسم أو الماركة', onChanged: (v) => setState(() => _search = v)),
        if (canStock)
          FilledButton.icon(
            onPressed: () => showStockCount(context),
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('جرد'),
          ),
        OutlinedButton.icon(
          onPressed: () => showDialog<void>(context: context, builder: (_) => const ReservationsDialog()),
          icon: const Icon(Icons.bookmark_border),
          label: const Text('الحجوزات'),
        ),
        OutlinedButton.icon(
          onPressed: () => showDialog<void>(context: context, builder: (_) => const LocationsDialog()),
          icon: const Icon(Icons.warehouse_outlined),
          label: const Text('الأماكن والتحويل'),
        ),
      ]),
      Expanded(
        child: all.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (list) {
            bool pass(InventoryRow r, _Show s) => switch (s) {
                  _Show.inStock => r.stock != 0,
                  _Show.low => r.stock != 0 && r.item.isLowStock,
                  _Show.old => (byPrice[r.product.id]?.old ?? 0) > 0,
                  _Show.unknown => (byPrice[r.product.id]?.unknown ?? 0) > 0,
                  _Show.out => r.stock == 0,
                };
            final rows = list.where((r) => pass(r, _show)).toList();
            final held = list.where((r) => r.stock != 0);
            final value = held.fold(0, (s, r) => s + r.value);
            final oldValue = held.where((r) => (byPrice[r.product.id]?.old ?? 0) > 0).length;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SummaryStrip(items: [
                SummaryItem('أصناف في المخزون', '${held.length}', icon: Icons.inventory_2_outlined),
                if (isAdmin)
                  SummaryItem('قيمة المخزون بالتكلفة', formatMoney(value), icon: Icons.account_balance_wallet_outlined),
                SummaryItem('تحت حد الطلب', '${held.where((r) => r.item.isLowStock).length}',
                    icon: Icons.warning_amber_rounded, tone: AppColors.warn),
                SummaryItem('بها مخزون بسعر قديم', '$oldValue', icon: Icons.history, tone: AppColors.info),
                SummaryItem('نفد', '${list.where((r) => r.stock == 0).length}',
                    icon: Icons.remove_shopping_cart_outlined, tone: AppColors.bad),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  for (final (s, label) in const [
                    (_Show.inStock, 'في المخزون'),
                    (_Show.low, 'تحت حد الطلب'),
                    (_Show.old, 'بسعر قديم'),
                    (_Show.unknown, 'سعر غير محدد'),
                    (_Show.out, 'نفد'),
                  ])
                    ChoiceChip(
                      showCheckmark: false,
                      label: Text('$label  ${list.where((r) => pass(r, s)).length}'),
                      selected: _show == s,
                      onSelected: (_) => setState(() => _show = s),
                    ),
                  const SizedBox(width: 8),
                  FilterMenu(
                    icon: Icons.category_outlined,
                    allLabel: 'كل التصنيفات',
                    value: _categoryId,
                    options: [for (final c in categories) (c.id, c.nameAr)],
                    onChanged: (v) => setState(() => _categoryId = v),
                  ),
                  FilterMenu(
                    icon: Icons.sell_outlined,
                    allLabel: 'كل الماركات',
                    value: _brandId,
                    options: [for (final b in brands) (b.id, b.name)],
                    onChanged: (v) => setState(() => _brandId = v),
                  ),
                ]),
              ),
              Expanded(
                child: DataList<InventoryRow>(
                  rows: rows,
                  emptyText: list.isEmpty
                      ? 'لا يوجد مخزون بعد. يدخل المخزون من فواتير الشراء أو رصيد أول المدة، وليس من قوائم الأسعار.'
                      : 'لا توجد أصناف بهذا الاختيار',
                  onTap: (r) => context.go('/products/${r.product.id}'),
                  rowColor: (r) => r.stock == 0 ? AppColors.canvas : null,
                  trailing: (r) => _InventoryMenu(row: r, isAdmin: canStock),
                  columns: [
                    DataListColumn('', width: 60, (r) => ProductThumb(productId: r.product.id, size: 44)),
                    DataListColumn(Strings.productName, flex: 5, (r) => TitleCell(
                          r.product.nameAr,
                          subtitle: [r.product.code, if (r.item.brandName != null) r.item.brandName!].join('  ·  '),
                        )),
                    DataListColumn('الأماكن', flex: 4, (r) => Wrap(spacing: 4, runSpacing: 4, children: [
                          for (final (place, qty) in r.places)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(color: AppColors.canvas, borderRadius: BorderRadius.circular(10)),
                              child: Text('$place ${formatQty(qty)}', style: const TextStyle(fontSize: 12)),
                            ),
                        ])),
                    DataListColumn('جديد / قديم', flex: 3, (r) => _PriceSplit(byPrice[r.product.id], r.stock)),
                    DataListColumn('آخر وارد', numeric: true, flex: 2, (r) => Text(sinceText(r.lastIn),
                        style: const TextStyle(fontSize: 12.5, color: AppColors.muted))),
                    if (isAdmin)
                      DataListColumn('القيمة', flex: 2, numeric: true, (r) => Text(formatMoney(r.value))),
                    DataListColumn(Strings.stock, flex: 2, numeric: true, (r) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            stockPill(r.item),
                            if (r.item.sellableStock != r.stock)
                              Text('للبيع ${formatQty(r.item.sellableStock)}',
                                  style: const TextStyle(fontSize: 11, color: AppColors.muted)),
                          ],
                        )),
                  ],
                ),
              ),
            ]);
          },
        ),
      ),
    ]);
  }
}

/// New / old / unknown price stock as a small stacked bar with numbers.
class _PriceSplit extends StatelessWidget {
  const _PriceSplit(this.s, this.stock);

  final StockPriceSummary? s;
  final int stock;

  @override
  Widget build(BuildContext context) {
    final v = s;
    if (v == null || (v.current == 0 && v.old == 0 && v.unknown == 0)) {
      return const Text('—', style: TextStyle(color: AppColors.muted));
    }
    final parts = [
      (v.current, AppColors.good, 'جديد'),
      (v.old, AppColors.warn, 'قديم'),
      (v.unknown, AppColors.muted, 'غير محدد'),
    ].where((p) => p.$1 > 0).toList();
    return Tooltip(
      message: parts.map((p) => '${p.$3} ${formatQty(p.$1)}').join('\n'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 7,
            child: Row(children: [
              for (final (q, c, _) in parts) Expanded(flex: q, child: Container(color: c)),
            ]),
          ),
        ),
        const SizedBox(height: 3),
        Text(parts.map((p) => '${p.$3} ${formatQty(p.$1)}').join(' · '),
            overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5)),
      ]),
    );
  }
}

class _InventoryMenu extends StatelessWidget {
  const _InventoryMenu({required this.row, required this.isAdmin});

  final InventoryRow row;
  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<void Function()>(
      tooltip: 'إجراءات',
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        PopupMenuItem(value: () => showStockCard(context, row.item), child: const Text(Strings.stockCard)),
        if (isAdmin) PopupMenuItem(value: () => showStockAdjust(context, row.item), child: const Text(Strings.stockAdjust)),
        PopupMenuItem(value: () => showStockByPrice(context, row.item), child: const Text('المخزون حسب السعر')),
      ],
    );
  }
}

final _stockByPriceProvider = StreamProvider.autoDispose<Map<int, StockPriceSummary>>(
  (ref) => ref.watch(stockPriceServiceProvider).watchSummaries(),
);

typedef _Filter = ({String search, int? categoryId, int? brandId});

final _inventoryProvider = StreamProvider.autoDispose.family<List<InventoryRow>, _Filter>(
  (ref, f) => ref.watch(inventoryServiceProvider).watch(
        search: f.search,
        categoryId: f.categoryId,
        brandId: f.brandId,
        includeSoldOut: true,
      ),
);
