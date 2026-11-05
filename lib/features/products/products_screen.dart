import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_service.dart';
import '../../core/auth/session.dart';
import '../../core/db/database.dart';
import '../../core/l10n/strings.dart';
import '../../core/money.dart';
import '../../core/providers.dart';
import '../../core/quantity.dart';
import '../../core/services/product_service.dart';
import '../../core/widgets/data_list.dart';
import 'catalog_dialog.dart';
import 'locations_dialog.dart';
import 'reservations_dialog.dart';
import 'product_form_dialog.dart';
import 'stock_dialogs.dart';

class ProductsScreen extends ConsumerStatefulWidget {
  const ProductsScreen({super.key});

  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends ConsumerState<ProductsScreen> {
  String _search = '';
  int? _categoryId;
  bool _lowOnly = false;

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(currentUserProvider)?.isAdmin ?? false;
    final categories = ref.watch(_categoriesProvider).valueOrNull ?? const <Category>[];
    final rows = ref.watch(_productListProvider((_search, _categoryId, _lowOnly)));
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
              OutlinedButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const ReservationsDialog(),
                ),
                icon: const Icon(Icons.bookmark_outline),
                label: const Text('الحجوزات'),
              ),
            if (isAdmin)
              OutlinedButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const LocationsDialog(),
                ),
                icon: const Icon(Icons.warehouse_outlined),
                label: const Text('الأماكن والتحويل'),
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
              FilterChip(
                label: const Text(Strings.lowStockOnly),
                selected: _lowOnly,
                onSelected: (v) => setState(() => _lowOnly = v),
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
                DataListColumn(Strings.code, (r) => Text(r.product.code)),
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
                DataListColumn(Strings.priceRetail, numeric: true, (r) => Text(formatMoney(r.product.priceRetail))),
                if (isAdmin)
                  DataListColumn(Strings.costPrice, numeric: true, (r) => Text(formatMoney(r.product.costPrice))),
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
