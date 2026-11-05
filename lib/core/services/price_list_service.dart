import 'package:drift/drift.dart';

import '../db/database.dart';
import 'discount_service.dart';
import 'errors.dart';

class PriceRowInput {
  const PriceRowInput({
    required this.name,
    required this.price,
    this.supplierCode = '',
    this.colour,
    this.packSize,
  });

  final String name;

  /// Piastres per unit.
  final int price;
  final String supplierCode;
  final String? colour;
  final int? packSize;
}

class PriceQuote {
  const PriceQuote({
    required this.price,
    required this.priceListId,
    required this.supplierId,
    required this.vatIncluded,
  });

  final int price;
  final int priceListId;
  final int supplierId;
  final bool vatIncluded;
}

class PriceListResult {
  const PriceListResult(this.id, this.rows, this.matched);

  final int id;
  final int rows;

  /// Rows matched to a product in the catalogue by code.
  final int matched;
}

class PriceListSummary {
  const PriceListSummary(this.list, this.supplierName, this.items, this.matched);

  final PriceList list;
  final String supplierName;
  final int items;

  /// Lines tied to a product in the catalogue.
  final int matched;
}

/// Supplier price lists. A new edition is a new list; the quote for a date
/// comes from the newest list in force on that date.
class PriceListService {
  PriceListService(this.db);

  final AppDatabase db;

  Future<PriceListResult> create({
    required int supplierId,
    required String name,
    required DateTime effectiveDate,
    required List<PriceRowInput> rows,
    int? brandId,
    bool vatIncluded = false,
    String? note,
  }) {
    return db.transaction(() async {
      if (name.trim().isEmpty) throw ValidationException('اسم القائمة مطلوب');
      if (rows.isEmpty) throw ValidationException('القائمة فارغة');
      final supplier = await (db.select(db.suppliers)..where((t) => t.id.equals(supplierId)))
          .getSingleOrNull();
      if (supplier == null) throw ValidationException('اختر المورد');
      for (final r in rows) {
        if (r.name.trim().isEmpty) throw ValidationException('صنف بدون اسم في القائمة');
        if (r.price < 0) throw ValidationException('السعر لا يمكن أن يكون سالباً (${r.name})');
        if (r.packSize != null && r.packSize! <= 0) {
          throw ValidationException('عدد الكرتونة غير صحيح (${r.name})');
        }
      }
      final listId = await db.into(db.priceLists).insert(PriceListsCompanion.insert(
            supplierId: supplierId,
            brandId: Value(brandId),
            name: name.trim(),
            effectiveDate: effectiveDate,
            vatIncluded: Value(vatIncluded),
            note: Value(note),
          ));
      final byCode = <String, int>{
        for (final p in await db.select(db.products).get()) p.code.trim().toLowerCase(): p.id,
      };
      var matched = 0;
      for (final r in rows) {
        final code = r.supplierCode.trim();
        // A code with a colour suffix is matched on the full code.
        final pid = code.isEmpty ? null : byCode[code.toLowerCase()];
        if (pid != null) matched++;
        await db.into(db.priceListItems).insert(PriceListItemsCompanion.insert(
              priceListId: listId,
              productId: Value(pid),
              supplierCode: Value(code),
              name: r.name.trim(),
              colour: Value(r.colour),
              price: r.price,
              packSize: Value(r.packSize),
            ));
      }
      return PriceListResult(listId, rows.length, matched);
    });
  }

  /// Every list, newest first, with its supplier and line counts.
  Future<List<PriceListSummary>> summaries() async {
    final rows = await db.customSelect('''
      SELECT l.*, s.name AS supplier_name,
             (SELECT COUNT(*) FROM price_list_items i WHERE i.price_list_id = l.id) AS n,
             (SELECT COUNT(*) FROM price_list_items i
               WHERE i.price_list_id = l.id AND i.product_id IS NOT NULL) AS m
      FROM price_lists l
      JOIN suppliers s ON s.id = l.supplier_id
      ORDER BY l.effective_date DESC, l.id DESC
    ''', readsFrom: {db.priceLists, db.priceListItems, db.suppliers}).get();
    return [
      for (final r in rows)
        PriceListSummary(
          db.priceLists.map(r.data),
          r.read<String>('supplier_name'),
          r.read<int>('n'),
          r.read<int>('m'),
        ),
    ];
  }

  Future<List<PriceListItem>> items(int listId) =>
      (db.select(db.priceListItems)
            ..where((i) => i.priceListId.equals(listId))
            ..orderBy([(i) => OrderingTerm.asc(i.id)]))
          .get();

  /// Ties a list line to a catalogue product.
  Future<void> matchItem(int itemId, int productId) =>
      (db.update(db.priceListItems)..where((i) => i.id.equals(itemId)))
          .write(PriceListItemsCompanion(productId: Value(productId)));

  Future<void> setActive(int listId, bool active) =>
      (db.update(db.priceLists)..where((l) => l.id.equals(listId))).write(
          PriceListsCompanion(isActive: Value(active), updatedAt: Value(DateTime.now())));

  /// The list price of [productId] on [asOf] from the newest active list
  /// in force; optionally only from [supplierId].
  Future<PriceQuote?> priceFor(int productId, {int? supplierId, DateTime? asOf}) async {
    final day = asOf ?? DateTime.now();
    final q = db.select(db.priceListItems).join([
      innerJoin(db.priceLists, db.priceLists.id.equalsExp(db.priceListItems.priceListId)),
    ])
      ..where(db.priceListItems.productId.equals(productId) & db.priceLists.isActive.equals(true))
      ..orderBy([
        OrderingTerm.desc(db.priceLists.effectiveDate),
        OrderingTerm.desc(db.priceLists.id),
      ]);
    for (final row in await q.get()) {
      final list = row.readTable(db.priceLists);
      if (list.effectiveDate.isAfter(day)) continue;
      if (supplierId != null && list.supplierId != supplierId) continue;
      return PriceQuote(
        price: row.readTable(db.priceListItems).price,
        priceListId: list.id,
        supplierId: list.supplierId,
        vatIncluded: list.vatIncluded,
      );
    }
    return null;
  }

  /// List price minus the supplier's discount, if any. Null when the
  /// product has no price in force.
  Future<int?> netCostFor(int productId, {int? supplierId, DateTime? asOf}) async {
    final quote = await priceFor(productId, supplierId: supplierId, asOf: asOf);
    if (quote == null) return null;
    final bp = await DiscountService(db)
        .percentFor(supplierId: quote.supplierId, productId: productId, asOf: asOf);
    return applyDiscount(quote.price, bp);
  }
}
