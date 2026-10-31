import 'package:drift/drift.dart';

import '../db/database.dart';
import '../money.dart';
import '../quantity.dart';
import '../search_text.dart';
import 'audit_service.dart';
import 'errors.dart';
import 'stock_service.dart';

abstract final class PriceLevel {
  static const retail = 'retail';
  static const wholesale = 'wholesale';
  static const contractor = 'contractor';

  static const all = [retail, wholesale, contractor];
}

extension ProductPrices on Product {
  /// Default selling price for a customer's price level.
  int priceFor(String level) => switch (level) {
        PriceLevel.wholesale => priceWholesale,
        PriceLevel.contractor => priceContractor,
        _ => priceRetail,
      };
}

/// A product with the names of its category, brand and unit and its
/// current stock (thousandths), as lists and the invoice screen need it.
class ProductRow {
  const ProductRow({
    required this.product,
    required this.stock,
    this.categoryName,
    this.brandName,
    this.unitName,
    this.unitAllowsDecimal = false,
  });

  final Product product;
  final int stock;
  final String? categoryName;
  final String? brandName;
  final String? unitName;
  final bool unitAllowsDecimal;

  bool get isLowStock => product.minStock > 0 && stock <= product.minStock;
}

class ProductInput {
  const ProductInput({
    required this.code,
    required this.nameAr,
    this.categoryId,
    this.brandId,
    this.unitId,
    this.costPrice = 0,
    this.priceRetail = 0,
    this.priceWholesale = 0,
    this.priceContractor = 0,
    this.minStock = 0,
    this.isActive = true,
    this.notes,
  });

  final String code;
  final String nameAr;
  final int? categoryId;
  final int? brandId;
  final int? unitId;
  final int costPrice;
  final int priceRetail;
  final int priceWholesale;
  final int priceContractor;
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
                     WHERE m.product_id = p.id), 0) AS stock
    FROM products p
    LEFT JOIN categories c ON c.id = p.category_id
    LEFT JOIN brands b ON b.id = p.brand_id
    LEFT JOIN units u ON u.id = p.unit_id
  ''';

  Selectable<ProductRow> _rows({String where = '', List<Variable> args = const []}) {
    return db.customSelect(
      '$_listSql $where ORDER BY p.name_ar',
      variables: args,
      readsFrom: {db.products, db.categories, db.brands, db.units, db.stockMovements},
    ).map((row) => ProductRow(
          product: db.products.map(row.data),
          stock: row.read<int>('stock'),
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
            search, [r.product.code, r.product.nameAr, r.brandName, r.categoryName]))
        .toList());
  }

  /// Active products matching [query] by code or name, exact code first.
  Future<List<ProductRow>> search(String query, {int limit = 20}) async {
    final rows = await _rows(where: 'WHERE p.is_active = 1').get();
    final folded = foldForSearch(query);
    final hits = rows
        .where((r) => matchesSearch(query, [r.product.code, r.product.nameAr, r.brandName]))
        .toList()
      ..sort((a, b) {
        final ac = foldForSearch(a.product.code) == folded ? 0 : 1;
        final bc = foldForSearch(b.product.code) == folded ? 0 : 1;
        return ac - bc;
      });
    return hits.take(limit).toList();
  }

  Future<ProductRow> row(int id) =>
      _rows(where: 'WHERE p.id = ?', args: [Variable.withInt(id)]).getSingle();

  /// Creates a product, with an opening stock movement if [openingQty] > 0.
  Future<Product> create(ProductInput input, {int openingQty = 0, int? userId}) {
    return db.transaction(() async {
      final unit = await _validate(input);
      if (openingQty < 0) throw ValidationException('رصيد أول المدة لا يمكن أن يكون سالباً');
      _checkWholeQty(openingQty, unit, 'رصيد أول المدة');

      final id = await db.into(db.products).insert(ProductsCompanion.insert(
            code: input.code.trim(),
            nameAr: input.nameAr.trim(),
            categoryId: Value(input.categoryId),
            brandId: Value(input.brandId),
            unitId: Value(input.unitId),
            costPrice: Value(input.costPrice),
            priceRetail: Value(input.priceRetail),
            priceWholesale: Value(input.priceWholesale),
            priceContractor: Value(input.priceContractor),
            minStock: Value(input.minStock),
            isActive: Value(input.isActive),
            notes: Value(_blankToNull(input.notes)),
          ));
      if (openingQty > 0) {
        await StockService(db).record(
          productId: id,
          type: StockMovementType.opening,
          qty: openingQty,
          unitCost: input.costPrice,
          createdBy: userId,
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

  /// Updates a product. Price changes are written to the audit log.
  Future<void> update(int id, ProductInput input, {int? userId}) {
    return db.transaction(() async {
      final old = await (db.select(db.products)..where((t) => t.id.equals(id))).getSingle();
      await _validate(input, ignoreId: id);
      await (db.update(db.products)..where((t) => t.id.equals(id))).write(ProductsCompanion(
            code: Value(input.code.trim()),
            nameAr: Value(input.nameAr.trim()),
            categoryId: Value(input.categoryId),
            brandId: Value(input.brandId),
            unitId: Value(input.unitId),
            costPrice: Value(input.costPrice),
            priceRetail: Value(input.priceRetail),
            priceWholesale: Value(input.priceWholesale),
            priceContractor: Value(input.priceContractor),
            minStock: Value(input.minStock),
            isActive: Value(input.isActive),
            notes: Value(_blankToNull(input.notes)),
            updatedAt: Value(DateTime.now()),
          ));

      final changes = <String>[
        if (old.costPrice != input.costPrice)
          'التكلفة ${formatMoney(old.costPrice)} ← ${formatMoney(input.costPrice)}',
        if (old.priceRetail != input.priceRetail)
          'قطاعي ${formatMoney(old.priceRetail)} ← ${formatMoney(input.priceRetail)}',
        if (old.priceWholesale != input.priceWholesale)
          'جملة ${formatMoney(old.priceWholesale)} ← ${formatMoney(input.priceWholesale)}',
        if (old.priceContractor != input.priceContractor)
          'مقاولين ${formatMoney(old.priceContractor)} ← ${formatMoney(input.priceContractor)}',
      ];
      await AuditService(db).log(
        action: AuditAction.update,
        entity: 'product',
        entityId: id,
        userId: userId,
        details: changes.isEmpty ? null : changes.join('، '),
      );
    });
  }

  /// Returns the product's unit (null if none) after checking [input].
  Future<Unit?> _validate(ProductInput input, {int? ignoreId}) async {
    final code = input.code.trim();
    if (code.isEmpty) throw ValidationException('كود الصنف مطلوب');
    if (input.nameAr.trim().isEmpty) throw ValidationException('اسم الصنف مطلوب');
    for (final price in [
      input.costPrice,
      input.priceRetail,
      input.priceWholesale,
      input.priceContractor,
    ]) {
      if (price < 0) throw ValidationException('الأسعار لا يمكن أن تكون سالبة');
    }
    if (input.minStock < 0) throw ValidationException('حد الطلب لا يمكن أن يكون سالباً');

    final clash = await (db.select(db.products)..where((t) => t.code.equals(code)))
        .getSingleOrNull();
    if (clash != null && clash.id != ignoreId) {
      throw ValidationException('الكود "$code" مستخدم للصنف "${clash.nameAr}"');
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
