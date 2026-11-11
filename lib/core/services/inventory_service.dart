import '../db/database.dart';
import '../search_text.dart';
import 'product_service.dart';

/// One product the shop actually holds or has held: it came into stock at
/// least once (a purchase, opening balance, adjustment or return).
class InventoryRow {
  const InventoryRow({
    required this.item,
    required this.value,
    required this.places,
    this.lastIn,
  });

  /// The product and its stock.
  final ProductRow item;

  /// Piastres: what the stock on hand cost (FIFO layers left).
  final int value;

  /// Stock by place, places with nothing left out: (place name, thousandths).
  final List<(String, int)> places;

  /// When stock last came in.
  final DateTime? lastIn;

  Product get product => item.product;
  int get stock => item.stock;
}

/// The stock the shop has, kept apart from the catalogue and the price lists:
/// a product loaded from a supplier's list but never bought is not here.
class InventoryService {
  InventoryService(this.db);

  final AppDatabase db;

  static const _sql = '''
    SELECT p.*,
           c.name_ar AS category_name,
           b.name AS brand_name,
           u.name_ar AS unit_name,
           COALESCE(u.allow_decimal, 0) AS unit_allow_decimal,
           COALESCE((SELECT SUM(m.qty) FROM stock_movements m WHERE m.product_id = p.id), 0) AS stock,
           COALESCE((SELECT SUM(m.qty) FROM stock_movements m
                     JOIN locations l ON l.id = m.location_id
                     WHERE m.product_id = p.id AND l.is_sellable = 1 AND l.is_active = 1), 0) AS sellable_stock,
           COALESCE((SELECT SUM((cl.qty_remaining * cl.unit_cost + 500) / 1000) FROM cost_layers cl
                     WHERE cl.product_id = p.id AND cl.qty_remaining > 0), 0) AS stock_value,
           (SELECT MAX(m.date) FROM stock_movements m WHERE m.product_id = p.id AND m.qty > 0) AS last_in
    FROM products p
    LEFT JOIN categories c ON c.id = p.category_id
    LEFT JOIN brands b ON b.id = p.brand_id
    LEFT JOIN units u ON u.id = p.unit_id
    WHERE EXISTS (SELECT 1 FROM stock_movements m WHERE m.product_id = p.id)
    ORDER BY p.name_ar
  ''';

  /// Products held now ([includeSoldOut] adds those bought and since sold
  /// out), filtered in Dart so Arabic spelling variants match.
  Stream<List<InventoryRow>> watch({
    String search = '',
    int? categoryId,
    int? brandId,
    bool includeSoldOut = false,
    bool lowStockOnly = false,
  }) {
    final rows = db.customSelect(
      _sql,
      readsFrom: {db.products, db.categories, db.brands, db.units, db.stockMovements, db.locations, db.costLayers},
    ).watch();
    return rows.asyncMap((result) async {
      final places = await _places();
      return [
        for (final row in result)
          InventoryRow(
            item: ProductRow(
              product: db.products.map(row.data),
              stock: row.read<int>('stock'),
              sellableStock: row.read<int>('sellable_stock'),
              categoryName: row.readNullable<String>('category_name'),
              brandName: row.readNullable<String>('brand_name'),
              unitName: row.readNullable<String>('unit_name'),
              unitAllowsDecimal: row.read<int>('unit_allow_decimal') == 1,
            ),
            value: row.read<int>('stock_value'),
            places: places[row.read<int>('id')] ?? const [],
            lastIn: row.readNullable<DateTime>('last_in'),
          ),
      ]
          .where((r) => includeSoldOut || r.stock != 0)
          .where((r) => categoryId == null || r.product.categoryId == categoryId)
          .where((r) => brandId == null || r.product.brandId == brandId)
          .where((r) => !lowStockOnly || r.item.isLowStock)
          .where((r) => matchesSearch(search, [
                r.product.code,
                r.product.manufacturerCode,
                r.product.barcode,
                r.product.nameAr,
                r.item.brandName,
                r.item.categoryName,
              ]))
          .toList();
    });
  }

  Future<Map<int, List<(String, int)>>> _places() async {
    final rows = await db.customSelect(
      '''
      SELECT m.product_id AS product_id, l.name AS place, SUM(m.qty) AS qty
      FROM stock_movements m JOIN locations l ON l.id = m.location_id
      GROUP BY m.product_id, m.location_id
      HAVING SUM(m.qty) <> 0
      ORDER BY m.location_id
      ''',
      readsFrom: {db.stockMovements, db.locations},
    ).get();
    final out = <int, List<(String, int)>>{};
    for (final r in rows) {
      (out[r.read<int>('product_id')] ??= []).add((r.read<String>('place'), r.read<int>('qty')));
    }
    return out;
  }
}
