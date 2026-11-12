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
import '../../core/search_text.dart';
import '../../core/services/product_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/data_list.dart';
import '../../core/widgets/list_kit.dart';
import 'catalog_dialog.dart';
import 'price_history_dialog.dart';
import 'product_form_dialog.dart';
import 'product_image.dart';
import 'stock_dialogs.dart';
import 'stock_price_dialog.dart';

/// Each product's list price today, for lists and the product browser.
final listPricesProvider = StreamProvider.autoDispose<Map<int, int>>(
  (ref) => ref.watch(stockPriceServiceProvider).watchCurrentListPrices(),
);

final categoriesProvider = StreamProvider.autoDispose<List<Category>>(
  (ref) => ref.watch(catalogServiceProvider).watchCategories(),
);

final brandsProvider = StreamProvider.autoDispose<List<Brand>>(
  (ref) => ref.watch(catalogServiceProvider).watchBrands(),
);

final _allProductsProvider = StreamProvider.autoDispose<List<ProductRow>>(
  (ref) => ref.watch(productServiceProvider).watchList(),
);

/// In stock, low, or out: as a coloured pill.
Widget stockPill(ProductRow r) {
  final text = '${formatQty(r.stock)} ${r.unitName ?? ''}'.trim();
  if (r.stock <= 0) return StatusPill.bad(r.stock < 0 ? text : 'نفد');
  if (r.isLowStock) return StatusPill.warn(text);
  return StatusPill.good(text);
}

enum _Show { all, inStock, low, out, noPrice, stopped }

class ProductsScreen extends ConsumerStatefulWidget {
  const ProductsScreen({super.key});

  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends ConsumerState<ProductsScreen> {
  String _search = '';
  int? _categoryId;
  int? _brandId;
  _Show _show = _Show.all;
  bool _cards = false;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final isAdmin = user?.can(Perm.catalog) ?? false;
    final canStock = user?.can(Perm.stock) ?? false;
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const <Category>[];
    final brands = ref.watch(brandsProvider).valueOrNull ?? const <Brand>[];
    final prices = ref.watch(listPricesProvider).valueOrNull ?? const <int, int>{};
    final all = ref.watch(_allProductsProvider);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(title: Strings.products, actions: [
        SearchBox(hint: 'بحث بالكود أو الاسم أو الباركود', onChanged: (v) => setState(() => _search = v)),
        ViewToggle(cards: _cards, onChanged: (v) => setState(() => _cards = v)),
        if (isAdmin)
          OutlinedButton.icon(
            onPressed: () => showDialog<void>(context: context, builder: (_) => const CatalogDialog()),
            icon: const Icon(Icons.list_alt),
            label: const Text(Strings.lists),
          ),
        if (isAdmin)
          FilledButton.icon(
            onPressed: () => showProductForm(context),
            icon: const Icon(Icons.add),
            label: const Text(Strings.newProduct),
          ),
      ]),
      Expanded(
        child: all.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (list) {
            bool pass(ProductRow r, _Show s) => switch (s) {
                  _Show.all => r.product.isActive,
                  _Show.inStock => r.product.isActive && r.stock > 0,
                  _Show.low => r.product.isActive && r.isLowStock && r.stock > 0,
                  _Show.out => r.product.isActive && r.stock <= 0,
                  _Show.noPrice => r.product.isActive && prices[r.product.id] == null,
                  _Show.stopped => !r.product.isActive,
                };
            final base = list.where((r) =>
                (_categoryId == null || r.product.categoryId == _categoryId) &&
                (_brandId == null || r.product.brandId == _brandId) &&
                matchesSearch(_search, [
                  r.product.code,
                  r.product.manufacturerCode,
                  r.product.barcode,
                  r.product.nameAr,
                  r.brandName,
                  r.categoryName,
                ]));
            final rows = base.where((r) => pass(r, _show)).toList();
            final active = list.where((r) => r.product.isActive);
            void open(ProductRow r) => context.go('/products/${r.product.id}');
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SummaryStrip(items: [
                SummaryItem('أصناف نشطة', '${active.length}', icon: Icons.inventory_2_outlined),
                SummaryItem('متوفرة', '${active.where((r) => r.stock > 0).length}',
                    icon: Icons.check_circle_outline, tone: AppColors.good),
                SummaryItem('تحت حد الطلب', '${active.where((r) => r.isLowStock && r.stock > 0).length}',
                    icon: Icons.warning_amber_rounded, tone: AppColors.warn),
                SummaryItem('بدون سعر بيع ساري', '${active.where((r) => prices[r.product.id] == null).length}',
                    icon: Icons.price_change_outlined, tone: AppColors.bad),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  for (final (s, label) in const [
                    (_Show.all, 'الكل'),
                    (_Show.inStock, 'متوفر'),
                    (_Show.low, 'تحت حد الطلب'),
                    (_Show.out, 'نفد / غير مخزّن'),
                    (_Show.noPrice, 'بدون سعر'),
                    (_Show.stopped, 'موقوف'),
                  ])
                    ChoiceChip(
                      showCheckmark: false,
                      label: Text('$label  ${base.where((r) => pass(r, s)).length}'),
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
                child: _cards
                    ? CardGrid<ProductRow>(
                        rows: rows,
                        emptyText: Strings.noProducts,
                        width: 230,
                        height: 250,
                        card: (r) => ProductCard(row: r, price: prices[r.product.id], onTap: () => open(r)),
                      )
                    : DataList<ProductRow>(
                        rows: rows,
                        emptyText: Strings.noProducts,
                        onTap: open,
                        rowColor: (r) => r.product.isActive ? null : AppColors.canvas,
                        trailing: (r) => _ProductMenu(row: r, isAdmin: isAdmin, canStock: canStock),
                        columns: [
                          DataListColumn('', width: 60, (r) => ProductThumb(productId: r.product.id, size: 44)),
                          DataListColumn(Strings.productName, flex: 5, (r) => TitleCell(
                                r.product.nameAr,
                                subtitle: [
                                  r.product.code,
                                  if (r.product.manufacturerCode.isNotEmpty && r.product.manufacturerCode != r.product.code)
                                    'كود الشركة ${r.product.manufacturerCode}',
                                ].join('  ·  '),
                                muted: !r.product.isActive,
                              )),
                          DataListColumn('التصنيف / الماركة', flex: 3, (r) => TitleCell(
                                r.categoryName ?? '—',
                                subtitle: r.brandName,
                              )),
                          DataListColumn('سعر القائمة', numeric: true, flex: 2, (r) {
                            final p = prices[r.product.id];
                            return Text(p == null ? 'بدون سعر' : formatMoney(p),
                                style: TextStyle(
                                    fontWeight: FontWeight.w700, color: p == null ? AppColors.muted : AppColors.ink));
                          }),
                          DataListColumn(Strings.stock, numeric: true, flex: 2, stockPill),
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

/// A product as a card with its photo, for the card view and the product
/// browser of the sale screen.
class ProductCard extends StatelessWidget {
  const ProductCard({super.key, required this.row, this.price, this.onTap, this.badge});

  final ProductRow row;
  final int? price;
  final VoidCallback? onTap;

  /// A count shown on the photo (how many are on the invoice already).
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final p = row.product;
    return TapCard(
      onTap: onTap,
      padding: 10,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Expanded(
          child: Stack(children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(color: AppColors.canvas, borderRadius: BorderRadius.circular(8)),
                child: Center(child: ProductThumb(productId: p.id, size: 104, zoom: false)),
              ),
            ),
            PositionedDirectional(top: 6, start: 6, child: stockPill(row)),
            if (badge != null && badge! > 0)
              PositionedDirectional(
                top: 6,
                end: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: AppColors.brand, borderRadius: BorderRadius.circular(12)),
                  child: Text('× $badge', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 8),
        Text(p.nameAr, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, height: 1.25)),
        Text([p.code, if (row.brandName != null) row.brandName!].join('  ·  '),
            overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: AppColors.muted)),
        const SizedBox(height: 4),
        Text(price == null ? 'بدون سعر' : formatMoney(price!),
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: price == null ? AppColors.muted : AppColors.brand)),
      ]),
    );
  }
}

class FilterMenu extends StatelessWidget {
  const FilterMenu({
    super.key,
    required this.icon,
    required this.allLabel,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final IconData icon;
  final String allLabel;
  final int? value;
  final List<(int, String)> options;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: allLabel,
      onSelected: (v) => onChanged(v == -1 ? null : v),
      itemBuilder: (_) => [
        PopupMenuItem(value: -1, child: Text(allLabel)),
        for (final (id, name) in options) PopupMenuItem(value: id, child: Text(name)),
      ],
      child: Chip(
        avatar: Icon(icon, size: 18),
        label: Text(value == null ? allLabel : options.where((o) => o.$1 == value).firstOrNull?.$2 ?? allLabel),
        backgroundColor: value == null ? null : AppColors.infoBg,
      ),
    );
  }
}

class _ProductMenu extends StatelessWidget {
  const _ProductMenu({required this.row, required this.isAdmin, required this.canStock});

  final bool canStock;

  final ProductRow row;
  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<void Function()>(
      tooltip: 'إجراءات',
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        if (isAdmin) PopupMenuItem(value: () => showProductForm(context, existing: row), child: const Text(Strings.edit)),
        if (canStock) PopupMenuItem(value: () => showStockAdjust(context, row), child: const Text(Strings.stockAdjust)),
        PopupMenuItem(value: () => showStockCard(context, row), child: const Text(Strings.stockCard)),
        PopupMenuItem(value: () => showStockByPrice(context, row), child: const Text('المخزون حسب السعر')),
        PopupMenuItem(value: () => showPriceHistory(context, row), child: const Text('سجل الأسعار')),
      ],
    );
  }
}
