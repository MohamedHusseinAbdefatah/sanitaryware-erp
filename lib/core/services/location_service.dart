import 'package:drift/drift.dart';

import '../db/database.dart';
import 'audit_service.dart';
import 'errors.dart';
import 'fifo_service.dart';
import 'stock_service.dart';

abstract final class LocationKind {
  static const warehouse = 'warehouse';
  static const showroomDisplay = 'showroom_display';
  static const showroomStorage = 'showroom_storage';
  static const other = 'other';
  static const all = [warehouse, showroomDisplay, showroomStorage, other];

  static String label(String kind) => switch (kind) {
        warehouse => 'مخزن',
        showroomDisplay => 'معرض - عرض',
        showroomStorage => 'معرض - تخزين',
        _ => 'آخر',
      };
}

/// Places stock can be kept (warehouse, showroom ...) and moves between them.
/// Location 1 is the main warehouse and always stays active.
class LocationService {
  LocationService(this.db);

  final AppDatabase db;

  Future<List<Location>> all({bool activeOnly = false}) {
    final q = db.select(db.locations)..orderBy([(t) => OrderingTerm(expression: t.id)]);
    if (activeOnly) q.where((t) => t.isActive);
    return q.get();
  }

  Stream<List<Location>> watchAll() {
    final q = db.select(db.locations)..orderBy([(t) => OrderingTerm(expression: t.id)]);
    return q.watch();
  }

  Future<int> create({
    required String name,
    String kind = LocationKind.warehouse,
    bool isSellable = true,
    int? userId,
  }) async {
    final clean = await _checkName(name, null);
    _checkKind(kind);
    final id = await db.into(db.locations).insert(LocationsCompanion.insert(
          name: clean,
          kind: Value(kind),
          isSellable: Value(isSellable),
        ));
    await AuditService(db).log(action: AuditAction.create, entity: 'location', entityId: id, userId: userId);
    return id;
  }

  Future<void> update(
    int id, {
    required String name,
    required String kind,
    required bool isSellable,
    required bool isActive,
    int? userId,
  }) async {
    final clean = await _checkName(name, id);
    _checkKind(kind);
    if (id == mainLocationId && !isActive) {
      throw ValidationException('لا يمكن إيقاف المخزن الرئيسي');
    }
    await (db.update(db.locations)..where((t) => t.id.equals(id))).write(LocationsCompanion(
      name: Value(clean),
      kind: Value(kind),
      isSellable: Value(isSellable),
      isActive: Value(isActive),
      updatedAt: Value(DateTime.now()),
    ));
    await AuditService(db).log(action: AuditAction.update, entity: 'location', entityId: id, userId: userId);
  }

  /// Quantity of one product at each location (only where it is not zero).
  Future<Map<int, int>> stockByLocation(int productId) async {
    final out = <int, int>{};
    for (final l in await all()) {
      final q = await StockService(db).currentStock(productId, locationId: l.id);
      if (q != 0) out[l.id] = q;
    }
    return out;
  }

  /// Moves [qty] (thousandths) of a product between two places. The cost and
  /// the received date travel with the stock.
  Future<void> transfer({
    required int productId,
    required int qty,
    required int fromLocationId,
    required int toLocationId,
    int? userId,
  }) {
    return db.transaction(() async {
      if (qty <= 0) throw ValidationException('الكمية يجب أن تكون أكبر من صفر');
      if (fromLocationId == toLocationId) {
        throw ValidationException('لا يمكن التحويل إلى نفس المكان');
      }
      final product = await (db.select(db.products)..where((t) => t.id.equals(productId))).getSingleOrNull();
      if (product == null) throw ValidationException('الصنف غير موجود');
      for (final id in [fromLocationId, toLocationId]) {
        final l = await (db.select(db.locations)..where((t) => t.id.equals(id))).getSingleOrNull();
        if (l == null || !l.isActive) throw ValidationException('المكان غير موجود أو موقوف');
      }
      final available = await StockService(db).currentStock(productId, locationId: fromLocationId);
      if (available < qty) {
        throw ValidationException('الكمية المتاحة في المكان المحوَّل منه أقل من المطلوب');
      }
      await FifoService(db).transfer(
        productId: productId,
        qty: qty,
        fromLocationId: fromLocationId,
        toLocationId: toLocationId,
        createdBy: userId,
      );
      await AuditService(db)
          .log(action: AuditAction.create, entity: 'stock_transfer', entityId: productId, userId: userId);
    });
  }

  Future<String> _checkName(String name, int? exceptId) async {
    final clean = name.trim();
    if (clean.isEmpty) throw ValidationException('اسم المكان مطلوب');
    final same = await (db.select(db.locations)..where((t) => t.name.equals(clean))).get();
    final dup = same.where((l) => l.id != exceptId);
    if (dup.isNotEmpty) throw ValidationException('يوجد مكان بنفس الاسم');
    return clean;
  }

  void _checkKind(String kind) {
    if (!LocationKind.all.contains(kind)) throw ArgumentError.value(kind, 'kind');
  }
}
