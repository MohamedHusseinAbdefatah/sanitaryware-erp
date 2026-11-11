import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/dates.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/inventory_service.dart';
import '../../core/services/stock_price_service.dart';
import '../../core/widgets/data_list.dart';
import '../products/locations_dialog.dart';
import '../products/reservations_dialog.dart';
import '../products/stock_dialogs.dart';
import '../products/stock_price_dialog.dart';

/// What the shop holds: only products that came into stock, never the whole
/// catalogue loaded from the price lists.
class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

typedef _Filter = ({String search, int? categoryId, int? brandId, bool soldOut, bool low});

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  _Filter _f = (search: '', categoryId: null, brandId: null, soldOut: false, low: false);

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(currentUserProvider)?.isAdmin ?? false;
    final categories = ref.watch(_categoriesProvider).valueOrNull ?? const <Category>[];
    final brands = ref.watch(_brandsProvider).valueOrNull ?? const <Brand>[];
    final rows = ref.watch(_inventoryProvider(_f));
    final byPrice = ref.watch(_stockByPriceProvider).valueOrNull ?? const <int, StockPriceSummary>{};
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: Strings.inventory,
          actions: [
            if (isAdmin)
              OutlinedButton.icon(
                onPressed: () => showDialog<void>(context: context, builder: (_) => const ReservationsDialog()),
                icon: const Icon(Icons.bookmark_outline),
                label: const Text('الحجوزات'),
              ),
            if (isAdmin)
              OutlinedButton.icon(
                onPressed: () => showDialog<void>(context: context, builder: (_) => const LocationsDialog()),
                icon: const Icon(Icons.warehouse_outlined),
                label: const Text('الأماكن والتحويل'),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SearchBox(
                hint: Strings.searchProducts,
                onChanged: (v) => setState(() => _f = (search: v, categoryId: _f.categoryId, brandId: _f.brandId, soldOut: _f.soldOut, low: _f.low)),
              ),
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<int?>(
                  initialValue: _f.categoryId,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: Strings.category, border: OutlineInputBorder(), isDense: true),
                  items: [
                    const DropdownMenuItem(value: null, child: Text(Strings.all)),
                    for (final c in categories) DropdownMenuItem(value: c.id, child: Text(c.nameAr, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _f = (search: _f.search, categoryId: v, brandId: _f.brandId, soldOut: _f.soldOut, low: _f.low)),
                ),
              ),
              SizedBox(
                width: 170,
                child: DropdownButtonFormField<int?>(
                  initialValue: _f.brandId,
                  isDense: true,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: Strings.brand, border: OutlineInputBorder(), isDense: true),
                  items: [
                    const DropdownMenuItem(value: null, child: Text(Strings.all)),
                    for (final b in brands) DropdownMenuItem(value: b.id, child: Text(b.name, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setState(() => _f = (search: _f.search, categoryId: _f.categoryId, brandId: v, soldOut: _f.soldOut, low: _f.low)),
                ),
              ),
              FilterChip(
                label: const Text(Strings.lowStockOnly),
                selected: _f.low,
                onSelected: (v) => setState(() => _f = (search: _f.search, categoryId: _f.categoryId, brandId: _f.brandId, soldOut: _f.soldOut, low: v)),
              ),
              FilterChip(
                label: const Text('يشمل ما نفد'),
                selected: _f.soldOut,
                onSelected: (v) => setState(() => _f = (search: _f.search, categoryId: _f.categoryId, brandId: _f.brandId, soldOut: v, low: _f.low)),
              ),
            ],
          ),
        ),
        if (rows.valueOrNull != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
            child: Text(
              '${rows.value!.where((r) => r.stock != 0).length} صنف في المخزون'
              '${isAdmin ? ' · القيمة بالتكلفة ${formatMoney(rows.value!.fold(0, (s, r) => s + r.value))}' : ''}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        const SizedBox(height: 12),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (list) => DataList<InventoryRow>(
              rows: list,
              emptyText: _f.search.isEmpty && _f.categoryId == null && _f.brandId == null && !_f.low
                  ? 'لا يوجد مخزون بعد. يدخل المخزون من فواتير الشراء أو رصيد أول المدة، وليس من قوائم الأسعار.'
                  : 'لا توجد أصناف بهذا البحث في المخزون',
              onTap: (r) => showStockCard(context, r.item),
              rowColor: (r) => r.stock == 0 ? scheme.surfaceContainerHighest : null,
              trailing: (r) => _InventoryMenu(row: r, isAdmin: isAdmin),
              columns: [
                DataListColumn('رقم الصنف', flex: 2, (r) => Text(r.product.code)),
                DataListColumn('كود الشركة', flex: 3, (r) => Text(r.product.manufacturerCode)),
                DataListColumn(Strings.productName, flex: 6, (r) => Text(r.product.nameAr)),
                DataListColumn(Strings.brand, flex: 3, (r) => Text(r.item.brandName ?? '')),
                DataListColumn('المكان', flex: 4, (r) => Text(r.places.map((p) => '${p.$1} ${formatQty(p.$2)}').join(' · '))),
                DataListColumn('جديد / قديم', flex: 4, (r) => Text(_priceSplit(byPrice[r.product.id]))),
                DataListColumn('آخر وارد', flex: 4, (r) => Text(r.lastIn == null ? '' : formatDate(r.lastIn!))),
                if (isAdmin) DataListColumn('القيمة', flex: 3, numeric: true, (r) => Text(formatMoney(r.value))),
                DataListColumn(
                  Strings.stock,
                  flex: 3,
                  numeric: true,
                  (r) => Text(
                    '${formatQty(r.stock)} ${r.item.unitName ?? ''}'.trim(),
                    style: r.item.isLowStock ? TextStyle(color: scheme.error, fontWeight: FontWeight.bold) : null,
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

/// "new 40 · old 60", leaving out whatever is zero.
String _priceSplit(StockPriceSummary? s) {
  if (s == null) return '';
  return [
    if (s.current != 0) 'جديد ${formatQty(s.current)}',
    if (s.old != 0) 'قديم ${formatQty(s.old)}',
    if (s.unknown != 0) 'غير محدد ${formatQty(s.unknown)}',
  ].join(' · ');
}

class _InventoryMenu extends StatelessWidget {
  const _InventoryMenu({required this.row, required this.isAdmin});

  final InventoryRow row;
  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<void Function()>(
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

final _categoriesProvider = StreamProvider.autoDispose<List<Category>>(
  (ref) => ref.watch(catalogServiceProvider).watchCategories(),
);

final _brandsProvider = StreamProvider.autoDispose<List<Brand>>(
  (ref) => ref.watch(catalogServiceProvider).watchBrands(),
);

final _inventoryProvider = StreamProvider.autoDispose.family<List<InventoryRow>, _Filter>(
  (ref, f) => ref.watch(inventoryServiceProvider).watch(
        search: f.search,
        categoryId: f.categoryId,
        brandId: f.brandId,
        includeSoldOut: f.soldOut,
        lowStockOnly: f.low,
      ),
);
