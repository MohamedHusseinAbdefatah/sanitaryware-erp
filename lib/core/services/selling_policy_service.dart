import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../pricing_math.dart';
import '../quantity.dart';
import 'audit_service.dart';
import 'buying_policy_service.dart';
import 'errors.dart';
import 'price_list_service.dart';

/// The most extra discount (basis points) a cashier may give past the
/// category discount and the customer's own discount when no special rule
/// sets a limit of its own.
const cashierMaxExtraBp = 500;

/// The category used for a sale with no customer, and for a customer with no
/// category: the first one, retail.
const walkInCategoryId = 1;

/// How a recorded pricing type reads: a category name since schema 13, one of
/// the three fixed types before it.
String pricingTypeLabel(String? type) => switch (type) {
      null || '' => 'قطاعي',
      PricingType.b2c || PricingType.b2b || PricingType.project => PricingType.label(type),
      _ => type,
    };

class CustomerCategoryInput {
  const CustomerCategoryInput({required this.name, this.discountBp = 0, this.isActive = true});

  final String name;
  final int discountBp;
  final bool isActive;
}

class SellingPolicyInput {
  const SellingPolicyInput({
    required this.customerCategoryId,
    this.brandId,
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

  final int customerCategoryId;

  /// Null: every brand.
  final int? brandId;
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
  const SellingPolicyRow(this.policy, this.customerCategoryName, this.brandName, this.targetName);

  final SellingPolicy policy;
  final String customerCategoryName;

  /// 'كل الماركات' for a rule on every brand.
  final String brandName;
  final String targetName;
}

/// A selling price offered from one version: the list price and each discount.
class SellQuote {
  const SellQuote({
    required this.quote,
    required this.pricingType,
    this.policy,
    this.categoryBp = 0,
    this.customerBp = 0,
    this.extraBp = 0,
  });

  final PriceQuote quote;

  /// The customer category's name, kept on the document line.
  final String pricingType;

  /// A special rule for this category, brand and product. Null: the
  /// category's usual discount applies.
  final SellingPolicy? policy;
  final int categoryBp;
  final int customerBp;
  final int extraBp;

  int get listPrice => quote.price;

  /// The special rule's discount, else the category's.
  int get policyBp => policy?.discountBp ?? categoryBp;

  /// Category + customer + negotiation: 21% and one more point is 22%.
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

/// Selling discounts. Each customer has a category (retail, wholesale,
/// projects, engineers...) with a usual discount. A special rule can give a
/// category another discount on one brand, product category or product.
/// Neither is tied to a price list version, so a new list keeps them.
/// Entirely apart from buying policies.
class SellingPolicyService {
  SellingPolicyService(this.db);

  final AppDatabase db;

  void _admin(User user) {
    if (!user.isAdmin) throw ValidationException('خصومات البيع للمدير فقط');
  }

  void _checkPercent(int? bp) {
    if (bp != null && (bp < 0 || bp > 10000)) {
      throw ValidationException('النسبة يجب أن تكون بين 0 و 100');
    }
  }

  // ---- customer categories ----

  Stream<List<CustomerCategory>> watchCategories() =>
      (db.select(db.customerCategories)..orderBy([(c) => OrderingTerm.asc(c.id)])).watch();

  Future<List<CustomerCategory>> categories() =>
      (db.select(db.customerCategories)..orderBy([(c) => OrderingTerm.asc(c.id)])).get();

  /// Adds a category, or changes one when [id] is given.
  Future<int> saveCategory(CustomerCategoryInput input, {int? id, required User user}) {
    return db.transaction(() async {
      _admin(user);
      final name = input.name.trim();
      if (name.isEmpty) throw ValidationException('اكتب اسم الفئة');
      _checkPercent(input.discountBp);
      final same = await (db.select(db.customerCategories)..where((c) => c.name.equals(name))).getSingleOrNull();
      if (same != null && same.id != id) throw ValidationException('توجد فئة بنفس الاسم');
      if (id == null) {
        final newId = await db.into(db.customerCategories).insert(CustomerCategoriesCompanion.insert(
              name: name,
              discountBp: Value(input.discountBp),
              isActive: Value(input.isActive),
            ));
        await AuditService(db).log(
            action: AuditAction.create,
            entity: 'customer_category',
            entityId: newId,
            userId: user.id,
            details: '$name ${input.discountBp / 100}%');
        return newId;
      }
      final before = await (db.select(db.customerCategories)..where((c) => c.id.equals(id))).getSingle();
      if (!input.isActive && id == walkInCategoryId) {
        throw ValidationException('فئة "${before.name}" تُستخدم للبيع بدون عميل ولا يمكن إيقافها');
      }
      await (db.update(db.customerCategories)..where((c) => c.id.equals(id))).write(CustomerCategoriesCompanion(
          name: Value(name),
          discountBp: Value(input.discountBp),
          isActive: Value(input.isActive),
          updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
          action: AuditAction.update,
          entity: 'customer_category',
          entityId: id,
          userId: user.id,
          details: '${before.name} ${before.discountBp / 100}% -> $name ${input.discountBp / 100}%'
              '${input.isActive ? '' : ' (موقوفة)'}');
      return id;
    });
  }

  /// The category a [customer] is priced by; retail for a walk-in sale.
  Future<CustomerCategory?> categoryOf(Customer? customer) async {
    final id = customer?.categoryId ?? walkInCategoryId;
    return (db.select(db.customerCategories)..where((c) => c.id.equals(id))).getSingleOrNull();
  }

  // ---- special rules ----

  Future<int> add(SellingPolicyInput input, {required User user}) {
    return db.transaction(() async {
      _admin(user);
      _checkPercent(input.discountBp);
      _checkPercent(input.maxDiscountBp);
      _checkPercent(input.minMarginBp);
      if (input.maxDiscountBp != null && input.maxDiscountBp! < input.discountBp) {
        throw ValidationException('الحد الأقصى للخصم أقل من الخصم نفسه');
      }
      final target = switch (input.scope) {
        PolicyScope.all => true,
        PolicyScope.category => input.categoryId != null,
        PolicyScope.product => input.productId != null,
        _ => throw ArgumentError.value(input.scope, 'scope'),
      };
      if (!target) throw ValidationException('اختر الصنف أو التصنيف الذي يخصه الخصم');
      if (input.validFrom != null && input.validTo != null && input.validTo!.isBefore(input.validFrom!)) {
        throw ValidationException('نهاية الخصم قبل بدايته');
      }
      final category = await (db.select(db.customerCategories)..where((c) => c.id.equals(input.customerCategoryId)))
          .getSingleOrNull();
      if (category == null) throw ValidationException('اختر فئة العملاء');
      final id = await db.into(db.sellingPolicies).insert(SellingPoliciesCompanion.insert(
            customerCategoryId: input.customerCategoryId,
            brandId: Value(input.brandId),
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
          details: '${category.name} ${input.discountBp / 100}%');
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
    final groups = {for (final c in await categories()) c.id: c.name};
    final brands = {for (final b in await db.select(db.brands).get()) b.id: b.name};
    final cats = {for (final c in await db.select(db.categories).get()) c.id: c.nameAr};
    final products = {for (final p in await db.select(db.products).get()) p.id: p.nameAr};
    final all = await (db.select(db.sellingPolicies)..orderBy([(r) => OrderingTerm.desc(r.id)])).get();
    return [
      for (final r in all)
        SellingPolicyRow(
          r,
          groups[r.customerCategoryId] ?? '',
          r.brandId == null ? 'كل الماركات' : brands[r.brandId] ?? '',
          switch (r.scope) {
            PolicyScope.category => cats[r.categoryId] ?? '',
            PolicyScope.product => products[r.productId] ?? '',
            _ => '',
          },
        ),
    ];
  }

  /// The special rule for this customer category, brand and product on
  /// [asOf]. Product beats product category beats all; at the same level a
  /// rule for the brand beats one for every brand; then the newest. Null
  /// when none applies: the category's usual discount is used.
  Future<SellingPolicy?> policyFor({
    required int customerCategoryId,
    required int? brandId,
    required Product product,
    DateTime? asOf,
  }) async {
    final day = asOf ?? DateTime.now();
    final rules = await (db.select(db.sellingPolicies)
          ..where((r) => r.customerCategoryId.equals(customerCategoryId) & r.isActive.equals(true)))
        .get();
    SellingPolicy? best;
    var bestRank = -1;
    for (final r in rules) {
      if (r.brandId != null && r.brandId != brandId) continue;
      if (r.validFrom != null && day.isBefore(r.validFrom!)) continue;
      if (r.validTo != null && dayOf(day).isAfter(r.validTo!)) continue;
      final scopeRank = PolicyScope.rank(r.scope, r.categoryId, r.productId, product);
      if (scopeRank < 0) continue;
      final rank = scopeRank * 2 + (r.brandId == null ? 0 : 1);
      if (rank > bestRank || (rank == bestRank && r.id > best!.id)) {
        best = r;
        bestRank = rank;
      }
    }
    return best;
  }

  Future<SellQuote> _sellQuote(PriceQuote q, Product product, CustomerCategory? category, Customer? customer,
      DateTime? asOf, int extraBp) async {
    return SellQuote(
      quote: q,
      pricingType: category?.name ?? 'قطاعي',
      policy: category == null
          ? null
          : await policyFor(
              customerCategoryId: category.id, brandId: q.priceList.brandId, product: product, asOf: asOf),
      categoryBp: category?.discountBp ?? 0,
      customerBp: customer?.discountBp ?? 0,
      extraBp: extraBp,
    );
  }

  /// Every price that may apply for this customer on [asOf], one per version.
  /// None: the product has no approved price. Several: the person chooses.
  Future<List<SellQuote>> quotes(int productId, {Customer? customer, DateTime? asOf, int extraBp = 0}) async {
    final category = await categoryOf(customer);
    final product = await (db.select(db.products)..where((t) => t.id.equals(productId))).getSingle();
    final prices = await PriceListService(db).quotesFor(productId, asOf: asOf, pricingType: category?.legacyType);
    return [for (final q in prices) await _sellQuote(q, product, category, customer, asOf, extraBp)];
  }

  /// The quote from one chosen version, or null if it does not price the
  /// product.
  Future<SellQuote?> quoteIn(int listId, int productId, {Customer? customer, DateTime? asOf, int extraBp = 0}) async {
    final category = await categoryOf(customer);
    final product = await (db.select(db.products)..where((t) => t.id.equals(productId))).getSingle();
    final q = await PriceListService(db).quoteIn(listId, productId);
    if (q == null) return null;
    return _sellQuote(q, product, category, customer, asOf, extraBp);
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
    if (locked != null) return LineCheck(snapshot: locked);
    if (priceListId == null) {
      final category = await categoryOf(customer);
      return LineCheck(
        manualPrice: true,
        snapshot: PricingSnapshot(
            pricingType: category?.name, vatStatus: product.vatBasis, vatRateBp: product.vatRateBp),
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
        pricingType: quote.pricingType,
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
