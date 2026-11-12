import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../pricing_math.dart';
import 'audit_service.dart';
import 'errors.dart';
import 'product_service.dart';
import 'stock_price_service.dart';

abstract final class PriceListStatus {
  static const active = 'active';
  static const pendingReview = 'pending_review';
  static const withdrawn = 'withdrawn';
}

abstract final class PriceRowStatus {
  static const ok = 'ok';
  static const review = 'review';
  static const skipped = 'skipped';
}

/// One row going into a version, from a file or typed by hand.
class PriceRowInput {
  const PriceRowInput({
    required this.name,
    this.price,
    this.manufacturerCode = '',
    this.variant,
    this.packSize,
    this.productId,
    this.reviewReason,
    this.sourceRow,
  });

  final String name;

  /// Piastres per unit. Null only with a [reviewReason].
  final int? price;
  final String manufacturerCode;
  final String? variant;
  final int? packSize;

  /// Known product; empty means it stays unmatched until reviewed.
  final int? productId;

  /// Set means the row is stopped for review.
  final String? reviewReason;
  final int? sourceRow;
}

/// The header of a new version (blueprint 3.3).
class PriceListHeader {
  const PriceListHeader({
    required this.name,
    required this.brandId,
    required this.listType,
    required this.effectiveFrom,
    this.effectiveTo,
    this.currency = 'EGP',
    this.vatStatus = VatStatus.unverified,
    this.vatRateBp,
    this.sourceFile,
    this.sourcePages,
    this.note,
  });

  final String name;
  final int brandId;
  final String listType;
  final DateTime effectiveFrom;
  final DateTime? effectiveTo;
  final String currency;
  final String vatStatus;
  final int? vatRateBp;
  final String? sourceFile;
  final String? sourcePages;
  final String? note;
}

/// The price of a product in one version.
class PriceQuote {
  const PriceQuote({
    required this.price,
    required this.priceList,
    required this.brandName,
  });

  final int price;
  final PriceList priceList;
  final String? brandName;

  int get priceListId => priceList.id;
  String get label =>
      '${brandName ?? ''} ${priceList.listType} V${priceList.versionNo} (PL-${priceList.id})'.trim();
}

class PriceListResult {
  const PriceListResult(this.id, {this.rows = 0, this.matched = 0, this.created = 0, this.review = 0});

  /// The Price List ID.
  final int id;
  final int rows;
  final int matched;
  final int created;
  final int review;
}

class PriceListSummary {
  const PriceListSummary(this.list, this.brandName, this.items, this.matched, this.review);

  final PriceList list;
  final String? brandName;
  final int items;

  /// Rows tied to a product and usable.
  final int matched;

  /// Rows waiting for a person.
  final int review;
}

/// One past or present price of a product (the price history).
class PriceHistoryRow {
  const PriceHistoryRow(this.item, this.list, this.brandName);

  final PriceListItem item;
  final PriceList list;
  final String? brandName;
}

/// Price list versions (blueprint 3.2, 3.3). Old versions and their rows are
/// never overwritten or erased: a new price is a new version, and the only
/// thing that ever changes on an old version is the closing of its period.
class PriceListService {
  PriceListService(this.db);

  final AppDatabase db;

  void _admin(User user) {
    if (!user.isAdmin) throw ValidationException('قوائم الأسعار للمدير فقط');
  }

  void _checkHeader(PriceListHeader h) {
    if (h.name.trim().isEmpty) throw ValidationException('اسم القائمة مطلوب');
    if (h.listType.trim().isEmpty) throw ValidationException('نوع القائمة مطلوب');
    if (h.currency != 'EGP') {
      // Every amount in the system is in pounds; there is no exchange rate to
      // convert with, and none may be made up.
      throw ValidationException('العملة ${h.currency} غير مدعومة حالياً؛ البرنامج يعمل بالجنيه المصري');
    }
    if (!VatStatus.all.contains(h.vatStatus)) throw ArgumentError.value(h.vatStatus, 'vatStatus');
    if (h.vatRateBp != null && (h.vatRateBp! < 0 || h.vatRateBp! > 10000)) {
      throw ValidationException('نسبة الضريبة يجب أن تكون بين 0 و 100');
    }
    if (h.effectiveTo != null && dayOf(h.effectiveTo!).isBefore(dayOf(h.effectiveFrom))) {
      throw ValidationException('نهاية القائمة قبل بدايتها');
    }
  }

  void _checkRow(PriceRowInput r) {
    if (r.reviewReason != null) return;
    if (r.price == null) throw ValidationException('السعر مطلوب (${r.name})');
    if (r.price! < 0) throw ValidationException('السعر لا يمكن أن يكون سالباً (${r.name})');
    if (r.packSize != null && r.packSize! <= 0) {
      throw ValidationException('عدد الكرتونة غير صحيح (${r.name})');
    }
  }

  /// Creates a new version with its own Price List ID.
  ///
  /// With [closePrevious] (a full list) every earlier open version of the same
  /// brand and list type ends the day before this one starts. Without it (a
  /// few products under a new date) the earlier version stays open for all its
  /// other products, and this version wins for the products it has.
  Future<PriceListResult> createVersion(
    PriceListHeader header, {
    required List<PriceRowInput> rows,
    required User user,
    bool closePrevious = true,
    int? rowCountOnSource,
  }) {
    return db.transaction(() async {
      _admin(user);
      _checkHeader(header);
      rows.forEach(_checkRow);
      final brand = await (db.select(db.brands)..where((b) => b.id.equals(header.brandId))).getSingleOrNull();
      if (brand == null) throw ValidationException('اختر الماركة');

      final from = dayOf(header.effectiveFrom);
      final type = header.listType.trim();
      final earlier = await (db.select(db.priceLists)
            ..where((l) => l.brandId.equals(header.brandId) & l.listType.equals(type))
            ..orderBy([(l) => OrderingTerm.desc(l.versionNo)]))
          .get();
      final live = earlier.where((l) => l.status == PriceListStatus.active).toList();
      for (final l in live) {
        if (l.effectiveFrom.isAfter(from)) {
          throw ValidationException(
              'يوجد إصدار V${l.versionNo} يبدأ بعد هذا التاريخ؛ الإصدار الجديد يجب أن يبدأ في تاريخه أو بعده');
        }
      }
      if (closePrevious) {
        // A version starting the same day (a corrected or re-sent list) is
        // replaced from its first day: it stays on record, never in force.
        final dayBefore = from.subtract(const Duration(days: 1));
        for (final l in live) {
          if (l.effectiveTo == null || !l.effectiveTo!.isBefore(from)) {
            await (db.update(db.priceLists)..where((t) => t.id.equals(l.id))).write(
                PriceListsCompanion(effectiveTo: Value(dayBefore), updatedAt: Value(DateTime.now())));
          }
        }
      }
      final id = await db.into(db.priceLists).insert(PriceListsCompanion.insert(
            name: header.name.trim(),
            brandId: Value(header.brandId),
            listType: type,
            versionNo: Value((earlier.isEmpty ? 0 : earlier.first.versionNo) + 1),
            currency: Value(header.currency),
            effectiveFrom: from,
            effectiveTo: Value(header.effectiveTo == null ? null : dayOf(header.effectiveTo!)),
            importDate: DateTime.now(),
            sourceFile: Value(_blankToNull(header.sourceFile)),
            sourcePages: Value(_blankToNull(header.sourcePages)),
            rowCount: Value(rowCountOnSource ?? rows.length),
            vatStatus: Value(header.vatStatus),
            vatRateBp: Value(header.vatRateBp),
            note: Value(_blankToNull(header.note)),
          ));
      var matched = 0, review = 0;
      for (final r in rows) {
        final stopped = r.reviewReason != null || r.productId == null;
        if (stopped) {
          review++;
        } else {
          matched++;
        }
        await _insertRow(id, r, stopped);
      }
      final carried = await _carryPolicies(live.map((l) => l.id).toList(), id);
      await AuditService(db).log(
        action: AuditAction.create,
        entity: 'price_list',
        entityId: id,
        userId: user.id,
        details: '${header.name.trim()} V${(earlier.isEmpty ? 0 : earlier.first.versionNo) + 1}: ${rows.length} صف'
            '${carried == 0 ? '' : '، نُقلت $carried سياسة شراء من الإصدار السابق'}',
      );
      await StockPriceService(db).stampUnknown(productIds: rows.map((r) => r.productId).whereType<int>());
      return PriceListResult(id, rows: rows.length, matched: matched, review: review);
    });
  }

  /// A supplier's discount belongs to the brand and list type, not to one
  /// edition: a new version takes over the active buying policies of the
  /// versions it follows, with the same discounts. The old ones stay on the
  /// old version for the documents that used them. (Selling discounts are by
  /// customer category and brand, not by version, so they need nothing.)
  Future<int> _carryPolicies(List<int> fromListIds, int toListId) async {
    if (fromListIds.isEmpty) return 0;
    var n = 0;
    final buying = await (db.select(db.buyingPolicies)
          ..where((p) => p.priceListId.isIn(fromListIds) & p.isActive.equals(true))
          ..orderBy([(p) => OrderingTerm.desc(p.id)]))
        .get();
    final seenBuy = <String>{};
    for (final p in buying) {
      // The newest rule wins when two versions both had one for the same target.
      if (!seenBuy.add('${p.supplierId}|${p.scope}|${p.categoryId}|${p.productId}')) continue;
      await db.into(db.buyingPolicies).insert(BuyingPoliciesCompanion.insert(
            supplierId: p.supplierId,
            brandId: Value(p.brandId),
            priceListId: Value(toListId),
            scope: p.scope,
            categoryId: Value(p.categoryId),
            productId: Value(p.productId),
            baseDiscountBp: Value(p.baseDiscountBp),
            extraDiscountBp: Value(p.extraDiscountBp),
            validFrom: Value(p.validFrom),
            validTo: Value(p.validTo),
            note: Value(p.note),
          ));
      n++;
    }
    return n;
  }

  /// The newest active version of each list type of [brandId], so an import
  /// can offer to be a new version of one of them.
  Future<List<PriceList>> liveListsOf(int brandId) async {
    final all = await (db.select(db.priceLists)
          ..where((l) => l.brandId.equals(brandId) & l.status.equals(PriceListStatus.active))
          ..orderBy([(l) => OrderingTerm.desc(l.versionNo), (l) => OrderingTerm.desc(l.id)]))
        .get();
    final byType = <String, PriceList>{};
    for (final l in all) {
      byType.putIfAbsent(l.listType, () => l);
    }
    return byType.values.toList();
  }

  Future<int> _insertRow(int listId, PriceRowInput r, bool stopped) {
    return db.into(db.priceListItems).insert(PriceListItemsCompanion.insert(
          priceListId: listId,
          productId: Value(stopped ? null : r.productId),
          manufacturerCode: Value(r.manufacturerCode.trim()),
          name: r.name.trim().isEmpty ? '(بدون اسم)' : r.name.trim(),
          variant: Value(_blankToNull(r.variant)),
          price: Value(r.price),
          packSize: Value(r.packSize),
          status: Value(stopped ? PriceRowStatus.review : PriceRowStatus.ok),
          reviewReason: Value(stopped ? (r.reviewReason ?? 'لم يطابق صنفاً') : null),
          sourceRow: Value(r.sourceRow),
        ));
  }

  /// Adds products to a version without a file (blueprint 3.2b): each entry
  /// has a product and its price. A product already priced in this version
  /// cannot be changed; that takes a new version.
  Future<void> addEntries(int listId, List<PriceRowInput> rows, {required User user}) {
    return db.transaction(() async {
      _admin(user);
      if (rows.isEmpty) throw ValidationException('أضف صنفاً واحداً على الأقل');
      final list = await _list(listId);
      if (list.status == PriceListStatus.withdrawn) throw ValidationException('هذه القائمة مسحوبة');
      for (final r in rows) {
        _checkRow(r);
        if (r.productId == null) throw ValidationException('اختر الصنف (${r.name})');
        final same = await (db.select(db.priceListItems)
              ..where((i) =>
                  i.priceListId.equals(listId) &
                  i.productId.equals(r.productId!) &
                  i.status.equals(PriceRowStatus.ok)))
            .get();
        if (same.isNotEmpty) {
          throw ValidationException(
              'الصنف "${r.name}" مسعّر في هذا الإصدار؛ لا يُكتب فوق سعر قديم — أنشئ إصداراً جديداً');
        }
        await _insertRow(listId, r, false);
      }
      await (db.update(db.priceLists)..where((l) => l.id.equals(listId))).write(PriceListsCompanion(
          rowCount: Value(list.rowCount + rows.length), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
        action: AuditAction.update,
        entity: 'price_list',
        entityId: listId,
        userId: user.id,
        details: 'إضافة ${rows.length} صف',
      );
      await StockPriceService(db).stampUnknown(productIds: rows.map((r) => r.productId).whereType<int>());
    });
  }

  Future<PriceList> _list(int id) async {
    final l = await (db.select(db.priceLists)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (l == null) throw ValidationException('القائمة غير موجودة');
    return l;
  }

  /// Every version, newest first, with its counts.
  Stream<List<PriceListSummary>> watchSummaries() => _summaries().watch();

  Future<List<PriceListSummary>> summaries() => _summaries().get();

  Selectable<PriceListSummary> _summaries() {
    return db.customSelect('''
      SELECT l.*, b.name AS brand_name,
             (SELECT COUNT(*) FROM price_list_items i WHERE i.price_list_id = l.id) AS n,
             (SELECT COUNT(*) FROM price_list_items i
               WHERE i.price_list_id = l.id AND i.status = 'ok') AS m,
             (SELECT COUNT(*) FROM price_list_items i
               WHERE i.price_list_id = l.id AND i.status = 'review') AS r
      FROM price_lists l
      LEFT JOIN brands b ON b.id = l.brand_id
      ORDER BY l.effective_from DESC, l.id DESC
    ''', readsFrom: {db.priceLists, db.priceListItems, db.brands}).map((r) => PriceListSummary(
          db.priceLists.map(r.data),
          r.readNullable<String>('brand_name'),
          r.read<int>('n'),
          r.read<int>('m'),
          r.read<int>('r'),
        ));
  }

  Future<List<PriceListItem>> items(int listId) =>
      (db.select(db.priceListItems)
            ..where((i) => i.priceListId.equals(listId))
            ..orderBy([(i) => OrderingTerm.asc(i.id)]))
          .get();

  /// Rows waiting for a person, across all versions or one.
  Future<List<PriceListItem>> reviewQueue({int? listId}) =>
      (db.select(db.priceListItems)
            ..where((i) =>
                i.status.equals(PriceRowStatus.review) &
                (listId == null ? const Constant(true) : i.priceListId.equals(listId)))
            ..orderBy([(i) => OrderingTerm.asc(i.priceListId), (i) => OrderingTerm.asc(i.id)]))
          .get();

  /// Resolves a review row by tying it to an existing product. [price] is
  /// needed when the row's own price was missing.
  Future<void> resolveMatch(int itemId, int productId, {int? price, required User user}) {
    return db.transaction(() async {
      _admin(user);
      final item = await _reviewItem(itemId);
      final p = price ?? item.price;
      if (p == null || p < 0) throw ValidationException('أدخل السعر');
      await _refusePriced(item.priceListId, productId, itemId);
      await (db.update(db.priceListItems)..where((i) => i.id.equals(itemId))).write(PriceListItemsCompanion(
          productId: Value(productId),
          price: Value(p),
          status: const Value(PriceRowStatus.ok),
          reviewReason: const Value(null)));
      await _logReview(item, 'ربط بصنف', user);
      await StockPriceService(db).stampUnknown(productIds: [productId]);
    });
  }

  /// Resolves a review row by creating a new product for it. Returns its id.
  Future<int> resolveCreate(int itemId, {int? price, required User user, int? categoryId, int? unitId}) {
    return db.transaction(() async {
      _admin(user);
      final item = await _reviewItem(itemId);
      final p = price ?? item.price;
      if (p == null || p < 0) throw ValidationException('أدخل السعر');
      final list = await _list(item.priceListId);
      final product = await ProductService(db).create(
        ProductInput(
          nameAr: item.name,
          manufacturerCode: item.manufacturerCode,
          brandId: list.brandId,
          variant: item.variant,
          categoryId: categoryId,
          unitId: unitId,
        ),
        userId: user.id,
      );
      await (db.update(db.priceListItems)..where((i) => i.id.equals(itemId))).write(PriceListItemsCompanion(
          productId: Value(product.id),
          price: Value(p),
          status: const Value(PriceRowStatus.ok),
          reviewReason: const Value(null)));
      await _logReview(item, 'صنف جديد ${product.code}', user);
      return product.id;
    });
  }

  /// Resolves a review row by leaving it out. The row stays on record.
  Future<void> resolveSkip(int itemId, {required String reason, required User user}) {
    return db.transaction(() async {
      _admin(user);
      if (reason.trim().isEmpty) throw ValidationException('اكتب سبب الاستبعاد');
      final item = await _reviewItem(itemId);
      await (db.update(db.priceListItems)..where((i) => i.id.equals(itemId))).write(PriceListItemsCompanion(
          status: const Value(PriceRowStatus.skipped), reviewReason: Value(reason.trim())));
      await _logReview(item, 'استبعاد: ${reason.trim()}', user);
    });
  }

  Future<PriceListItem> _reviewItem(int itemId) async {
    final item = await (db.select(db.priceListItems)..where((i) => i.id.equals(itemId))).getSingleOrNull();
    if (item == null) throw ValidationException('الصف غير موجود');
    if (item.status != PriceRowStatus.review) throw ValidationException('هذا الصف ليس قيد المراجعة');
    return item;
  }

  Future<void> _refusePriced(int listId, int productId, int exceptItemId) async {
    final rows = await (db.select(db.priceListItems)
          ..where((i) =>
              i.priceListId.equals(listId) &
              i.productId.equals(productId) &
              i.status.equals(PriceRowStatus.ok) &
              i.id.equals(exceptItemId).not()))
        .get();
    if (rows.isNotEmpty) throw ValidationException('هذا الصنف مسعّر من قبل في نفس الإصدار');
  }

  Future<void> _logReview(PriceListItem item, String what, User user) => AuditService(db).log(
        action: AuditAction.update,
        entity: 'price_list',
        entityId: item.priceListId,
        userId: user.id,
        details: 'مراجعة "${item.name}": $what',
      );

  /// Approves a list brought over from an old version once a person has
  /// checked it: it needs a brand, and its VAT status comes from the source.
  Future<void> approvePending(
    int listId, {
    required int brandId,
    required String vatStatus,
    int? vatRateBp,
    required User user,
  }) {
    return db.transaction(() async {
      _admin(user);
      final list = await _list(listId);
      if (list.status != PriceListStatus.pendingReview) {
        throw ValidationException('هذه القائمة ليست قيد المراجعة');
      }
      if (!VatStatus.all.contains(vatStatus)) throw ArgumentError.value(vatStatus, 'vatStatus');
      await (db.update(db.priceLists)..where((l) => l.id.equals(listId))).write(PriceListsCompanion(
          brandId: Value(brandId),
          vatStatus: Value(vatStatus),
          vatRateBp: Value(vatRateBp),
          status: const Value(PriceListStatus.active),
          updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
          action: AuditAction.update, entity: 'price_list', entityId: listId, userId: user.id, details: 'اعتماد');
      await StockPriceService(db).stampUnknown();
    });
  }

  /// Records the VAT status once it is verified from the source. This is the
  /// one thing besides the period that may be completed on a version.
  Future<void> setVat(int listId, {required String vatStatus, int? vatRateBp, required User user}) {
    return db.transaction(() async {
      _admin(user);
      if (!VatStatus.all.contains(vatStatus)) throw ArgumentError.value(vatStatus, 'vatStatus');
      await _list(listId);
      await (db.update(db.priceLists)..where((l) => l.id.equals(listId))).write(PriceListsCompanion(
          vatStatus: Value(vatStatus), vatRateBp: Value(vatRateBp), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
          action: AuditAction.update,
          entity: 'price_list',
          entityId: listId,
          userId: user.id,
          details: 'الضريبة: ${VatStatus.label(vatStatus)}');
    });
  }

  /// Takes a mistaken version out of use. It stays on record; documents that
  /// used it keep it.
  Future<void> withdraw(int listId, {required String reason, required User user}) {
    return db.transaction(() async {
      _admin(user);
      if (reason.trim().isEmpty) throw ValidationException('اكتب سبب السحب');
      await _list(listId);
      await (db.update(db.priceLists)..where((l) => l.id.equals(listId))).write(PriceListsCompanion(
          status: const Value(PriceListStatus.withdrawn), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
          action: AuditAction.cancel, entity: 'price_list', entityId: listId, userId: user.id, details: reason.trim());
    });
  }

  /// True when [list] can price something on [day].
  static bool inForce(PriceList list, DateTime day) {
    if (list.status != PriceListStatus.active) return false;
    final d = dayOf(day);
    if (list.effectiveFrom.isAfter(d)) return false;
    return list.effectiveTo == null || !list.effectiveTo!.isBefore(d);
  }

  /// Every price that may apply to [productId] on [asOf], for [pricingType] if
  /// given. Each brand and list type gives one: its newest version in force
  /// that has the product. More than one result means the person must choose.
  Future<List<PriceQuote>> quotesFor(int productId, {DateTime? asOf, String? pricingType}) async {
    final day = asOf ?? DateTime.now();
    final rows = await (db.select(db.priceListItems).join([
      innerJoin(db.priceLists, db.priceLists.id.equalsExp(db.priceListItems.priceListId)),
      leftOuterJoin(db.brands, db.brands.id.equalsExp(db.priceLists.brandId)),
    ])
          ..where(db.priceListItems.productId.equals(productId) &
              db.priceListItems.status.equals(PriceRowStatus.ok))
          ..orderBy([OrderingTerm.desc(db.priceLists.versionNo), OrderingTerm.desc(db.priceLists.id)]))
        .get();
    final byKind = <String, PriceQuote>{};
    for (final row in rows) {
      final list = row.readTable(db.priceLists);
      if (!inForce(list, day)) continue;
      if (pricingType != null && list.pricingTypeOnly != null && list.pricingTypeOnly != pricingType) continue;
      final price = row.readTable(db.priceListItems).price;
      if (price == null) continue;
      byKind.putIfAbsent(
        '${list.brandId}|${list.listType}',
        () => PriceQuote(price: price, priceList: list, brandName: row.readTableOrNull(db.brands)?.name),
      );
    }
    return byKind.values.toList();
  }

  /// The price of [productId] in one chosen version, usable or not on today's
  /// date is the caller's concern. Null when the version has no such row.
  Future<PriceQuote?> quoteIn(int listId, int productId) async {
    final list = await _list(listId);
    final item = await (db.select(db.priceListItems)
          ..where((i) =>
              i.priceListId.equals(listId) &
              i.productId.equals(productId) &
              i.status.equals(PriceRowStatus.ok)))
        .get();
    if (item.isEmpty || item.first.price == null) return null;
    final brand = list.brandId == null
        ? null
        : await (db.select(db.brands)..where((b) => b.id.equals(list.brandId!))).getSingleOrNull();
    return PriceQuote(price: item.first.price!, priceList: list, brandName: brand?.name);
  }

  /// All prices a product ever had, newest first.
  Future<List<PriceHistoryRow>> history(int productId) async {
    final rows = await (db.select(db.priceListItems).join([
      innerJoin(db.priceLists, db.priceLists.id.equalsExp(db.priceListItems.priceListId)),
      leftOuterJoin(db.brands, db.brands.id.equalsExp(db.priceLists.brandId)),
    ])
          ..where(db.priceListItems.productId.equals(productId))
          ..orderBy([OrderingTerm.desc(db.priceLists.effectiveFrom), OrderingTerm.desc(db.priceLists.id)]))
        .get();
    return [
      for (final r in rows)
        PriceHistoryRow(r.readTable(db.priceListItems), r.readTable(db.priceLists), r.readTableOrNull(db.brands)?.name),
    ];
  }

  static String? _blankToNull(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();
}
