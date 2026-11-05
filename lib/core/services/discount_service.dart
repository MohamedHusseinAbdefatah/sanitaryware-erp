import 'package:drift/drift.dart';

import '../db/database.dart';
import 'errors.dart';

abstract final class DiscountScope {
  static const supplier = 'supplier';
  static const brand = 'brand';
  static const category = 'category';
  static const product = 'product';
}

/// price minus [bp] basis points (2100 = 21%), rounded to the piastre.
int applyDiscount(int price, int bp) => price - (price * bp + 5000) ~/ 10000;

class DiscountRuleRow {
  const DiscountRuleRow(this.rule, this.supplierName, this.targetName);

  final DiscountRule rule;
  final String supplierName;

  /// The brand, category or product the rule is about; empty for a whole supplier.
  final String targetName;
}

/// Optional supplier discounts. With no rule, the discount is zero.
class DiscountService {
  DiscountService(this.db);

  final AppDatabase db;

  Future<int> addRule({
    required int supplierId,
    required String scope,
    required int percentBp,
    int? brandId,
    int? categoryId,
    int? productId,
    DateTime? validFrom,
    DateTime? validTo,
    String? note,
  }) async {
    if (percentBp < 0 || percentBp > 10000) {
      throw ValidationException('نسبة الخصم يجب أن تكون بين 0 و 100');
    }
    final target = switch (scope) {
      DiscountScope.supplier => true,
      DiscountScope.brand => brandId != null,
      DiscountScope.category => categoryId != null,
      DiscountScope.product => productId != null,
      _ => throw ArgumentError.value(scope, 'scope'),
    };
    if (!target) throw ValidationException('اختر الصنف أو الماركة أو التصنيف الذي يخصه الخصم');
    if (validFrom != null && validTo != null && validTo.isBefore(validFrom)) {
      throw ValidationException('تاريخ نهاية الخصم قبل بدايته');
    }
    return db.into(db.discountRules).insert(DiscountRulesCompanion.insert(
          supplierId: supplierId,
          scope: scope,
          percentBp: percentBp,
          brandId: Value(scope == DiscountScope.brand ? brandId : null),
          categoryId: Value(scope == DiscountScope.category ? categoryId : null),
          productId: Value(scope == DiscountScope.product ? productId : null),
          validFrom: Value(validFrom),
          validTo: Value(validTo),
          note: Value(note),
        ));
  }

  /// Every rule, newest first, with readable names.
  Future<List<DiscountRuleRow>> rules() async {
    final suppliers = {for (final s in await db.select(db.suppliers).get()) s.id: s.name};
    final brands = {for (final b in await db.select(db.brands).get()) b.id: b.name};
    final categories = {for (final c in await db.select(db.categories).get()) c.id: c.nameAr};
    final products = {for (final p in await db.select(db.products).get()) p.id: p.nameAr};
    final rows = await (db.select(db.discountRules)..orderBy([(r) => OrderingTerm.desc(r.id)])).get();
    return [
      for (final r in rows)
        DiscountRuleRow(
          r,
          suppliers[r.supplierId] ?? '',
          switch (r.scope) {
            DiscountScope.brand => brands[r.brandId] ?? '',
            DiscountScope.category => categories[r.categoryId] ?? '',
            DiscountScope.product => products[r.productId] ?? '',
            _ => '',
          },
        ),
    ];
  }

  Future<void> setActive(int ruleId, bool active) =>
      (db.update(db.discountRules)..where((r) => r.id.equals(ruleId))).write(
          DiscountRulesCompanion(isActive: Value(active), updatedAt: Value(DateTime.now())));

  /// The discount in basis points that applies to [productId] from
  /// [supplierId] on [asOf]: product rule, else category, else brand, else
  /// the supplier-wide rule, else 0.
  Future<int> percentFor({
    required int supplierId,
    required int productId,
    DateTime? asOf,
  }) async {
    final day = asOf ?? DateTime.now();
    final p = await (db.select(db.products)..where((t) => t.id.equals(productId))).getSingle();
    final rules = await (db.select(db.discountRules)
          ..where((r) => r.supplierId.equals(supplierId) & r.isActive.equals(true)))
        .get();
    DiscountRule? best;
    var bestRank = -1;
    for (final r in rules) {
      if (r.validFrom != null && day.isBefore(r.validFrom!)) continue;
      if (r.validTo != null && day.isAfter(r.validTo!)) continue;
      final rank = switch (r.scope) {
        DiscountScope.product => r.productId == p.id ? 3 : -1,
        DiscountScope.category => r.categoryId != null && r.categoryId == p.categoryId ? 2 : -1,
        DiscountScope.brand => r.brandId != null && r.brandId == p.brandId ? 1 : -1,
        DiscountScope.supplier => 0,
        _ => -1,
      };
      if (rank < 0) continue;
      if (rank > bestRank || (rank == bestRank && r.id > best!.id)) {
        best = r;
        bestRank = rank;
      }
    }
    return best?.percentBp ?? 0;
  }
}
