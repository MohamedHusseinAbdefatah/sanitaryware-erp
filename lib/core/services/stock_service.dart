import 'package:drift/drift.dart';

import '../db/database.dart';

abstract final class StockMovementType {
  static const opening = 'opening';
  static const purchase = 'purchase';
  static const sale = 'sale';
  static const saleReturn = 'sale_return';
  static const purchaseReturn = 'purchase_return';
  static const adjustment = 'adjustment';
}

/// Stock is never edited directly. Every change is a row in
/// `stock_movements`, and the current stock is the sum of those rows.
class StockService {
  StockService(this.db);

  final AppDatabase db;

  /// Current stock in thousandths of a unit.
  Future<int> currentStock(int productId) async {
    final total = db.stockMovements.qty.sum();
    final query = db.selectOnly(db.stockMovements)
      ..addColumns([total])
      ..where(db.stockMovements.productId.equals(productId));
    final row = await query.getSingle();
    return row.read(total) ?? 0;
  }

  /// Adds one movement. [qty] is in thousandths; positive adds stock,
  /// negative removes it. [unitCost] is piastres per whole unit.
  /// Call this inside the same transaction as the document that causes it.
  Future<int> record({
    required int productId,
    required String type,
    required int qty,
    int unitCost = 0,
    String? refType,
    int? refId,
    String? note,
    int? createdBy,
    DateTime? date,
  }) {
    if (qty == 0) {
      throw ArgumentError.value(qty, 'qty', 'A stock movement cannot be zero');
    }
    return db.into(db.stockMovements).insert(
          StockMovementsCompanion.insert(
            productId: productId,
            type: type,
            qty: qty,
            unitCost: Value(unitCost),
            refType: Value(refType),
            refId: Value(refId),
            note: Value(note),
            createdBy: Value(createdBy),
            date: date == null ? const Value.absent() : Value(date),
          ),
        );
  }
}
