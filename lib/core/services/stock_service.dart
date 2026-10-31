import 'package:drift/drift.dart';

import '../db/database.dart';
import '../quantity.dart';
import 'audit_service.dart';
import 'errors.dart';

abstract final class StockMovementType {
  static const opening = 'opening';
  static const purchase = 'purchase';
  static const purchaseCancel = 'purchase_cancel';
  static const sale = 'sale';
  static const saleCancel = 'sale_cancel';
  static const saleReturn = 'sale_return';
  static const purchaseReturn = 'purchase_return';
  static const adjustment = 'adjustment';
  static const returnCancel = 'return_cancel';
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

  /// A counted correction (breakage, stock-take). [delta] is in thousandths;
  /// the reason is required and the result may not go below zero.
  Future<void> adjust({
    required int productId,
    required int delta,
    required String reason,
    int? userId,
  }) {
    return db.transaction(() async {
      if (delta == 0) throw ValidationException('أدخل كمية التسوية');
      if (reason.trim().isEmpty) throw ValidationException('سبب التسوية مطلوب');
      final product = await (db.select(db.products)..where((t) => t.id.equals(productId)))
          .getSingle();
      final unit = product.unitId == null
          ? null
          : await (db.select(db.units)..where((t) => t.id.equals(product.unitId!))).getSingle();
      if (!(unit?.allowDecimal ?? false) && !isWholeQty(delta)) {
        throw ValidationException('الكمية يجب أن تكون رقماً صحيحاً لهذه الوحدة');
      }
      final after = await currentStock(productId) + delta;
      if (delta < 0 && after < 0) {
        throw ValidationException('الرصيد بعد التسوية سيكون أقل من صفر');
      }
      await record(
        productId: productId,
        type: StockMovementType.adjustment,
        qty: delta,
        unitCost: product.costPrice,
        note: reason.trim(),
        createdBy: userId,
      );
      await AuditService(db).log(
        action: AuditAction.update,
        entity: 'stock',
        entityId: productId,
        userId: userId,
        details: 'تسوية ${formatQty(delta)}: ${reason.trim()}',
      );
    });
  }

  /// Every movement of one product, newest first (the stock card).
  Stream<List<StockMovement>> watchMovements(int productId) {
    return (db.select(db.stockMovements)
          ..where((t) => t.productId.equals(productId))
          ..orderBy([
            (t) => OrderingTerm.desc(t.date),
            (t) => OrderingTerm.desc(t.id),
          ]))
        .watch();
  }
}
