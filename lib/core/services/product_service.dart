import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../pricing_math.dart';
import '../quantity.dart';
import '../search_text.dart';
import 'audit_service.dart';
import 'errors.dart';
import 'fifo_service.dart';
import 'stock_service.dart';

abstract final class PriceLevel {
  static const retail = 'retail';
  static const wholesale = 'wholesale';
  static const contractor = 'contractor';

  static const all = [retail, wholesale, contractor];
}

/// A product with the names of its category, brand and unit and its
/// current stock (thousandths), as lists and the invoice screen need it.
class ProductRow {
  const ProductRow({
    required this.product,
    required this.stock,
    int? sellableStock,
    this.categoryName,
    this.brandName,
    this.unitName,
    this.unitAllowsDecimal = false,
  }) : sellableStock = sellableStock ?? stock;

  final Product product;
  final int stock;

  /// What can be sold: display-only places do not count.
  final int sellableStock;
  final String? categoryName;
  final String? brandName;
  final String? unitName;
  final bool unitAllowsDecimal;

  bool get isLowStock => product.minStock > 0 && stock <= product.minStock;
}

/// Master data only (blueprint 3.1): no price, no cost, no balance. Blank
/// [code] means the next Product ID is given automatically.
class ProductInput {
  const ProductInput({
    this.code = '',
    required this.nameAr,
    this.manufacturerCode = '',
    this.description,
    this.categoryId,
    this.subcategoryId,
    this.brandId,
    this.series,
    this.dimensions,
    this.variant,
    this.finish,
    this.unitId,
    this.barcode,
    this.technicalSpecs,
    this.vatBasis,
    this.vatRateBp,
    this.minStock = 0,
    this.isActive = true,
    this.notes,
    this.modelNo,
  });

  /// The maker's model number, kept apart from the code and the name.
  final String? modelNo;

  final String code;
  final String nameAr;
  final String manufacturerCode;
  final String? description;
  final int? categoryId;
  final int? subcategoryId;
  final int? brandId;
  final String? series;
  final String? dimensions;
  final String? variant;
  final String? finish;
  final int? unitId;
  final String? barcode;
  final String? technicalSpecs;
  final String? vatBasis;
  final int? vatRateBp;
  final int minStock;
  final bool isActive;
  final String? notes;
}

class ProductService {
  ProductService(this.db);

  final AppDatabase db;

  static const _listSql = '''
    SELECT p.*,
           c.name_ar AS category_name,
           b.name AS brand_name,
           u.name_ar AS unit_name,
           COALESCE(u.allow_decimal, 0) AS unit_allow_decimal,
           COALESCE((SELECT SUM(m.qty) FROM stock_movements m
                     WHERE m.product_id = p.id), 0) AS stock,
           COALESCE((SELECT SUM(m.qty) FROM stock_movements m
                     JOIN locations l ON l.id = m.location_id
                     WHERE m.product_id = p.id AND l.is_sellable = 1 AND l.is_active = 1), 0) AS sellable_stock
    FROM products p
    LEFT JOIN categories c ON c.id = p.category_id
    LEFT JOIN brands b ON b.id = p.brand_id
    LEFT JOIN units u ON u.id = p.unit_id
  ''';

  Selectable<ProductRow> _rows({String where = '', List<Variable> args = const []}) {
    return db.customSelect(
      '$_listSql $where ORDER BY p.name_ar',
      variables: args,
      readsFrom: {db.products, db.categories, db.brands, db.units, db.stockMovements, db.locations},
    ).map((row) => ProductRow(
          product: db.products.map(row.data),
          stock: row.read<int>('stock'),
          sellableStock: row.read<int>('sellable_stock'),
          categoryName: row.readNullable<String>('category_name'),
          brandName: row.readNullable<String>('brand_name'),
          unitName: row.readNullable<String>('unit_name'),
          unitAllowsDecimal: row.read<int>('unit_allow_decimal') == 1,
        ));
  }

  /// All products for the list screen, filtered in Dart so Arabic spelling
  /// variants match (a shop has hundreds to a few thousand products).
  Stream<List<ProductRow>> watchList({
    String search = '',
    int? categoryId,
    bool lowStockOnly = false,
    bool includeInactive = true,
  }) {
    return _rows().watch().map((rows) => rows
        .where((r) => includeInactive || r.product.isActive)
        .where((r) => categoryId == null || r.product.categoryId == categoryId)
        .where((r) => !lowStockOnly || r.isLowStock)
        .where((r) => matchesSearch(
            search, [
              r.product.code,
              r.product.manufacturerCode,
              r.product.modelNo,
              r.product.barcode,
              r.product.nameAr,
              r.brandName,
              r.categoryName,
            ]))
        .toList());
  }

  /// Active products matching [query] by code or name, exact code first.
  Future<List<ProductRow>> search(String query, {int limit = 20}) async {
    final rows = await _rows(where: 'WHERE p.is_active = 1').get();
    final folded = foldForSearch(query);
    final hits = rows
        .where((r) => matchesSearch(
            query, [r.product.code, r.product.manufacturerCode, r.product.modelNo, r.product.barcode, r.product.nameAr, r.brandName]))
        .toList()
      ..sort((a, b) {
        int rank(ProductRow r) => foldForSearch(r.product.code) == folded ||
                foldForSearch(r.product.manufacturerCode) == folded ||
                foldForSearch(r.product.modelNo ?? '') == folded ||
                foldForSearch(r.product.barcode ?? '') == folded
            ? 0
            : 1;
        return rank(a) - rank(b);
      });
    return hits.take(limit).toList();
  }

  Future<ProductRow> row(int id) =>
      _rows(where: 'WHERE p.id = ?', args: [Variable.withInt(id)]).getSingle();

  /// Creates a product. Opening stock is by quantity, location and actual
  /// cost (blueprint 10), never by list price: [openingQty] > 0 needs
  /// [openingCost], and makes a FIFO layer.
  Future<Product> create(
    ProductInput input, {
    int openingQty = 0,
    int? openingCost,
    int locationId = mainLocationId,
    int? userId,
  }) {
    return db.transaction(() async {
      final unit = await _validate(input);
      if (openingQty < 0) throw ValidationException('رصيد أول المدة لا يمكن أن يكون سالباً');
      if (openingQty > 0 && openingCost == null) {
        throw ValidationException('أدخل التكلفة الفعلية لرصيد أول المدة');
      }
      if ((openingCost ?? 0) < 0) throw ValidationException('التكلفة لا يمكن أن تكون سالبة');
      _checkWholeQty(openingQty, unit, 'رصيد أول المدة');

      final code = input.code.trim().isEmpty ? await _nextProductId() : input.code.trim();
      final clash = await (db.select(db.products)..where((t) => t.code.equals(code))).getSingleOrNull();
      if (clash != null) throw ValidationException('الكود "$code" مستخدم للصنف "${clash.nameAr}"');

      final id = await db.into(db.products).insert(ProductsCompanion.insert(
            code: code,
            nameAr: input.nameAr.trim(),
            categoryId: Value(input.categoryId),
            brandId: Value(input.brandId),
            unitId: Value(input.unitId),
            minStock: Value(input.minStock),
            isActive: Value(input.isActive),
            notes: Value(_blankToNull(input.notes)),
            manufacturerCode: Value(input.manufacturerCode.trim()),
            matchKey: Value(matchKeyOf(input.manufacturerCode)),
            description: Value(_blankToNull(input.description)),
            subcategoryId: Value(input.subcategoryId),
            series: Value(_blankToNull(input.series)),
            dimensions: Value(_blankToNull(input.dimensions)),
            variant: Value(_blankToNull(input.variant)),
            finish: Value(_blankToNull(input.finish)),
            barcode: Value(_blankToNull(input.barcode)),
            technicalSpecs: Value(_blankToNull(input.technicalSpecs)),
            vatBasis: Value(_blankToNull(input.vatBasis)),
            vatRateBp: Value(input.vatRateBp),
            modelNo: Value(_blankToNull(input.modelNo)),
          ));
      if (openingQty > 0) {
        await StockService(db).record(
          productId: id,
          type: StockMovementType.opening,
          qty: openingQty,
          unitCost: openingCost!,
          createdBy: userId,
          locationId: locationId,
        );
        await FifoService(db).addLayer(
          productId: id,
          qty: openingQty,
          unitCost: openingCost,
          locationId: locationId,
          sourceType: 'opening',
        );
      }
      await AuditService(db).log(
        action: AuditAction.create,
        entity: 'product',
        entityId: id,
        userId: userId,
        details: openingQty > 0 ? 'رصيد أول المدة ${formatQty(openingQty)}' : null,
      );
      return (db.select(db.products)..where((t) => t.id.equals(id))).getSingle();
    });
  }

  /// Updates a product. The Product ID itself can never change.
  Future<void> update(int id, ProductInput input, {int? userId}) {
    return db.transaction(() async {
      final old = await (db.select(db.products)..where((t) => t.id.equals(id))).getSingle();
      if (input.code.trim().isNotEmpty && input.code.trim() != old.code) {
        throw ValidationException('رقم الصنف ثابت ولا يتغير (${old.code})');
      }
      await _validate(input, ignoreId: id);
      await (db.update(db.products)..where((t) => t.id.equals(id))).write(ProductsCompanion(
            nameAr: Value(input.nameAr.trim()),
            categoryId: Value(input.categoryId),
            brandId: Value(input.brandId),
            unitId: Value(input.unitId),
            minStock: Value(input.minStock),
            isActive: Value(input.isActive),
            notes: Value(_blankToNull(input.notes)),
            manufacturerCode: Value(input.manufacturerCode.trim()),
            matchKey: Value(matchKeyOf(input.manufacturerCode)),
            description: Value(_blankToNull(input.description)),
            subcategoryId: Value(input.subcategoryId),
            series: Value(_blankToNull(input.series)),
            dimensions: Value(_blankToNull(input.dimensions)),
            variant: Value(_blankToNull(input.variant)),
            finish: Value(_blankToNull(input.finish)),
            barcode: Value(_blankToNull(input.barcode)),
            technicalSpecs: Value(_blankToNull(input.technicalSpecs)),
            vatBasis: Value(_blankToNull(input.vatBasis)),
            vatRateBp: Value(input.vatRateBp),
            modelNo: Value(_blankToNull(input.modelNo)),
            updatedAt: Value(DateTime.now()),
          ));
      final fresh = await (db.select(db.products)..where((t) => t.id.equals(id))).getSingle();
      await AuditService(db).log(
        action: AuditAction.update,
        entity: 'product',
        entityId: id,
        userId: userId,
        details: auditChanges(old.toJson(), fresh.toJson()),
      );
    });
  }

  /// What keeps a product from being deleted: anything that moved it or
  /// that a document points to. Price-list rows are not here: a deleted
  /// product's rows are unlinked from it instead.
  static const _usedIn = {
    'stock_movements': 'حركة مخزون',
    'cost_layers': 'رصيد مخزون',
    'sales_invoice_items': 'فاتورة بيع',
    'purchase_invoice_items': 'فاتورة شراء',
    'return_items': 'مرتجع',
    'sales_order_lines': 'أمر بيع أو عرض سعر',
    'purchase_order_lines': 'أمر شراء',
    'reservations': 'حجز',
    'project_boq_lines': 'مقايسة مشروع',
    'stock_entry_lines': 'إدخال مخزون يدوي',
    'purchase_rejections': 'استلام مرفوض',
  };

  /// Why each of [productIds] cannot be deleted ("فاتورة بيع، حركة مخزون");
  /// a product missing from the result can be.
  Future<Map<int, String>> usage(Iterable<int> productIds) async {
    final ids = productIds.toSet().toList();
    final out = <int, List<String>>{};
    if (ids.isEmpty) return const {};
    final marks = List.filled(ids.length, '?').join(',');
    for (final e in _usedIn.entries) {
      final rows = await db.customSelect(
        'SELECT DISTINCT product_id AS p FROM ${e.key} WHERE product_id IN ($marks)',
        variables: [for (final id in ids) Variable.withInt(id)],
      ).get();
      for (final r in rows) {
        (out[r.read<int>('p')] ??= []).add(e.value);
      }
    }
    return {for (final e in out.entries) e.key: e.value.join('، ')};
  }

  /// Deletes, for good, the products of [productIds] that nothing used: no
  /// stock, no document, no reservation, no project line. Their photo and
  /// any discount set on them alone go too; price-list rows that named them
  /// are unlinked and marked "الصنف محذوف". Used products are left as they
  /// are and returned with the reason (they can be switched off instead).
  /// With [onlyIfNotOnOtherLists], a product still on a list other than
  /// [exceptList] is kept too (cleaning up after a list is removed).
  Future<ProductDeleteResult> deleteUnused(
    Iterable<int> productIds, {
    required User user,
    String reason = '',
    int? exceptList,
    bool onlyIfNotOnOtherLists = false,
  }) {
    return db.transaction(() async {
      if (!user.can(Perm.catalog)) throw ValidationException('حذف الأصناف لصلاحية الأصناف والأسعار');
      final ids = productIds.toSet().toList();
      final kept = await usage(ids);
      if (onlyIfNotOnOtherLists && ids.isNotEmpty) {
        final marks = List.filled(ids.length, '?').join(',');
        final onOthers = await db.customSelect(
          'SELECT DISTINCT i.product_id AS p FROM price_list_items i JOIN price_lists l ON l.id = i.price_list_id '
          "WHERE i.product_id IN ($marks) AND i.price_list_id <> ? AND l.status NOT IN ('withdrawn', 'deleted')",
          variables: [for (final id in ids) Variable.withInt(id), Variable.withInt(exceptList ?? -1)],
        ).get();
        for (final r in onOthers) {
          kept.putIfAbsent(r.read<int>('p'), () => 'في قائمة أسعار أخرى');
        }
      }
      final gone = ids.where((id) => !kept.containsKey(id)).toList();
      final products = {
        for (final p in await (db.select(db.products)..where((t) => t.id.isIn(gone))).get()) p.id: p,
      };
      for (final id in gone) {
        final p = products[id];
        if (p == null) continue;
        await (db.update(db.priceListItems)..where((t) => t.productId.equals(id))).write(const PriceListItemsCompanion(
            productId: Value(null), status: Value('skipped'), reviewReason: Value('الصنف محذوف')));
        await (db.delete(db.productImages)..where((t) => t.productId.equals(id))).go();
        await (db.delete(db.buyingPolicies)..where((t) => t.productId.equals(id))).go();
        await (db.delete(db.sellingPolicies)..where((t) => t.productId.equals(id))).go();
        await (db.delete(db.products)..where((t) => t.id.equals(id))).go();
        await AuditService(db).log(
          action: AuditAction.delete,
          entity: 'product',
          entityId: id,
          userId: user.id,
          details: '${p.code} — ${p.nameAr}${p.manufacturerCode.isEmpty ? '' : ' (${p.manufacturerCode})'}',
          reason: reason.trim().isEmpty ? null : reason.trim(),
        );
      }
      final names = {
        for (final p in await (db.select(db.products)..where((t) => t.id.isIn(kept.keys.toList()))).get()) p.id: p.nameAr,
      };
      return ProductDeleteResult(
        deleted: gone.where(products.containsKey).length,
        kept: {for (final e in kept.entries) if (names[e.key] != null) names[e.key]!: e.value},
        keptIds: kept.keys.toList(),
      );
    });
  }

  /// Switches products off (hidden from sales and lists, history kept).
  Future<void> setActive(Iterable<int> productIds, bool active, {int? userId}) async {
    final ids = productIds.toSet().toList();
    if (ids.isEmpty) return;
    await (db.update(db.products)..where((t) => t.id.isIn(ids)))
        .write(ProductsCompanion(isActive: Value(active), updatedAt: Value(DateTime.now())));
    for (final id in ids) {
      await AuditService(db).log(
          action: active ? AuditAction.activate : AuditAction.deactivate, entity: 'product', entityId: id, userId: userId);
    }
  }

  /// Gives many products the same category (and subcategory, which must sit
  /// under it; null clears it) in one step. Each changed product is in the
  /// audit log with its old and new category. Returns how many changed.
  Future<int> setCategory(Iterable<int> productIds, {required int categoryId, int? subcategoryId, int? userId}) {
    return db.transaction(() async {
      final ids = productIds.toSet().toList();
      if (ids.isEmpty) throw ValidationException('اختر صنفاً واحداً على الأقل');
      final category = await (db.select(db.categories)..where((t) => t.id.equals(categoryId))).getSingleOrNull();
      if (category == null || category.parentId != null) throw ValidationException('اختر التصنيف الرئيسي');
      if (subcategoryId != null) {
        final sub = await (db.select(db.categories)..where((t) => t.id.equals(subcategoryId))).getSingleOrNull();
        if (sub == null || sub.parentId != categoryId) {
          throw ValidationException('التصنيف الفرعي ليس تحت "${category.nameAr}"');
        }
      }
      final names = {for (final c in await db.select(db.categories).get()) c.id: c.nameAr};
      String label(int? cat, int? sub) =>
          cat == null ? 'بدون' : (sub == null ? names[cat] ?? '' : '${names[cat]} › ${names[sub]}');
      var changed = 0;
      for (final p in await (db.select(db.products)..where((t) => t.id.isIn(ids))).get()) {
        if (p.categoryId == categoryId && p.subcategoryId == subcategoryId) continue;
        await (db.update(db.products)..where((t) => t.id.equals(p.id))).write(ProductsCompanion(
              categoryId: Value(categoryId),
              subcategoryId: Value(subcategoryId),
              updatedAt: Value(DateTime.now()),
            ));
        await AuditService(db).log(
          action: AuditAction.update,
          entity: 'product',
          entityId: p.id,
          userId: userId,
          details: 'التصنيف: ${label(p.categoryId, p.subcategoryId)} ← ${label(categoryId, subcategoryId)} (تعديل جماعي)',
        );
        changed++;
      }
      return changed;
    });
  }

  /// Products with this maker's code under this brand, in any variant.
  Future<List<Product>> withMatchKey(String manufacturerCode, int? brandId) {
    final key = matchKeyOf(manufacturerCode);
    if (key.isEmpty) return Future.value(const []);
    return (db.select(db.products)
          ..where((t) =>
              t.matchKey.equals(key) & (brandId == null ? t.brandId.isNull() : t.brandId.equals(brandId))))
        .get();
  }

  Future<String> _nextProductId() async {
    // Taken from the highest id ever used, so an id is never reused.
    final row = await db.customSelect('SELECT COALESCE(MAX(id), 0) + 1 AS n FROM products').getSingle();
    var n = row.read<int>('n');
    while (true) {
      final code = 'P-${n.toString().padLeft(6, '0')}';
      final used = await (db.select(db.products)..where((t) => t.code.equals(code))).getSingleOrNull();
      if (used == null) return code;
      n++;
    }
  }

  /// Returns the product's unit (null if none) after checking [input].
  Future<Unit?> _validate(ProductInput input, {int? ignoreId}) async {
    if (input.nameAr.trim().isEmpty) throw ValidationException('اسم الصنف مطلوب');
    if (input.minStock < 0) throw ValidationException('حد الطلب لا يمكن أن يكون سالباً');
    if (input.vatBasis != null &&
        input.vatBasis!.trim().isNotEmpty &&
        !const [VatStatus.inclusive, VatStatus.exclusive].contains(input.vatBasis)) {
      throw ArgumentError.value(input.vatBasis, 'vatBasis');
    }
    if (input.vatRateBp != null && (input.vatRateBp! < 0 || input.vatRateBp! > 10000)) {
      throw ValidationException('نسبة الضريبة يجب أن تكون بين 0 و 100');
    }

    // The same maker's code under the same brand and variant is a duplicate.
    final same = await withMatchKey(input.manufacturerCode, input.brandId);
    final variant = variantKeyOf(input.variant);
    for (final p in same) {
      if (p.id != ignoreId && variantKeyOf(p.variant) == variant) {
        throw ValidationException(
            'كود الشركة "${input.manufacturerCode.trim()}" موجود للصنف "${p.nameAr}" (${p.code})؛ لا يُكرر الصنف');
      }
    }

    final unit = input.unitId == null
        ? null
        : await (db.select(db.units)..where((t) => t.id.equals(input.unitId!))).getSingle();
    _checkWholeQty(input.minStock, unit, 'حد الطلب');
    return unit;
  }

  void _checkWholeQty(int qty, Unit? unit, String what) {
    if (!(unit?.allowDecimal ?? false) && !isWholeQty(qty)) {
      throw ValidationException('$what يجب أن يكون رقماً صحيحاً لهذه الوحدة');
    }
  }

  static String? _blankToNull(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();
}

/// What [ProductService.deleteUnused] did: how many went, and each kept
/// product's name with what it is used in.
class ProductDeleteResult {
  const ProductDeleteResult({required this.deleted, required this.kept, required this.keptIds});

  final int deleted;
  final Map<String, String> kept;
  final List<int> keptIds;
}
