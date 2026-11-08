import 'package:drift/drift.dart';

import '../db/database.dart';
import 'fifo_service.dart';
import '../quantity.dart';
import 'audit_service.dart';
import 'errors.dart';

/// The main warehouse; every location-less call means this one.
const mainLocationId = 1;

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
  static const transferOut = 'transfer_out';
  static const transferIn = 'transfer_in';
}

/// Stock is never edited directly. Every change is a row in
/// `stock_movements`, and the current stock is the sum of those rows.
class StockService {
  StockService(this.db);

  final AppDatabase db;

  /// Current stock in thousandths of a unit, in all locations or only in
  /// [locationId].
  Future<int> currentStock(int productId, {int? locationId}) async {
    final total = db.stockMovements.qty.sum();
    Expression<bool> where = db.stockMovements.productId.equals(productId);
    if (locationId != null) {
      where = where & db.stockMovements.locationId.equals(locationId);
    }
    final query = db.selectOnly(db.stockMovements)
      ..addColumns([total])
      ..where(where);
    final row = await query.getSingle();
    return row.read(total) ?? 0;
  }

  /// Active places goods can be sold from, the main warehouse first.
  Future<List<int>> sellableLocationIds() async {
    final rows = await (db.select(db.locations)
          ..where((l) => l.isActive.equals(true) & l.isSellable.equals(true))
          ..orderBy([(l) => OrderingTerm.asc(l.id)]))
        .get();
    return [for (final l in rows) l.id];
  }

  /// Every place, the main warehouse first.
  Future<List<int>> allLocationIds() async {
    final rows = await (db.select(db.locations)..orderBy([(l) => OrderingTerm.asc(l.id)])).get();
    return [for (final l in rows) l.id];
  }

  /// Stock that can be sold: display-only places do not count.
  Future<int> sellableStock(int productId) async {
    var total = 0;
    for (final id in await sellableLocationIds()) {
      total += await currentStock(productId, locationId: id);
    }
    return total;
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
    int locationId = mainLocationId,
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
            locationId: Value(locationId),
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
    int locationId = mainLocationId,
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
      final after = await currentStock(productId, locationId: locationId) + delta;
      if (delta < 0 && after < 0) {
        throw ValidationException('الرصيد بعد التسوية سيكون أقل من صفر');
      }
      final fifo = FifoService(db);
      final cost = await fifo.lastKnownCost(productId) ?? 0;
      await record(
        productId: productId,
        type: StockMovementType.adjustment,
        qty: delta,
        unitCost: cost,
        note: reason.trim(),
        createdBy: userId,
        locationId: locationId,
      );
      if (delta > 0) {
        await fifo.addLayer(
            productId: productId, qty: delta, unitCost: cost, locationId: locationId, sourceType: 'adjustment');
      } else {
        await fifo.consume(
          productId: productId,
          qty: -delta,
          refType: 'adjustment',
          locationId: locationId,
          fallbackCost: cost,
        );
      }
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
