import 'package:drift/drift.dart';

import '../db/database.dart';
import 'audit_service.dart';
import 'errors.dart';
import 'stock_service.dart';

abstract final class ReservationStatus {
  static const active = 'active';
  static const released = 'released';
  static const fulfilled = 'fulfilled';
}

class ReservationRow {
  const ReservationRow({
    required this.reservation,
    required this.productName,
    this.customerName,
    this.orderNumber,
  });

  final Reservation reservation;
  final String productName;
  final String? customerName;

  /// The customer order it holds stock for.
  final String? orderNumber;
}

/// Holds stock back for a customer without moving it. A reservation that has
/// passed its date no longer counts.
class ReservationService {
  ReservationService(this.db);

  final AppDatabase db;

  bool _counts(Reservation r, DateTime now) =>
      r.status == ReservationStatus.active && (r.expiresAt == null || r.expiresAt!.isAfter(now));

  /// Reserved quantity of a product (at one place, or everywhere).
  Future<int> reservedQty(int productId, {int? locationId, DateTime? asOf}) async {
    final now = asOf ?? DateTime.now();
    final rows = await (db.select(db.reservations)
          ..where((r) => r.productId.equals(productId) & r.status.equals(ReservationStatus.active)))
        .get();
    return rows
        .where((r) => _counts(r, now) && (locationId == null || r.locationId == locationId))
        .fold<int>(0, (a, r) => a + r.qty);
  }

  /// Reserved for anyone except [customerId] (a null customer has no
  /// reservations of their own, so everything counts against them).
  Future<int> reservedByOthers(int productId, int? customerId) async {
    final now = DateTime.now();
    final rows = await (db.select(db.reservations)
          ..where((r) => r.productId.equals(productId) & r.status.equals(ReservationStatus.active)))
        .get();
    return rows
        .where((r) => _counts(r, now) && (customerId == null || r.customerId != customerId))
        .fold<int>(0, (a, r) => a + r.qty);
  }

  /// A sale to [customerId] uses up that customer's reservations of the
  /// product, oldest first: a whole one is fulfilled, the last one shrinks.
  Future<void> consumeForCustomer(int customerId, int productId, int qty, {int? userId}) async {
    var left = qty;
    final rows = await (db.select(db.reservations)
          ..where((r) =>
              r.productId.equals(productId) &
              r.customerId.equals(customerId) &
              r.status.equals(ReservationStatus.active))
          ..orderBy([(r) => OrderingTerm.asc(r.id)]))
        .get();
    final now = DateTime.now();
    for (final r in rows) {
      if (left <= 0) break;
      if (!_counts(r, now)) continue;
      if (r.qty <= left) {
        left -= r.qty;
        await _close(r.id, ReservationStatus.fulfilled, userId);
      } else {
        await (db.update(db.reservations)..where((t) => t.id.equals(r.id))).write(
            ReservationsCompanion(qty: Value(r.qty - left), updatedAt: Value(DateTime.now())));
        left = 0;
      }
    }
  }

  /// Stock that can still be promised: on hand minus reserved.
  Future<int> availableQty(int productId, {int? locationId}) async {
    final onHand = await StockService(db).currentStock(productId, locationId: locationId);
    return onHand - await reservedQty(productId, locationId: locationId);
  }

  Future<int> reserve({
    required int productId,
    required int qty,
    int? customerId,
    int locationId = mainLocationId,
    DateTime? expiresAt,
    String? note,
    int? userId,
  }) {
    return db.transaction(() async {
      if (qty <= 0) throw ValidationException('الكمية يجب أن تكون أكبر من صفر');
      final product = await (db.select(db.products)..where((t) => t.id.equals(productId))).getSingleOrNull();
      if (product == null) throw ValidationException('الصنف غير موجود');
      if (expiresAt != null && !expiresAt.isAfter(DateTime.now())) {
        throw ValidationException('تاريخ انتهاء الحجز يجب أن يكون في المستقبل');
      }
      final available = await availableQty(productId, locationId: locationId);
      if (available < qty) {
        throw ValidationException('الكمية المتاحة للحجز أقل من المطلوب');
      }
      final id = await db.into(db.reservations).insert(ReservationsCompanion.insert(
            productId: productId,
            qty: qty,
            customerId: Value(customerId),
            locationId: Value(locationId),
            expiresAt: Value(expiresAt),
            note: Value((note ?? '').trim().isEmpty ? null : note!.trim()),
          ));
      await AuditService(db).log(action: AuditAction.create, entity: 'reservation', entityId: id, userId: userId);
      return id;
    });
  }

  /// Stock that can be held for an order now: sellable stock less what is
  /// already held for anyone.
  Future<int> freeToHold(int productId) async =>
      await StockService(db).sellableStock(productId) - await reservedQty(productId);

  /// Held for one customer order line.
  Future<int> heldForLine(int salesOrderLineId) async {
    final rows = await (db.select(db.reservations)
          ..where((r) => r.salesOrderLineId.equals(salesOrderLineId) & r.status.equals(ReservationStatus.active)))
        .get();
    return rows.fold<int>(0, (a, r) => a + r.qty);
  }

  /// Holds up to [wanted] of the line's product for its customer, as much as
  /// is free now. Returns what was held (0 when nothing is free).
  Future<int> holdForLine(SalesOrderLine line, int customerId, int wanted, {String? note, int? userId}) async {
    if (wanted <= 0) return 0;
    final free = await freeToHold(line.productId);
    final qty = wanted < free ? wanted : free;
    if (qty <= 0) return 0;
    final id = await db.into(db.reservations).insert(ReservationsCompanion.insert(
          productId: line.productId,
          qty: qty,
          customerId: Value(customerId),
          salesOrderLineId: Value(line.id),
          note: Value(note),
        ));
    await AuditService(db).log(action: AuditAction.create, entity: 'reservation', entityId: id, userId: userId);
    return qty;
  }

  /// Gives back everything still held for these order lines.
  Future<void> releaseLines(Iterable<int> salesOrderLineIds, {int? userId}) async {
    final ids = salesOrderLineIds.toList();
    if (ids.isEmpty) return;
    final rows = await (db.select(db.reservations)
          ..where((r) => r.salesOrderLineId.isIn(ids) & r.status.equals(ReservationStatus.active)))
        .get();
    for (final r in rows) {
      await _close(r.id, ReservationStatus.released, userId);
    }
  }

  Future<void> release(int id, {int? userId}) => _close(id, ReservationStatus.released, userId);

  Future<void> markFulfilled(int id, {int? userId}) => _close(id, ReservationStatus.fulfilled, userId);

  Future<void> _close(int id, String status, int? userId) {
    return db.transaction(() async {
      final r = await (db.select(db.reservations)..where((t) => t.id.equals(id))).getSingleOrNull();
      if (r == null) throw ValidationException('الحجز غير موجود');
      if (r.status != ReservationStatus.active) throw ValidationException('هذا الحجز مغلق بالفعل');
      await (db.update(db.reservations)..where((t) => t.id.equals(id))).write(
          ReservationsCompanion(status: Value(status), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(action: AuditAction.update, entity: 'reservation', entityId: id, userId: userId);
    });
  }

  /// Reservations that still count, newest first.
  Stream<List<ReservationRow>> watchActive() {
    final q = db.select(db.reservations).join([
      innerJoin(db.products, db.products.id.equalsExp(db.reservations.productId)),
      leftOuterJoin(db.customers, db.customers.id.equalsExp(db.reservations.customerId)),
      leftOuterJoin(db.salesOrderLines, db.salesOrderLines.id.equalsExp(db.reservations.salesOrderLineId)),
      leftOuterJoin(db.salesOrders, db.salesOrders.id.equalsExp(db.salesOrderLines.orderId)),
    ])
      ..where(db.reservations.status.equals(ReservationStatus.active))
      ..orderBy([OrderingTerm.desc(db.reservations.id)]);
    return q.watch().map((rows) {
      final now = DateTime.now();
      return [
        for (final r in rows)
          if (_counts(r.readTable(db.reservations), now))
            ReservationRow(
              reservation: r.readTable(db.reservations),
              productName: r.readTable(db.products).nameAr,
              customerName: r.readTableOrNull(db.customers)?.name,
              orderNumber: r.readTableOrNull(db.salesOrders)?.number,
            ),
      ];
    });
  }
}
