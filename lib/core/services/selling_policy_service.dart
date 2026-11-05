import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../pricing_math.dart';
import '../quantity.dart';
import 'audit_service.dart';
import 'buying_policy_service.dart';
import 'errors.dart';
import 'price_list_service.dart';

/// The most extra discount (basis points) a cashier may give past the policy
/// and the customer's own discount when the policy sets no limit of its own.
const cashierMaxExtraBp = 500;

class SellingPolicyInput {
  const SellingPolicyInput({
    required this.brandId,
    required this.priceListId,
    required this.pricingType,
    this.scope = PolicyScope.all,
    this.categoryId,
    this.productId,
    this.discountBp = 0,
    this.maxDiscountBp,
    this.minMarginBp,
    this.validFrom,
    this.validTo,
    this.note,
  });

  final int brandId;
  final int priceListId;
  final String pricingType;
  final String scope;
  final int? categoryId;
  final int? productId;
  final int discountBp;
  final int? maxDiscountBp;
  final int? minMarginBp;
  final DateTime? validFrom;
  final DateTime? validTo;
  final String? note;
}

class SellingPolicyRow {
  const SellingPolicyRow(this.policy, this.brandName, this.listLabel, this.targetName);

  final SellingPolicy policy;
  final String brandName;
  final String listLabel;
  final String targetName;
}

/// A selling price offered from one version: the list price and each discount.
class SellQuote {
  const SellQuote({
    required this.quote,
    required this.pricingType,
    this.policy,
    this.customerBp = 0,
    this.extraBp = 0,
  });

  final PriceQuote quote;
  final String pricingType;

  /// Null means no selling policy is recorded: the policy discount is zero.
  final SellingPolicy? policy;
  final int customerBp;
  final int extraBp;

  int get listPrice => quote.price;
  int get policyBp => policy?.discountBp ?? 0;

  /// Policy + customer + negotiation: 21% and one more point is 22%.
  int get totalBp {
    final sum = policyBp + customerBp + extraBp;
    return sum > 10000 ? 10000 : sum;
  }

  /// The final price of one unit.
  int get unitPrice => applyDiscount(listPrice, totalBp);
}

/// What a document line keeps about its price. Once a quote or order is
/// approved these numbers are fixed, whatever versions come later.
class PricingSnapshot {
  const PricingSnapshot({
    this.priceListId,
    this.listPrice,
    this.pricingType,
    this.sellingPolicyId,
    this.policyBp = 0,
    this.customerBp = 0,
    this.extraBp = 0,
    this.vatStatus,
    this.vatRateBp,
  });

  final int? priceListId;
  final int? listPrice;
  final String? pricingType;
  final int? sellingPolicyId;
  final int policyBp;
  final int customerBp;
  final int extraBp;
  final String? vatStatus;
  final int? vatRateBp;
}

/// The result of checking one line against its version and policy.
class LineCheck {
  const LineCheck({
    required this.snapshot,
    this.manualPrice = false,
    this.overDiscountLimit = false,
    this.minMarginBp,
    this.maxDiscountBp,
    this.listLabel,
    this.discountBp = 0,
  });

  final PricingSnapshot snapshot;

  /// The price is not the approved list price (or there is no list price).
  final bool manualPrice;

  /// The line's discount is past what the policy or the cashier limit allows.
  final bool overDiscountLimit;
  final int? minMarginBp;
  final int? maxDiscountBp;
  final String? listLabel;

  /// The whole discount on the line against the list price.
  final int discountBp;
}

/// Selling policies: Brand + Price List + Pricing Type, then scope. Entirely
/// apart from buying policies.
class SellingPolicyService {
  SellingPolicyService(this.db);

  final AppDatabase db;

  void _admin(User user) {
    if (!user.isAdmin) throw ValidationException('سياسات البيع للمدير فقط');
  }

  void _checkPercent(int? bp) {
    if (bp != null && (bp < 0 || bp > 10000)) {
      throw ValidationException('النسبة يجب أن تكون بين 0 و 100');
    }
  }

  Future<int> add(SellingPolicyInput input, {required User user}) {
    return db.transaction(() async {
      _admin(user);
      if (!PricingType.all.contains(input.pricingType)) throw ArgumentError.value(input.pricingType, 'pricingType');
      _checkPercent(input.discountBp);
      _checkPercent(input.maxDiscountBp);
      _checkPercent(input.minMarginBp);
      if (input.maxDiscountBp != null && input.maxDiscountBp! < input.discountBp) {
        throw ValidationException('الحد الأقصى للخصم أقل من خصم السياسة');
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
      final id = await db.into(db.sellingPolicies).insert(SellingPoliciesCompanion.insert(
            brandId: input.brandId,
            priceListId: input.priceListId,
            pricingType: input.pricingType,
            scope: input.scope,
            categoryId: Value(input.scope == PolicyScope.category ? input.categoryId : null),
            productId: Value(input.scope == PolicyScope.product ? input.productId : null),
            discountBp: Value(input.discountBp),
            maxDiscountBp: Value(input.maxDiscountBp),
            minMarginBp: Value(input.minMarginBp),
            validFrom: Value(input.validFrom),
            validTo: Value(input.validTo),
            note: Value((input.note ?? '').trim().isEmpty ? null : input.note!.trim()),
          ));
      await AuditService(db).log(
          action: AuditAction.create,
          entity: 'selling_policy',
          entityId: id,
          userId: user.id,
          details: '${input.pricingType} ${input.discountBp / 100}%');
      return id;
    });
  }

  Future<void> setActive(int id, bool active, {required User user}) {
    return db.transaction(() async {
      _admin(user);
      await (db.update(db.sellingPolicies)..where((t) => t.id.equals(id)))
          .write(SellingPoliciesCompanion(isActive: Value(active), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
          action: AuditAction.update,
          entity: 'selling_policy',
          entityId: id,
          userId: user.id,
          details: active ? 'تفعيل' : 'إيقاف');
    });
  }

  Future<List<SellingPolicyRow>> rows() async {
    final brands = {for (final b in await db.select(db.brands).get()) b.id: b.name};
    final categories = {for (final c in await db.select(db.categories).get()) c.id: c.nameAr};
    final products = {for (final p in await db.select(db.products).get()) p.id: p.nameAr};
    final lists = {for (final l in await db.select(db.priceLists).get()) l.id: '${l.listType} V${l.versionNo}'};
    final all = await (db.select(db.sellingPolicies)..orderBy([(r) => OrderingTerm.desc(r.id)])).get();
    return [
      for (final r in all)
        SellingPolicyRow(
          r,
          brands[r.brandId] ?? '',
          lists[r.priceListId] ?? '',
          switch (r.scope) {
            PolicyScope.category => categories[r.categoryId] ?? '',
            PolicyScope.product => products[r.productId] ?? '',
            _ => '',
          },
        ),
    ];
  }

  /// The policy for this version, pricing type and product: product rule, else
  /// category, else all. Null when none is recorded.
  Future<SellingPolicy?> policyFor({
    required PriceList list,
    required String pricingType,
    required Product product,
    DateTime? asOf,
  }) async {
    final day = asOf ?? DateTime.now();
    final rules = await (db.select(db.sellingPolicies)
          ..where((r) =>
              r.priceListId.equals(list.id) & r.pricingType.equals(pricingType) & r.isActive.equals(true)))
        .get();
    SellingPolicy? best;
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

  /// Every price that may apply for this customer on [asOf], one per version.
  /// None: the product has no approved price. Several: the person chooses.
  Future<List<SellQuote>> quotes(int productId, {Customer? customer, DateTime? asOf, int extraBp = 0}) async {
    final type = PricingType.ofLevel(customer?.priceLevel);
    final product = await (db.select(db.products)..where((t) => t.id.equals(productId))).getSingle();
    final prices = await PriceListService(db).quotesFor(productId, asOf: asOf, pricingType: type);
    return [
      for (final q in prices)
        SellQuote(
          quote: q,
          pricingType: type,
          policy: await policyFor(list: q.priceList, pricingType: type, product: product, asOf: asOf),
          customerBp: customer?.discountBp ?? 0,
          extraBp: extraBp,
        ),
    ];
  }

  /// The quote from one chosen version, or null if it does not price the
  /// product.
  Future<SellQuote?> quoteIn(int listId, int productId, {Customer? customer, DateTime? asOf, int extraBp = 0}) async {
    final type = PricingType.ofLevel(customer?.priceLevel);
    final product = await (db.select(db.products)..where((t) => t.id.equals(productId))).getSingle();
    final q = await PriceListService(db).quoteIn(listId, productId);
    if (q == null) return null;
    return SellQuote(
      quote: q,
      pricingType: type,
      policy: await policyFor(list: q.priceList, pricingType: type, product: product, asOf: asOf),
      customerBp: customer?.discountBp ?? 0,
      extraBp: extraBp,
    );
  }

  /// Checks one invoice line. [lineTotal] is before the invoice discount and
  /// [netTotal] after it. A [locked] line (from an approved order) is taken as
  /// it stands. A line with no [priceListId] is a manual price.
  Future<LineCheck> check({
    required Product product,
    required int qty,
    required int unitPrice,
    required int lineTotal,
    required int netTotal,
    int? priceListId,
    PricingSnapshot? locked,
    Customer? customer,
    required DateTime date,
  }) async {
    final type = PricingType.ofLevel(customer?.priceLevel);
    if (locked != null) return LineCheck(snapshot: locked);
    if (priceListId == null) {
      return LineCheck(
        manualPrice: true,
        snapshot: PricingSnapshot(pricingType: type, vatStatus: product.vatBasis, vatRateBp: product.vatRateBp),
      );
    }
    final quote = await quoteIn(priceListId, product.id, customer: customer, asOf: date);
    if (quote == null) {
      throw ValidationException('الصنف "${product.nameAr}" غير موجود في القائمة المختارة');
    }
    final list = quote.quote.priceList;
    if (!PriceListService.inForce(list, date)) {
      throw ValidationException('قائمة الأسعار المختارة غير سارية في تاريخ الفاتورة (${product.nameAr})');
    }
    final gross = lineAmount(qty, quote.listPrice);
    final expected = applyDiscount(gross, quote.totalBp);
    final extraMoney = expected - lineTotal;
    final extraBp = gross == 0 || extraMoney <= 0 ? 0 : (extraMoney * 10000 / gross).round();
    final wholeBp = gross == 0 ? 0 : ((gross - netTotal) * 10000 / gross).round();
    final max = quote.policy?.maxDiscountBp;
    final manual = unitPrice != quote.listPrice;
    // A changed unit price is one exception already, not two.
    final over = !manual && (max != null ? wholeBp > max : wholeBp - quote.totalBp > cashierMaxExtraBp);
    return LineCheck(
      manualPrice: manual,
      overDiscountLimit: over,
      minMarginBp: quote.policy?.minMarginBp,
      maxDiscountBp: max,
      listLabel: quote.quote.label,
      discountBp: wholeBp,
      snapshot: PricingSnapshot(
        priceListId: list.id,
        listPrice: quote.listPrice,
        pricingType: type,
        sellingPolicyId: quote.policy?.id,
        policyBp: quote.policyBp,
        customerBp: quote.customerBp,
        extraBp: extraBp,
        vatStatus: list.vatStatus,
        vatRateBp: list.vatRateBp ?? product.vatRateBp,
      ),
    );
  }
}
