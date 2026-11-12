import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/providers.dart';
import '../../core/search_text.dart';
import '../../core/services/directory_service.dart';
import '../../core/services/product_service.dart';
import '../../core/theme.dart';
import '../../core/widgets/list_kit.dart';
import '../products/products_screen.dart';

final _browserProductsProvider = StreamProvider.autoDispose<List<ProductRow>>(
  (ref) => ref.watch(productServiceProvider).watchList(includeInactive: false),
);

final topSoldProvider = FutureProvider.autoDispose<List<int>>(
  (ref) => DirectoryService(ref.watch(databaseProvider)).topSoldProducts(),
);

/// Opens the product browser: photos, categories, brands, stock and price.
/// Each tap calls [onPick] (the invoice adds the product or one more of it);
/// the browser stays open until closed, showing how many of each are on the
/// invoice already.
Future<void> showProductBrowser(
  BuildContext context, {
  required Future<void> Function(ProductRow row) onPick,
  required int Function(int productId) countOf,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _ProductBrowser(onPick: onPick, countOf: countOf),
    );

class _ProductBrowser extends ConsumerStatefulWidget {
  const _ProductBrowser({required this.onPick, required this.countOf});

  final Future<void> Function(ProductRow row) onPick;
  final int Function(int productId) countOf;

  @override
  ConsumerState<_ProductBrowser> createState() => _ProductBrowserState();
}

class _ProductBrowserState extends ConsumerState<_ProductBrowser> {
  String _search = '';
  int? _categoryId;
  int? _brandId;
  bool _inStockOnly = true;
  bool _topOnly = false;
  int _added = 0;

  Future<void> _pick(ProductRow r) async {
    await widget.onPick(r);
    if (mounted) setState(() => _added++);
  }

  @override
  Widget build(BuildContext context) {
    final all = ref.watch(_browserProductsProvider);
    final prices = ref.watch(listPricesProvider).valueOrNull ?? const <int, int>{};
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const <Category>[];
    final brands = ref.watch(brandsProvider).valueOrNull ?? const <Brand>[];
    final top = ref.watch(topSoldProvider).valueOrNull ?? const <int>[];
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: size.width * .92,
        height: size.height * .9,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(children: [
              const Icon(Icons.grid_view_rounded, color: AppColors.brand),
              const SizedBox(width: 8),
              const Text('تصفح الأصناف', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  autofocus: true,
                  onChanged: (v) => setState(() => _search = v),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                    hintText: 'اكتب جزءاً من الاسم أو الكود أو الماركة',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              if (_added > 0) StatusPill.good('أُضيف $_added'),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.check),
                label: const Text('تم'),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (top.isNotEmpty)
                FilterChip(
                  avatar: const Icon(Icons.local_fire_department_outlined, size: 18),
                  label: const Text('الأكثر مبيعاً'),
                  selected: _topOnly,
                  onSelected: (v) => setState(() => _topOnly = v),
                ),
              FilterChip(
                label: const Text('المتوفر فقط'),
                selected: _inStockOnly,
                onSelected: (v) => setState(() => _inStockOnly = v),
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
          // Categories as tabs of chips: one tap narrows the grid.
          SizedBox(
            height: 48,
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              scrollDirection: Axis.horizontal,
              children: [
                for (final (id, name) in [(null, 'كل التصنيفات'), for (final c in categories) (c.id, c.nameAr)])
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: ChoiceChip(
                      showCheckmark: false,
                      label: Text(name),
                      selected: _categoryId == id,
                      onSelected: (_) => setState(() => _categoryId = id),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Expanded(
            child: all.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (list) {
                final rank = {for (var i = 0; i < top.length; i++) top[i]: i};
                final rows = list
                    .where((r) =>
                        (!_inStockOnly || r.sellableStock > 0) &&
                        (!_topOnly || rank.containsKey(r.product.id)) &&
                        (_categoryId == null || r.product.categoryId == _categoryId) &&
                        (_brandId == null || r.product.brandId == _brandId) &&
                        matchesSearch(_search, [
                          r.product.code,
                          r.product.manufacturerCode,
                          r.product.barcode,
                          r.product.nameAr,
                          r.brandName,
                          r.categoryName,
                        ]))
                    .toList()
                  // Best sellers first, then by name.
                  ..sort((a, b) {
                    final ra = rank[a.product.id] ?? 1 << 20, rb = rank[b.product.id] ?? 1 << 20;
                    return ra != rb ? ra.compareTo(rb) : a.product.nameAr.compareTo(b.product.nameAr);
                  });
                return CardGrid<ProductRow>(
                  rows: rows,
                  width: 210,
                  height: 236,
                  emptyText: _inStockOnly ? 'لا أصناف متوفرة بهذا الاختيار — جرّب إلغاء "المتوفر فقط"' : 'لا أصناف بهذا البحث',
                  card: (r) => ProductCard(
                    row: r,
                    price: prices[r.product.id],
                    badge: widget.countOf(r.product.id),
                    onTap: () => _pick(r),
                  ),
                );
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Text(
              'اضغط على الصنف لإضافته للفاتورة، واضغط مرة أخرى لزيادة الكمية. السعر النهائي يُحسب على الفاتورة بخصم العميل.',
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
          ),
        ]),
      ),
    );
  }
}

final _topRowsProvider = FutureProvider.autoDispose<List<ProductRow>>((ref) async {
  final ids = await ref.watch(topSoldProvider.future);
  final products = ref.watch(productServiceProvider);
  final rows = <ProductRow>[];
  for (final id in ids.take(10)) {
    final r = await products.row(id);
    if (r.product.isActive) rows.add(r);
  }
  return rows;
});

/// What an empty invoice shows: the products sold most, one tap to add, and
/// the way into the full browser.
class QuickAdd extends ConsumerWidget {
  const QuickAdd({super.key, required this.onPick, required this.onBrowse});

  final void Function(ProductRow row) onPick;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final top = ref.watch(_topRowsProvider).valueOrNull ?? const <ProductRow>[];
    final prices = ref.watch(listPricesProvider).valueOrNull ?? const <int, int>{};
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.add_shopping_cart_outlined, size: 44, color: AppColors.border),
          const SizedBox(height: 8),
          const Text('ابحث بالكود أو الاسم في الخانة بالأعلى (F2)، أو تصفح الأصناف بالصور (F3)',
              style: TextStyle(color: AppColors.muted)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onBrowse,
            icon: const Icon(Icons.grid_view_rounded),
            label: const Text('تصفح كل الأصناف'),
          ),
          if (top.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Text('الأكثر مبيعاً — اضغط للإضافة', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
              for (final r in top)
                SizedBox(
                  width: 170,
                  height: 200,
                  child: ProductCard(row: r, price: prices[r.product.id], onTap: () => onPick(r)),
                ),
            ]),
          ],
        ]),
      ),
    );
  }
}
