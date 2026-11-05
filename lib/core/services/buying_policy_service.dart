import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../pricing_math.dart';
import 'audit_service.dart';
import 'errors.dart';
import 'price_list_service.dart';

/// Scope of a buying or selling policy. Priority: product, then category,
/// then all (blueprint 3.4).
abstract final class PolicyScope {
  static const all = 'all';
  static const category = 'category';
  static const product = 'product';

  static const values = [all, category, product];

  static String label(String scope) => switch (scope) {
        category => 'تصنيف',
        product => 'صنف',
        _ => 'كل الأصناف',
      };

  /// How well a rule's scope fits a product; -1 means it does not apply.
  static int rank(String scope, int? ruleCategoryId, int? ruleProductId, Product p) => switch (scope) {
        product => ruleProductId == p.id ? 2 : -1,
        category =>
          ruleCategoryId != null && (ruleCategoryId == p.categoryId || ruleCategoryId == p.subcategoryId) ? 1 : -1,
        all => 0,
        _ => -1,
      };
}

class BuyingPolicyInput {
  const BuyingPolicyInput({
    required this.supplierId,
    required this.brandId,
    required this.priceListId,
    this.scope = PolicyScope.all,
    this.categoryId,
    this.productId,
    this.baseDiscountBp = 0,
    this.extraDiscountBp = 0,
    this.validFrom,
    this.validTo,
    this.note,
  });

  final int supplierId;
  final int brandId;
  final int priceListId;
  final String scope;
  final int? categoryId;
  final int? productId;
  final int baseDiscountBp;
  final int extraDiscountBp;
  final DateTime? validFrom;
  final DateTime? validTo;
  final String? note;
}

class BuyingPolicyRow {
  const BuyingPolicyRow(this.policy, this.supplierName, this.brandName, this.listLabel, this.targetName);

  final BuyingPolicy policy;
  final String supplierName;
  final String? brandName;
  final String? listLabel;
  final String targetName;

  /// Brought over from an old version: it cannot be used until completed.
  bool get incomplete => policy.brandId == null || policy.priceListId == null;
}

/// What a product costs from a supplier under one version.
class BuyQuote {
  const BuyQuote({required this.quote, this.policy, this.vatStatus, this.vatRateBp});

  final PriceQuote quote;

  /// Null means no recorded policy: the cost stays unknown, no percentage is
  /// assumed.
  final BuyingPolicy? policy;
  final String? vatStatus;
  final int? vatRateBp;

  int get listPrice => quote.price;
  int get baseBp => policy?.baseDiscountBp ?? 0;
  int get extraBp => policy?.extraDiscountBp ?? 0;
  bool get missingPolicy => policy == null;

  /// List price less the recorded discounts. Null with no policy.
  int? get netCost {
    if (policy == null) return null;
    final bp = baseBp + extraBp;
    return applyDiscount(listPrice, bp > 10000 ? 10000 : bp);
  }

  /// Null unless the VAT basis and rate are verified.
  VatSplit? get vat => netCost == null ? null : vatOf(netCost!, vatStatus, vatRateBp);
}

/// Buying policies: Supplier + Brand + Price List, then scope. Entirely apart
/// from selling policies.
class BuyingPolicyService {
  BuyingPolicyService(this.db);

  final AppDatabase db;

  void _admin(User user) {
    if (!user.isAdmin) throw ValidationException('سياسات الشراء للمدير فقط');
  }

  Future<int> add(BuyingPolicyInput input, {required User user}) {
    return db.transaction(() async {
      _admin(user);
      _checkPercent(input.baseDiscountBp);
      _checkPercent(input.extraDiscountBp);
      if (input.baseDiscountBp + input.extraDiscountBp > 10000) {
        throw ValidationException('مجموع الخصمين أكبر من 100%');
      }
      final target = switch (input.scope) {
        PolicyScope.all => true,
        PolicyScope.category => input.categoryId != null,
        PolicyScope.product => input.productId != null,
        _ => throw ArgumentError.value(input.scope, 'scope'),
      };
      if (!target) throw ValidationException('اختر الصنف أو التصنيف الذي تخصه السياسة');
      if (input.validFrom != null && input.validTo != null && input.validTo!.isBefore(input.validFrom!)) {
        throw ValidationException('نهاية السياسة قبل بدايتها');
      }
      final list = await (db.select(db.priceLists)..where((l) => l.id.equals(input.priceListId))).getSingleOrNull();
      if (list == null) throw ValidationException('اختر قائمة الأسعار');
      if (list.brandId != input.brandId) throw ValidationException('القائمة المختارة ليست لهذه الماركة');
      final id = await db.into(db.buyingPolicies).insert(BuyingPoliciesCompanion.insert(
            supplierId: input.supplierId,
            brandId: Value(input.brandId),
            priceListId: Value(input.priceListId),
            scope: input.scope,
            categoryId: Value(input.scope == PolicyScope.category ? input.categoryId : null),
            productId: Value(input.scope == PolicyScope.product ? input.productId : null),
            baseDiscountBp: Value(input.baseDiscountBp),
            extraDiscountBp: Value(input.extraDiscountBp),
            validFrom: Value(input.validFrom),
            validTo: Value(input.validTo),
            note: Value((input.note ?? '').trim().isEmpty ? null : input.note!.trim()),
          ));
      await AuditService(db).log(
          action: AuditAction.create,
          entity: 'buying_policy',
          entityId: id,
          userId: user.id,
          details: '${input.baseDiscountBp / 100}% + ${input.extraDiscountBp / 100}%');
      return id;
    });
  }

  void _checkPercent(int bp) {
    if (bp < 0 || bp > 10000) throw ValidationException('نسبة الخصم يجب أن تكون بين 0 و 100');
  }

  Future<void> setActive(int id, bool active, {required User user}) {
    return db.transaction(() async {
      _admin(user);
      final p = await (db.select(db.buyingPolicies)..where((t) => t.id.equals(id))).getSingle();
      if (active && (p.brandId == null || p.priceListId == null)) {
        throw ValidationException('حدد الماركة وقائمة الأسعار لهذه السياسة أولاً');
      }
      await (db.update(db.buyingPolicies)..where((t) => t.id.equals(id)))
          .write(BuyingPoliciesCompanion(isActive: Value(active), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
          action: AuditAction.update,
          entity: 'buying_policy',
          entityId: id,
          userId: user.id,
          details: active ? 'تفعيل' : 'إيقاف');
    });
  }

  /// Completes a discount brought over from an old version.
  Future<void> complete(int id, {required int brandId, required int priceListId, required User user}) {
    return db.transaction(() async {
      _admin(user);
      final list = await (db.select(db.priceLists)..where((l) => l.id.equals(priceListId))).getSingleOrNull();
      if (list == null || list.brandId != brandId) throw ValidationException('القائمة المختارة ليست لهذه الماركة');
      await (db.update(db.buyingPolicies)..where((t) => t.id.equals(id))).write(BuyingPoliciesCompanion(
          brandId: Value(brandId), priceListId: Value(priceListId), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(action: AuditAction.update, entity: 'buying_policy', entityId: id, userId: user.id);
    });
  }

  /// Every policy, newest first, with readable names.
  Future<List<BuyingPolicyRow>> rows() async {
    final suppliers = {for (final s in await db.select(db.suppliers).get()) s.id: s.name};
    final brands = {for (final b in await db.select(db.brands).get()) b.id: b.name};
    final categories = {for (final c in await db.select(db.categories).get()) c.id: c.nameAr};
    final products = {for (final p in await db.select(db.products).get()) p.id: p.nameAr};
    final lists = {for (final l in await db.select(db.priceLists).get()) l.id: '${l.listType} V${l.versionNo}'};
    final all = await (db.select(db.buyingPolicies)..orderBy([(r) => OrderingTerm.desc(r.id)])).get();
    return [
      for (final r in all)
        BuyingPolicyRow(
          r,
          suppliers[r.supplierId] ?? '',
          brands[r.brandId],
          lists[r.priceListId],
          switch (r.scope) {
            PolicyScope.category => categories[r.categoryId] ?? '',
            PolicyScope.product => products[r.productId] ?? '',
            _ => '',
          },
        ),
    ];
  }

  /// The policy for this supplier, version and product on [asOf]: product
  /// rule, else category, else all. Null when none is recorded.
  Future<BuyingPolicy?> policyFor({
    required int supplierId,
    required PriceList list,
    required Product product,
    DateTime? asOf,
  }) async {
    final day = asOf ?? DateTime.now();
    final rules = await (db.select(db.buyingPolicies)
          ..where((r) =>
              r.supplierId.equals(supplierId) & r.priceListId.equals(list.id) & r.isActive.equals(true)))
        .get();
    BuyingPolicy? best;
    var bestRank = -1;
    for (final r in rules) {
      if (r.brandId != list.brandId) continue;
      if (r.validFrom != null && day.isBefore(r.validFrom!)) continue;
      if (r.validTo != null && dayOf(day).isAfter(r.validTo!)) continue;
      final rank = PolicyScope.rank(r.scope, r.categoryId, r.productId, product);
      if (rank < 0) continue;
      if (rank > bestRank || (rank == bestRank && r.id > best!.id)) {
        best = r;
        bestRank = rank;
      }
    }
    return best;
  }

  /// What [productId] costs from [supplierId] on [asOf], one result per
  /// version in force. A policy-backed result is listed first.
  Future<List<BuyQuote>> quotes(int productId, {required int supplierId, DateTime? asOf}) async {
    final product = await (db.select(db.products)..where((t) => t.id.equals(productId))).getSingle();
    final prices = await PriceListService(db).quotesFor(productId, asOf: asOf);
    final result = <BuyQuote>[];
    for (final q in prices) {
      final policy = await policyFor(supplierId: supplierId, list: q.priceList, product: product, asOf: asOf);
      result.add(BuyQuote(
        quote: q,
        policy: policy,
        vatStatus: q.priceList.vatStatus,
        vatRateBp: q.priceList.vatRateBp ?? product.vatRateBp,
      ));
    }
    result.sort((a, b) => (a.missingPolicy ? 1 : 0) - (b.missingPolicy ? 1 : 0));
    return result;
  }
}
