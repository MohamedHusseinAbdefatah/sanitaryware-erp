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
import '../../core/widgets/feedback.dart';
import 'bulk_category_dialog.dart';
import 'delete_products_dialog.dart';
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

  /// Selection mode: tick products, then give them a category at once.
  bool _selecting = false;
  final _selected = <int>{};

  /// The category filter's value for products with no category.
  static const _noCategory = 0;

  Future<void> _setCategory() async {
    final changed = await showBulkCategory(context, _selected.toList());
    if (changed == null || !mounted) return;
    setState(() {
      _selected.clear();
      _selecting = false;
    });
    showToast(context, 'تم تعيين التصنيف لـ $changed صنف');
  }

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
      PageHeader(title: Strings.products, icon: Icons.inventory_2_outlined, subtitle: 'دليل الأصناف: الأكواد والموديلات والماركات والصور', actions: [
        SearchBox(hint: 'بحث بالكود أو الاسم أو الباركود', onChanged: (v) => setState(() => _search = v)),
        ViewToggle(cards: _cards, onChanged: (v) => setState(() => _cards = v)),
        if (isAdmin)
          OutlinedButton.icon(
            onPressed: () => setState(() {
              _selecting = !_selecting;
              _selected.clear();
              _cards = false;
            }),
            icon: Icon(_selecting ? Icons.close : Icons.checklist),
            label: Text(_selecting ? 'إنهاء التحديد' : 'تحديد وتصنيف'),
          ),
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
                (_categoryId == null ||
                    (_categoryId == _noCategory ? r.product.categoryId == null : r.product.categoryId == _categoryId)) &&
                (_brandId == null || r.product.brandId == _brandId) &&
                matchesSearch(_search, [
                  r.product.code,
                  r.product.manufacturerCode,
                  r.product.modelNo,
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
                    options: [
                      (_noCategory, 'بدون تصنيف (${list.where((r) => r.product.isActive && r.product.categoryId == null).length})'),
                      for (final c in categories) (c.id, c.nameAr),
                    ],
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
              if (_selecting)
                Container(
                  margin: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(color: AppColors.infoBg, borderRadius: BorderRadius.circular(8)),
                  child: Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text('محدد ${_selected.length} صنف',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    TextButton.icon(
                      onPressed: () => setState(() => _selected.addAll(rows.map((r) => r.product.id))),
                      icon: const Icon(Icons.select_all),
                      label: Text('تحديد كل الظاهر (${rows.length})'),
                    ),
                    TextButton.icon(
                      onPressed: _selected.isEmpty ? null : () => setState(_selected.clear),
                      icon: const Icon(Icons.deselect),
                      label: const Text('إلغاء التحديد'),
                    ),
                    FilledButton.icon(
                      onPressed: _selected.isEmpty ? null : _setCategory,
                      icon: const Icon(Icons.category_outlined),
                      label: const Text('تعيين التصنيف…'),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(foregroundColor: AppColors.bad),
                      onPressed: _selected.isEmpty
                          ? null
                          : () async {
                              if (await deleteProducts(context, ref, _selected.toList()) && mounted) {
                                setState(_selected.clear);
                              }
                            },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('حذف المحدد…'),
                    ),
                    const Text('ابحث أو صفِّ (مثلاً: الماركة + بدون تصنيف + كلمة "حوض")، ثم حدد الكل وعيّن التصنيف أو احذف الخطأ.',
                        style: TextStyle(fontSize: 12, color: AppColors.muted)),
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
                        onTap: _selecting
                            ? (r) => setState(() =>
                                _selected.contains(r.product.id) ? _selected.remove(r.product.id) : _selected.add(r.product.id))
                            : open,
                        rowColor: (r) => _selecting && _selected.contains(r.product.id)
                            ? AppColors.infoBg
                            : (r.product.isActive ? null : AppColors.canvas),
                        trailing: (r) => _ProductMenu(row: r, isAdmin: isAdmin, canStock: canStock),
                        columns: [
                          if (_selecting)
                            DataListColumn('', width: 44, (r) => Checkbox(
                                  value: _selected.contains(r.product.id),
                                  onChanged: (v) => setState(() =>
                                      v == true ? _selected.add(r.product.id) : _selected.remove(r.product.id)),
                                )),
                          DataListColumn('', width: 60, (r) => ProductThumb(productId: r.product.id, size: 44)),
                          DataListColumn(Strings.productName, sortValue: (r) => r.product.nameAr, flex: 5, (r) => TitleCell(
                                r.product.nameAr,
                                tag: ModelTag(r.product.modelNo),
                                subtitle: [
                                  r.product.code,
                                  if (r.product.manufacturerCode.isNotEmpty && r.product.manufacturerCode != r.product.code)
                                    'كود الشركة ${r.product.manufacturerCode}',
                                ].join('  ·  '),
                                muted: !r.product.isActive,
                              )),
                          DataListColumn('الموديل', sortValue: (r) => r.product.modelNo ?? '', flex: 2, (r) => Text(
                                (r.product.modelNo ?? '').trim().isEmpty ? '—' : r.product.modelNo!.trim(),
                                style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: (r.product.modelNo ?? '').trim().isEmpty ? AppColors.muted : AppColors.brand),
                              )),
                          DataListColumn('كود الشركة', sortValue: (r) => r.product.manufacturerCode, flex: 2,
                              (r) => Text(r.product.manufacturerCode.isEmpty ? '—' : r.product.manufacturerCode)),
                          DataListColumn('التصنيف / الماركة', flex: 3, (r) => TitleCell(
                                r.categoryName ?? '—',
                                subtitle: r.brandName,
                              )),
                          DataListColumn('سعر القائمة', sortValue: (r) => prices[r.product.id], numeric: true, flex: 2, (r) {
                            final p = prices[r.product.id];
                            return Text(p == null ? 'بدون سعر' : formatMoney(p),
                                style: TextStyle(
                                    fontWeight: FontWeight.w700, color: p == null ? AppColors.muted : AppColors.ink));
                          }),
                          DataListColumn(Strings.stock, sortValue: (r) => r.stock, numeric: true, flex: 2, stockPill),
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
        if ((p.modelNo ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: ModelTag(p.modelNo)),
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

class _ProductMenu extends ConsumerWidget {
  const _ProductMenu({required this.row, required this.isAdmin, required this.canStock});

  final bool canStock;

  final ProductRow row;
  final bool isAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<void Function()>(
      tooltip: 'إجراءات',
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        if (isAdmin) PopupMenuItem(value: () => showProductForm(context, existing: row), child: const Text(Strings.edit)),
        if (canStock) PopupMenuItem(value: () => showStockAdjust(context, row), child: const Text(Strings.stockAdjust)),
        PopupMenuItem(value: () => showStockCard(context, row), child: const Text(Strings.stockCard)),
        PopupMenuItem(value: () => showStockByPrice(context, row), child: const Text('المخزون حسب السعر')),
        PopupMenuItem(value: () => showPriceHistory(context, row), child: const Text('سجل الأسعار')),
        if (isAdmin)
          PopupMenuItem(
            value: () => deleteProducts(context, ref, [row.product.id]),
            child: const Text('حذف الصنف', style: TextStyle(color: AppColors.bad)),
          ),
      ],
    );
  }
}
