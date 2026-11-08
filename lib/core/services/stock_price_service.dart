import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import 'audit_service.dart';
import 'errors.dart';
import 'price_list_service.dart';

/// Whether stock came in under the price in force today.
enum StockPriceKind {
  /// Its list price is today's price.
  current('بالسعر الجديد'),

  /// It came in under a price that has since changed.
  old('بالسعر القديم'),

  /// Nobody has said which list it came in under; none is guessed.
  unknown('غير محدد');

  const StockPriceKind(this.label);
  final String label;
}

/// One group of a product's stock: the same list version and list price.
class StockPriceLine {
  StockPriceLine({
    required this.kind,
    this.priceListId,
    this.versionLabel,
    this.listPrice,
    this.currentPrice,
  });

  final StockPriceKind kind;
  final int? priceListId;
  final String? versionLabel;
  final int? listPrice;

  /// Today's list price of the product, for comparing. Null when it has none.
  final int? currentPrice;
  int qty = 0;

  /// Actual FIFO cost of this stock.
  int value = 0;

  /// Place name -> quantity.
  final places = <String, int>{};
}

/// How much of a product is at the new price, the old one, or unknown.
class StockPriceSummary {
  const StockPriceSummary({this.current = 0, this.old = 0, this.unknown = 0});

  final int current;
  final int old;
  final int unknown;
}

class _CurrentPrice {
  const _CurrentPrice(this.listId, this.price);
  final int listId;
  final int price;
}

/// Answers "how much do I have at the old price and at the new price?".
///
/// Each FIFO layer remembers the list version it came in under. That is
/// compared with the prices in force today. A later version with the same
/// price counts as the new price, because the price did not change.
class StockPriceService {
  StockPriceService(this.db);

  final AppDatabase db;

  /// Today's prices per product: the newest version in force of each brand and
  /// list type that has the product.
  Future<Map<int, List<_CurrentPrice>>> _currentPrices() async {
    final now = DateTime.now();
    final rows = await (db.select(db.priceListItems).join([
      innerJoin(db.priceLists, db.priceLists.id.equalsExp(db.priceListItems.priceListId)),
    ])
          ..where(db.priceListItems.status.equals(PriceRowStatus.ok) & db.priceListItems.productId.isNotNull())
          ..orderBy([OrderingTerm.desc(db.priceLists.versionNo), OrderingTerm.desc(db.priceLists.id)]))
        .get();
    final seen = <String>{};
    final out = <int, List<_CurrentPrice>>{};
    for (final r in rows) {
      final list = r.readTable(db.priceLists);
      final item = r.readTable(db.priceListItems);
      if (item.price == null || !PriceListService.inForce(list, now)) continue;
      if (!seen.add('${item.productId}|${list.brandId}|${list.listType}')) continue;
      (out[item.productId!] ??= []).add(_CurrentPrice(list.id, item.price!));
    }
    return out;
  }

  StockPriceKind _kindOf(CostLayer l, List<_CurrentPrice> today) {
    if (l.priceListId == null) return StockPriceKind.unknown;
    final isNew = today.any((c) => c.listId == l.priceListId || c.price == l.listPrice);
    return isNew ? StockPriceKind.current : StockPriceKind.old;
  }

  /// One product's stock, split by list version and price: new first.
  Future<List<StockPriceLine>> breakdown(int productId) async {
    final layers = await (db.select(db.costLayers)
          ..where((l) => l.productId.equals(productId) & l.qtyRemaining.isBiggerThanValue(0)))
        .get();
    final today = (await _currentPrices())[productId] ?? const <_CurrentPrice>[];
    final lists = {for (final l in await db.select(db.priceLists).get()) l.id: l};
    final places = {for (final l in await db.select(db.locations).get()) l.id: l.name};
    final groups = <String, StockPriceLine>{};
    for (final l in layers) {
      final list = lists[l.priceListId];
      final line = groups.putIfAbsent(
        '${l.priceListId}|${l.listPrice}',
        () => StockPriceLine(
          kind: _kindOf(l, today),
          priceListId: l.priceListId,
          versionLabel: list == null ? null : '${list.listType} V${list.versionNo} (PL-${list.id})',
          listPrice: l.listPrice,
          currentPrice: today.length == 1 ? today.single.price : null,
        ),
      );
      line.qty += l.qtyRemaining;
      line.value += (l.qtyRemaining * l.unitCost + 500) ~/ 1000;
      final place = places[l.locationId] ?? '';
      line.places[place] = (line.places[place] ?? 0) + l.qtyRemaining;
    }
    return groups.values.toList()..sort((a, b) => a.kind.index - b.kind.index);
  }

  Future<Map<int, StockPriceSummary>> summaries() async {
    final layers = await (db.select(db.costLayers)..where((l) => l.qtyRemaining.isBiggerThanValue(0))).get();
    final today = await _currentPrices();
    final sums = <int, List<int>>{};
    for (final l in layers) {
      final s = sums.putIfAbsent(l.productId, () => [0, 0, 0]);
      s[_kindOf(l, today[l.productId] ?? const [])  .index] += l.qtyRemaining;
    }
    return {
      for (final e in sums.entries)
        e.key: StockPriceSummary(current: e.value[0], old: e.value[1], unknown: e.value[2]),
    };
  }

  Stream<Map<int, StockPriceSummary>> watchSummaries() =>
      db.select(db.costLayers).watch().asyncMap((_) => summaries());

  Future<StockPriceSummary> summaryOf(int productId) async =>
      (await summaries())[productId] ?? const StockPriceSummary();

  /// Gives unknown layers a version where their received date leaves exactly
  /// one possible: after a list is imported late, for example.
  Future<void> stampUnknown({Iterable<int>? productIds}) async {
    final ids = productIds?.toSet();
    final layers = await (db.select(db.costLayers)
          ..where((l) => l.priceListId.isNull() & l.qtyRemaining.isBiggerThanValue(0)))
        .get();
    final prices = PriceListService(db);
    for (final l in layers) {
      if (ids != null && !ids.contains(l.productId)) continue;
      final quotes = await prices.quotesFor(l.productId, asOf: l.receivedAt);
      if (quotes.length != 1) continue;
      await (db.update(db.costLayers)..where((t) => t.id.equals(l.id))).write(CostLayersCompanion(
          priceListId: Value(quotes.single.priceListId), listPrice: Value(quotes.single.price)));
    }
  }

  /// A person says which version a product's unknown stock came in under, for
  /// opening stock bought before the list was entered.
  Future<void> assignUnknown(int productId, int priceListId, {required User user}) {
    return db.transaction(() async {
      if (!user.isAdmin) throw ValidationException('تحديد القائمة للمدير فقط');
      final quote = await PriceListService(db).quoteIn(priceListId, productId);
      if (quote == null) throw ValidationException('هذا الصنف غير موجود في القائمة المختارة');
      await (db.update(db.costLayers)
            ..where((l) =>
                l.productId.equals(productId) & l.priceListId.isNull() & l.qtyRemaining.isBiggerThanValue(0)))
          .write(CostLayersCompanion(priceListId: Value(priceListId), listPrice: Value(quote.price)));
      await AuditService(db).log(
        action: AuditAction.update,
        entity: 'stock_price',
        entityId: productId,
        userId: user.id,
        details: 'المخزون غير المحدد ← PL-$priceListId',
      );
    });
  }

  /// Does [assignUnknown] for every product in a version, for go-live. Returns
  /// how many products changed.
  Future<int> assignAllUnknownFrom(int priceListId, {required User user}) {
    return db.transaction(() async {
      if (!user.isAdmin) throw ValidationException('تحديد القائمة للمدير فقط');
      final items = await (db.select(db.priceListItems)
            ..where((i) => i.priceListId.equals(priceListId) & i.status.equals(PriceRowStatus.ok)))
          .get();
      var changed = 0;
      for (final i in items) {
        if (i.productId == null || i.price == null) continue;
        final n = await (db.update(db.costLayers)
              ..where((l) =>
                  l.productId.equals(i.productId!) & l.priceListId.isNull() & l.qtyRemaining.isBiggerThanValue(0)))
            .write(CostLayersCompanion(priceListId: Value(priceListId), listPrice: Value(i.price)));
        if (n > 0) changed++;
      }
      await AuditService(db).log(
        action: AuditAction.update,
        entity: 'stock_price',
        entityId: priceListId,
        userId: user.id,
        details: 'المخزون غير المحدد لعدد $changed صنف ← PL-$priceListId',
      );
      return changed;
    });
  }
}
