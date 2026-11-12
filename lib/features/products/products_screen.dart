import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/product_service.dart';
import '../../core/widgets/data_list.dart';
import 'catalog_dialog.dart';
import 'price_history_dialog.dart';
import 'product_form_dialog.dart';
import 'product_image.dart';
import 'stock_dialogs.dart';
import 'stock_price_dialog.dart';

class ProductsScreen extends ConsumerStatefulWidget {
  const ProductsScreen({super.key});

  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends ConsumerState<ProductsScreen> {
  String _search = '';
  int? _categoryId;


  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(currentUserProvider)?.isAdmin ?? false;
    final categories = ref.watch(_categoriesProvider).valueOrNull ?? const <Category>[];
    final rows = ref.watch(_productListProvider((_search, _categoryId, false)));
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: Strings.products,
          actions: [
            if (isAdmin)
              OutlinedButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const CatalogDialog(),
                ),
                icon: const Icon(Icons.list_alt),
                label: const Text(Strings.lists),
              ),
            if (isAdmin)
              FilledButton.icon(
                onPressed: () => showProductForm(context),
                icon: const Icon(Icons.add),
                label: const Text(Strings.newProduct),
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
              SearchBox(hint: Strings.searchProducts, onChanged: (v) => setState(() => _search = v)),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<int?>(
                  initialValue: _categoryId,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: Strings.category,
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text(Strings.all)),
                    for (final c in categories) DropdownMenuItem(value: c.id, child: Text(c.nameAr)),
                  ],
                  onChanged: (v) => setState(() => _categoryId = v),
                ),
              ),
              if (rows.valueOrNull != null) Text('${rows.value!.length} ${Strings.items}'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('$e')),
            data: (list) => DataList<ProductRow>(
              rows: list,
              emptyText: Strings.noProducts,
              onTap: (r) => isAdmin
                  ? showProductForm(context, existing: r)
                  : showStockCard(context, r),
              rowColor: (r) => r.product.isActive ? null : scheme.surfaceContainerHighest,
              trailing: (r) => _ProductMenu(row: r, isAdmin: isAdmin),
              columns: [
                DataListColumn('', width: 56, (r) => ProductThumb(productId: r.product.id)),
                DataListColumn('رقم الصنف', (r) => Text(r.product.code)),
                DataListColumn('كود الشركة', (r) => Text(r.product.manufacturerCode)),
                DataListColumn(Strings.productName, flex: 3, (r) => Text(r.product.nameAr)),
                DataListColumn(Strings.category, (r) => Text(r.categoryName ?? '')),
                DataListColumn(Strings.brand, (r) => Text(r.brandName ?? '')),
                DataListColumn(Strings.unit, numeric: true, (r) => Text(r.unitName ?? '')),
                DataListColumn(
                  Strings.stock,
                  numeric: true,
                  (r) => Text(
                    formatQty(r.stock),
                    style: r.isLowStock
                        ? TextStyle(color: scheme.error, fontWeight: FontWeight.bold)
                        : null,
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

class _ProductMenu extends StatelessWidget {
  const _ProductMenu({required this.row, required this.isAdmin});

  final ProductRow row;
  final bool isAdmin;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<void Function()>(
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        if (isAdmin)
          PopupMenuItem(
            value: () => showProductForm(context, existing: row),
            child: const Text(Strings.edit),
          ),
        if (isAdmin)
          PopupMenuItem(
            value: () => showStockAdjust(context, row),
            child: const Text(Strings.stockAdjust),
          ),
        PopupMenuItem(
          value: () => showStockCard(context, row),
          child: const Text(Strings.stockCard),
        ),
        PopupMenuItem(
          value: () => showStockByPrice(context, row),
          child: const Text('المخزون حسب السعر'),
        ),
        PopupMenuItem(
          value: () => showPriceHistory(context, row),
          child: const Text('سجل الأسعار'),
        ),
      ],
    );
  }
}

final _categoriesProvider = StreamProvider.autoDispose<List<Category>>(
  (ref) => ref.watch(catalogServiceProvider).watchCategories(),
);

final _productListProvider =
    StreamProvider.autoDispose.family<List<ProductRow>, (String, int?, bool)>(
  (ref, filter) => ref.watch(productServiceProvider).watchList(
        search: filter.$1,
        categoryId: filter.$2,
        lowStockOnly: filter.$3,
      ),
);
