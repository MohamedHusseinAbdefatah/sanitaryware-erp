import 'package:drift/drift.dart';

import '../db/database.dart';
import '../quantity.dart';
import 'errors.dart';
import 'price_list_service.dart';
import 'stock_service.dart';

/// One slice of a layer that a use of stock took.
class LayerPiece {
  const LayerPiece({
    required this.layerId,
    required this.qty,
    required this.unitCost,
    required this.receivedAt,
    this.supplierId,
    this.priceListId,
    this.listPrice,
  });

  final int layerId;
  final int qty; // thousandths
  final int unitCost; // piastres per whole unit
  final DateTime receivedAt;
  final int? supplierId;
  final int? priceListId;
  final int? listPrice;

  int get cost => lineAmount(qty, unitCost);
}

/// What a use of stock cost: the exact layers it took.
class FifoTake {
  const FifoTake(this.pieces);

  final List<LayerPiece> pieces;

  int get qty => pieces.fold(0, (s, p) => s + p.qty);
  int get totalCost => pieces.fold(0, (s, p) => s + p.cost);

  /// Average piastres per whole unit.
  int get averageUnitCost => qty == 0 ? 0 : (totalCost * qtyScale / qty).round();
}

/// What one place gave up towards a use of stock.
class LocationTake {
  const LocationTake(this.locationId, this.take);

  final int locationId;
  final FifoTake take;
}

/// FIFO cost layers per (product, location). Call inside the same
/// transaction as the document that causes the change.
class FifoService {
  FifoService(this.db) : _stock = StockService(db);

  final AppDatabase db;
  final StockService _stock;

  Future<int> addLayer({
    required int productId,
    required int qty,
    required int unitCost,
    int locationId = mainLocationId,
    DateTime? receivedAt,
    int? supplierId,
    String? sourceType,
    int? sourceId,
    int? priceListId,
    int? listPrice,
    bool stampFromDate = true,
  }) async {
    if (qty <= 0) throw ArgumentError.value(qty, 'qty', 'A layer needs a positive quantity');
    final received = receivedAt ?? DateTime.now();
    if (priceListId == null && stampFromDate) {
      // The version in force on the day it came in, if exactly one was.
      final quotes = await PriceListService(db).quotesFor(productId, asOf: received);
      if (quotes.length == 1) {
        priceListId = quotes.single.priceListId;
        listPrice = quotes.single.price;
      }
    }
    return db.into(db.costLayers).insert(CostLayersCompanion.insert(
          productId: productId,
          locationId: locationId,
          qtyReceived: qty,
          qtyRemaining: qty,
          unitCost: unitCost,
          receivedAt: received,
          supplierId: Value(supplierId),
          sourceType: Value(sourceType),
          sourceId: Value(sourceId),
          priceListId: Value(priceListId),
          listPrice: Value(listPrice),
        ));
  }

  /// Quantity left in layers (thousandths).
  Future<int> remaining(int productId, {int locationId = mainLocationId}) async {
    final total = db.costLayers.qtyRemaining.sum();
    final q = db.selectOnly(db.costLayers)
      ..addColumns([total])
      ..where(db.costLayers.productId.equals(productId) &
          db.costLayers.locationId.equals(locationId));
    return (await q.getSingle()).read(total) ?? 0;
  }

  /// What taking [qty] would cost now, without taking it: the FIFO cost for
  /// the sale preview, taking [locationIds] in order. The part with no layer is
  /// priced at [lastKnownCost]. Null when the product has never had a cost.
  Future<FifoTake?> peek(int productId, int qty, {List<int> locationIds = const [mainLocationId]}) async {
    final layers = <CostLayer>[];
    for (final id in locationIds) {
      layers.addAll(await (db.select(db.costLayers)
            ..where((l) =>
                l.productId.equals(productId) &
                l.locationId.equals(id) &
                l.qtyRemaining.isBiggerThanValue(0))
            ..orderBy([(l) => OrderingTerm.asc(l.receivedAt), (l) => OrderingTerm.asc(l.id)]))
          .get());
    }
    var need = qty;
    final pieces = <LayerPiece>[];
    for (final l in layers) {
      if (need <= 0) break;
      final take = need < l.qtyRemaining ? need : l.qtyRemaining;
      pieces.add(LayerPiece(layerId: l.id, qty: take, unitCost: l.unitCost, receivedAt: l.receivedAt));
      need -= take;
    }
    if (need > 0) {
      final last = await lastKnownCost(productId);
      if (last == null) return null;
      pieces.add(LayerPiece(layerId: -1, qty: need, unitCost: last, receivedAt: DateTime.now()));
    }
    return FifoTake(pieces);
  }

  /// The newest cost on record: the last layer received, else the last stock
  /// movement that carried a cost. Null when there is none: no cost is made up.
  Future<int?> lastKnownCost(int productId) async {
    final layer = await (db.select(db.costLayers)
          ..where((l) => l.productId.equals(productId))
          ..orderBy([(l) => OrderingTerm.desc(l.receivedAt), (l) => OrderingTerm.desc(l.id)])
          ..limit(1))
        .getSingleOrNull();
    if (layer != null) return layer.unitCost;
    final move = await (db.select(db.stockMovements)
          ..where((m) => m.productId.equals(productId) & m.unitCost.isBiggerThanValue(0))
          ..orderBy([(m) => OrderingTerm.desc(m.date), (m) => OrderingTerm.desc(m.id)])
          ..limit(1))
        .getSingleOrNull();
    return move?.unitCost;
  }

  /// Takes [qty] from the oldest layers first. Throws [ValidationException]
  /// (and changes nothing) when there is not enough. With [fromPurchaseId],
  /// that purchase's own layers are taken first: goods sent back to the
  /// supplier leave at the cost they came in at.
  Future<FifoTake> consume({
    required int productId,
    required int qty,
    required String refType,
    int? refId,
    int locationId = mainLocationId,
    DateTime? date,
    int? fallbackCost,
    int? fromPurchaseId,
  }) {
    if (qty <= 0) throw ArgumentError.value(qty, 'qty', 'Quantity must be positive');
    return db.transaction(() async {
      final oldestFirst = await (db.select(db.costLayers)
            ..where((l) =>
                l.productId.equals(productId) &
                l.locationId.equals(locationId) &
                l.qtyRemaining.isBiggerThanValue(0))
            ..orderBy([(l) => OrderingTerm.asc(l.receivedAt), (l) => OrderingTerm.asc(l.id)]))
          .get();
      bool own(CostLayer l) => l.sourceType == 'purchase' && l.sourceId == fromPurchaseId;
      final layers = fromPurchaseId == null
          ? oldestFirst
          : [...oldestFirst.where(own), ...oldestFirst.where((l) => !own(l))];
      final available = layers.fold<int>(0, (s, l) => s + l.qtyRemaining);
      if (available < qty && fallbackCost == null) {
        throw ValidationException(
            'الكمية المتاحة (${formatQty(available)}) أقل من المطلوبة (${formatQty(qty)})');
      }
      var need = qty;
      final pieces = <LayerPiece>[];
      for (final l in layers) {
        if (need == 0) break;
        final take = need < l.qtyRemaining ? need : l.qtyRemaining;
        await (db.update(db.costLayers)..where((t) => t.id.equals(l.id)))
            .write(CostLayersCompanion(qtyRemaining: Value(l.qtyRemaining - take)));
        await db.into(db.layerConsumptions).insert(LayerConsumptionsCompanion.insert(
              layerId: l.id,
              qty: take,
              unitCost: l.unitCost,
              refType: refType,
              refId: Value(refId),
              date: date == null ? const Value.absent() : Value(date),
            ));
        pieces.add(LayerPiece(
          layerId: l.id,
          qty: take,
          unitCost: l.unitCost,
          receivedAt: l.receivedAt,
          supplierId: l.supplierId,
          priceListId: l.priceListId,
          listPrice: l.listPrice,
        ));
        need -= take;
      }
      if (need > 0) {
        // Only when the caller allows it (negative stock, or stock that
        // never had layers): the rest is priced at [fallbackCost] and has
        // no layer to restore later (layerId -1).
        pieces.add(LayerPiece(
          layerId: -1,
          qty: need,
          unitCost: fallbackCost!,
          receivedAt: date ?? DateTime.now(),
        ));
      }
      return FifoTake(pieces);
    });
  }

  /// Takes [qty] from [locationIds] in order, each only up to what it holds.
  /// Anything past that (negative stock, when allowed) comes off the first
  /// place at [fallbackCost]. The caller records a movement for each part, so
  /// stock and layers stay together place by place.
  Future<List<LocationTake>> consumeAcross({
    required int productId,
    required int qty,
    required List<int> locationIds,
    required String refType,
    int? refId,
    DateTime? date,
    required int fallbackCost,
    int? fromPurchaseId,
  }) {
    return db.transaction(() async {
      final ids = locationIds.isEmpty ? const [mainLocationId] : locationIds;
      var left = qty;
      final parts = <LocationTake>[];
      for (final id in ids) {
        if (left == 0) break;
        final onHand = await _stock.currentStock(productId, locationId: id);
        if (onHand <= 0) continue;
        final take = left < onHand ? left : onHand;
        parts.add(LocationTake(
          id,
          await consume(
            productId: productId,
            qty: take,
            refType: refType,
            refId: refId,
            locationId: id,
            date: date,
            fallbackCost: fallbackCost,
            fromPurchaseId: fromPurchaseId,
          ),
        ));
        left -= take;
      }
      if (left > 0) {
        parts.add(LocationTake(
          ids.first,
          await consume(
            productId: productId,
            qty: left,
            refType: refType,
            refId: refId,
            locationId: ids.first,
            date: date,
            fallbackCost: fallbackCost,
          ),
        ));
      }
      return parts;
    });
  }

  /// Moves stock between locations. Cost and received date travel with it.
  Future<FifoTake> transfer({
    required int productId,
    required int qty,
    required int fromLocationId,
    required int toLocationId,
    int? refId,
    int? createdBy,
    DateTime? date,
  }) {
    if (fromLocationId == toLocationId) {
      throw ValidationException('لا يمكن التحويل إلى نفس المكان');
    }
    return db.transaction(() async {
      final take = await consume(
        productId: productId,
        qty: qty,
        refType: 'transfer',
        refId: refId,
        locationId: fromLocationId,
        date: date,
      );
      for (final p in take.pieces) {
        await addLayer(
          productId: productId,
          qty: p.qty,
          unitCost: p.unitCost,
          locationId: toLocationId,
          receivedAt: p.receivedAt,
          supplierId: p.supplierId,
          sourceType: 'transfer',
          sourceId: refId,
          priceListId: p.priceListId,
          listPrice: p.listPrice,
          stampFromDate: false,
        );
      }
      await _stock.record(
        productId: productId,
        type: StockMovementType.transferOut,
        qty: -qty,
        unitCost: take.averageUnitCost,
        refType: 'transfer',
        refId: refId,
        createdBy: createdBy,
        date: date,
        locationId: fromLocationId,
      );
      await _stock.record(
        productId: productId,
        type: StockMovementType.transferIn,
        qty: qty,
        unitCost: take.averageUnitCost,
        refType: 'transfer',
        refId: refId,
        createdBy: createdBy,
        date: date,
        locationId: toLocationId,
      );
      return take;
    });
  }

  /// Undoes every use of stock recorded under ([refType], [refId]):
  /// layers get their quantity back. Throws if there is nothing to undo.
  Future<void> reverse(String refType, int refId) {
    return db.transaction(() async {
      final rows = await (db.select(db.layerConsumptions)
            ..where((c) => c.refType.equals(refType) & c.refId.equals(refId)))
          .get();
      final net = <int, int>{};
      for (final r in rows) {
        net[r.layerId] = (net[r.layerId] ?? 0) + r.qty;
      }
      net.removeWhere((_, v) => v <= 0);
      if (net.isEmpty) {
        throw ValidationException('لا توجد حركة لعكسها أو تم عكسها من قبل');
      }
      for (final e in net.entries) {
        final layer = await (db.select(db.costLayers)..where((l) => l.id.equals(e.key))).getSingle();
        await (db.update(db.costLayers)..where((l) => l.id.equals(e.key)))
            .write(CostLayersCompanion(qtyRemaining: Value(layer.qtyRemaining + e.value)));
        await db.into(db.layerConsumptions).insert(LayerConsumptionsCompanion.insert(
              layerId: e.key,
              qty: -e.value,
              unitCost: layer.unitCost,
              refType: refType,
              refId: Value(refId),
            ));
      }
    });
  }

  /// Like [reverse] but quiet: undoes whatever ([refType], [refId]) took
  /// and returns how much went back per product (empty if nothing, e.g. a
  /// document made before cost layers existed).
  Future<Map<int, int>> reverseAll(String refType, int refId) {
    return db.transaction(() async {
      final rows = await (db.select(db.layerConsumptions)
            ..where((c) => c.refType.equals(refType) & c.refId.equals(refId)))
          .get();
      final net = <int, int>{};
      for (final r in rows) {
        net[r.layerId] = (net[r.layerId] ?? 0) + r.qty;
      }
      net.removeWhere((_, v) => v <= 0);
      final perProduct = <int, int>{};
      for (final e in net.entries) {
        final layer = await (db.select(db.costLayers)..where((l) => l.id.equals(e.key))).getSingle();
        await (db.update(db.costLayers)..where((l) => l.id.equals(e.key)))
            .write(CostLayersCompanion(qtyRemaining: Value(layer.qtyRemaining + e.value)));
        await db.into(db.layerConsumptions).insert(LayerConsumptionsCompanion.insert(
              layerId: e.key,
              qty: -e.value,
              unitCost: layer.unitCost,
              refType: refType,
              refId: Value(refId),
            ));
        perProduct[layer.productId] = (perProduct[layer.productId] ?? 0) + e.value;
      }
      return perProduct;
    });
  }

  /// Takes back the layers a purchase created (nothing is deleted: they are
  /// emptied). Returns what was emptied as (product, place, quantity).
  Future<List<(int, int, int)>> voidSourceLayers(String sourceType, int sourceId) async {
    final layers = await (db.select(db.costLayers)
          ..where((l) => l.sourceType.equals(sourceType) & l.sourceId.equals(sourceId)))
        .get();
    final emptied = <(int, int, int)>[];
    for (final l in layers) {
      if (l.qtyRemaining == 0) continue;
      await (db.update(db.costLayers)..where((t) => t.id.equals(l.id)))
          .write(const CostLayersCompanion(qtyRemaining: Value(0)));
      emptied.add((l.productId, l.locationId, l.qtyRemaining));
    }
    return emptied;
  }

  /// Cost of goods used by ([refType], [refId]), net of reversals.
  Future<int> costOf(String refType, int refId) async {
    final rows = await (db.select(db.layerConsumptions)
          ..where((c) => c.refType.equals(refType) & c.refId.equals(refId)))
        .get();
    return rows.fold<int>(0, (s, r) => s + lineAmount(r.qty, r.unitCost));
  }
}
