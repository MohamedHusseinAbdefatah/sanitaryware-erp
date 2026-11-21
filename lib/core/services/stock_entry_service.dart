import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../money.dart';
import '../pricing_math.dart';
import '../quantity.dart';
import 'audit_service.dart';
import 'doc_types.dart';
import 'errors.dart';
import 'fifo_service.dart';
import 'numbering_service.dart';
import 'price_list_service.dart';
import 'stock_service.dart';
import 'supplier_advance_service.dart' show refuseLocked;

/// One product of a hand entry. The cost is either typed ([unitCost]) or
/// worked out from the list price less a discount (a percent or an amount
/// per unit).
class StockEntryLineInput {
  const StockEntryLineInput({
    required this.productId,
    required this.qty,
    this.unitCost,
    this.listPrice,
    this.priceListId,
    this.discountBp = 0,
    this.discountAmount = 0,
  });

  final int productId;

  /// Thousandths.
  final int qty;

  /// Piastres per whole unit; null = list price less the discount.
  final int? unitCost;
  final int? listPrice;
  final int? priceListId;
  final int discountBp;

  /// Piastres off each unit.
  final int discountAmount;

  /// The cost of one unit, or null when there is nothing to work it out from.
  int? get cost {
    if (unitCost != null) return unitCost;
    if (listPrice == null) return null;
    final afterPercent = applyDiscount(listPrice!, discountBp);
    return afterPercent - discountAmount;
  }
}

class StockEntryInput {
  const StockEntryInput({
    required this.lines,
    required this.effectiveDate,
    required this.reason,
    this.priceListId,
    this.supplierId,
    this.locationId = mainLocationId,
    this.notes,
    this.allowDuplicate = false,
  });

  final List<StockEntryLineInput> lines;

  /// When the goods were really bought (may be years ago).
  final DateTime effectiveDate;
  final String reason;

  /// The historical list the costs come from, for the record.
  final int? priceListId;

  /// Who it was bought from, for the record only.
  final int? supplierId;
  final int locationId;
  final String? notes;

  /// The person confirmed it is not the same stock entered twice.
  final bool allowDuplicate;
}

/// The same products, quantities and date are already in an active entry.
class DuplicateStockEntryException extends ValidationException {
  DuplicateStockEntryException(this.existing)
      : super('يبدو أن هذا المخزون أُدخل من قبل في ${existing.number} بنفس الأصناف والكميات والتاريخ');

  final StockEntry existing;
}

class StockEntryRow {
  const StockEntryRow(this.entry, this.lineCount, this.listLabel, this.supplierName, this.locationName);

  final StockEntry entry;
  final int lineCount;
  final String? listLabel;
  final String? supplierName;
  final String locationName;
}

class StockEntryLineRow {
  const StockEntryLineRow(this.line, this.productCode, this.productName, this.modelNo, this.brandName);

  final StockEntryLine line;
  final String productCode;
  final String productName;
  final String? modelNo;
  final String? brandName;
}

/// Stock entered by hand by the owner (blueprint 10, extended in 2.4), for
/// stock already in the shop before it was in the program. It is not a
/// purchase: no supplier invoice, no payment, no supplier balance. Each line
/// becomes an opening stock movement and a FIFO layer at its real cost, dated
/// on the day it was bought, tied to the historical list when there is one.
class StockEntryService {
  StockEntryService(this.db);

  final AppDatabase db;

  void _owner(User user) {
    if (!user.isAdmin) throw ValidationException('إدخال المخزون اليدوي للمالك فقط');
  }

  Future<StockEntry> enter(StockEntryInput input, {required User user}) {
    return db.transaction(() async {
      _owner(user);
      if (input.lines.isEmpty) throw ValidationException('أضف صنفاً واحداً على الأقل');
      if (input.reason.trim().isEmpty) throw ValidationException('اكتب سبب الإدخال (مثال: مخزون قديم قبل البرنامج)');
      final day = input.effectiveDate;
      if (dayOf(day).isAfter(dayOf(DateTime.now()))) {
        throw ValidationException('تاريخ الشراء الأصلي لا يكون في المستقبل');
      }
      await refuseLocked(db, day);
      final place = await (db.select(db.locations)..where((l) => l.id.equals(input.locationId))).getSingleOrNull();
      if (place == null || !place.isActive) throw ValidationException('مكان التخزين غير موجود أو موقوف');
      PriceList? list;
      if (input.priceListId != null) {
        list = await (db.select(db.priceLists)..where((l) => l.id.equals(input.priceListId!))).getSingleOrNull();
        if (list == null) throw ValidationException('قائمة الأسعار غير موجودة');
      }
      final units = {for (final u in await db.select(db.units).get()) u.id: u};
      final seen = <int>{};
      final costs = <int>[];
      for (final l in input.lines) {
        final p = await (db.select(db.products)..where((t) => t.id.equals(l.productId))).getSingleOrNull();
        if (p == null) throw ValidationException('الصنف غير موجود');
        if (!seen.add(p.id)) throw ValidationException('الصنف "${p.nameAr}" مكرر؛ اجمع كميته في سطر واحد');
        if (l.qty <= 0) throw ValidationException('الكمية يجب أن تكون أكبر من صفر (${p.nameAr})');
        if (!(units[p.unitId]?.allowDecimal ?? false) && !isWholeQty(l.qty)) {
          throw ValidationException('الكمية يجب أن تكون رقماً صحيحاً (${p.nameAr})');
        }
        if (l.discountBp < 0 || l.discountBp > 10000) throw ValidationException('نسبة الخصم بين 0 و 100 (${p.nameAr})');
        if (l.discountAmount < 0) throw ValidationException('الخصم لا يكون سالباً (${p.nameAr})');
        final c = l.cost;
        if (c == null) throw ValidationException('أدخل التكلفة أو سعر القائمة (${p.nameAr})');
        if (c < 0) throw ValidationException('الخصم أكبر من سعر القائمة (${p.nameAr})');
        costs.add(c);
      }
      if (!input.allowDuplicate) {
        final same = await _sameEntry(input);
        if (same != null) throw DuplicateStockEntryException(same);
      }

      final total = [
        for (var i = 0; i < input.lines.length; i++) lineAmount(input.lines[i].qty, costs[i]),
      ].fold<int>(0, (a, b) => a + b);
      final id = await db.into(db.stockEntries).insert(StockEntriesCompanion.insert(
            number: await NumberingService(db).next('stock_entry'),
            effectiveDate: day,
            priceListId: Value(input.priceListId),
            locationId: Value(input.locationId),
            supplierId: Value(input.supplierId),
            reason: input.reason.trim(),
            notes: Value((input.notes ?? '').trim().isEmpty ? null : input.notes!.trim()),
            total: Value(total),
            createdBy: Value(user.id),
          ));
      final stock = StockService(db);
      final fifo = FifoService(db);
      for (var i = 0; i < input.lines.length; i++) {
        final l = input.lines[i];
        final listId = l.priceListId ?? input.priceListId;
        await db.into(db.stockEntryLines).insert(StockEntryLinesCompanion.insert(
              entryId: id,
              productId: l.productId,
              qty: l.qty,
              listPrice: Value(l.listPrice),
              priceListId: Value(listId),
              discountBp: Value(l.discountBp),
              discountAmount: Value(l.discountAmount),
              unitCost: costs[i],
              lineTotal: lineAmount(l.qty, costs[i]),
            ));
        await stock.record(
          productId: l.productId,
          type: StockMovementType.opening,
          qty: l.qty,
          unitCost: costs[i],
          refType: RefType.stockEntry,
          refId: id,
          note: input.reason.trim(),
          createdBy: user.id,
          date: day,
          locationId: input.locationId,
        );
        await fifo.addLayer(
          productId: l.productId,
          qty: l.qty,
          unitCost: costs[i],
          locationId: input.locationId,
          receivedAt: day,
          supplierId: input.supplierId,
          sourceType: 'opening',
          sourceId: id,
          priceListId: listId,
          listPrice: l.listPrice,
          // With no list chosen, the version in force that day is found.
          stampFromDate: listId == null,
        );
      }
      final entry = await (db.select(db.stockEntries)..where((t) => t.id.equals(id))).getSingle();
      await AuditService(db).log(
        action: AuditAction.create,
        entity: 'stock_entry',
        entityId: id,
        userId: user.id,
        details: '${entry.number}: ${input.lines.length} صنف بقيمة ${formatMoney(total)}'
            '${list == null ? '' : ' من القائمة PL-${list.id} ${list.name}'}',
        newValue: 'تاريخ الشراء ${day.year}/${day.month}/${day.day}',
        reason: input.reason.trim(),
      );
      return entry;
    });
  }

  /// An active entry with the same date, place and lines, if any.
  Future<StockEntry?> _sameEntry(StockEntryInput input) async {
    final day = dayOf(input.effectiveDate);
    final candidates = await (db.select(db.stockEntries)
          ..where((t) => t.status.equals(DocStatus.active) & t.locationId.equals(input.locationId)))
        .get();
    final wanted = {for (final l in input.lines) '${l.productId}:${l.qty}'};
    for (final e in candidates) {
      if (dayOf(e.effectiveDate) != day) continue;
      final lines = await (db.select(db.stockEntryLines)..where((t) => t.entryId.equals(e.id))).get();
      final have = {for (final l in lines) '${l.productId}:${l.qty}'};
      if (have.length == wanted.length && have.containsAll(wanted)) return e;
    }
    return null;
  }

  /// Owner only: takes a mistaken entry back out. Refused when part of that
  /// stock has already been used (sold, moved, counted); kept on record.
  Future<void> cancel(int entryId, {required String reason, required User user}) {
    return db.transaction(() async {
      _owner(user);
      if (reason.trim().isEmpty) throw ValidationException('اكتب سبب الإلغاء');
      final e = await (db.select(db.stockEntries)..where((t) => t.id.equals(entryId))).getSingleOrNull();
      if (e == null) throw ValidationException('الإدخال غير موجود');
      if (e.status != DocStatus.active) throw ValidationException('الإدخال ${e.number} ملغى من قبل');
      await refuseLocked(db, e.effectiveDate);
      final layers = await (db.select(db.costLayers)
            ..where((l) => l.sourceType.equals('opening') & l.sourceId.equals(entryId)))
          .get();
      final names = {for (final p in await db.select(db.products).get()) p.id: p.nameAr};
      for (final l in layers) {
        if (l.qtyRemaining < l.qtyReceived) {
          throw ValidationException('استُخدم جزء من مخزون "${names[l.productId]}" في هذا الإدخال (بيع أو نقل)؛ '
              'لا يُلغى. سجّل تسوية مخزون بدلاً من ذلك.');
        }
      }
      final lines = await (db.select(db.stockEntryLines)..where((t) => t.entryId.equals(entryId))).get();
      await FifoService(db).voidSourceLayers('opening', entryId);
      final stock = StockService(db);
      for (final l in lines) {
        await stock.record(
          productId: l.productId,
          type: StockMovementType.opening,
          qty: -l.qty,
          unitCost: l.unitCost,
          refType: RefType.stockEntry,
          refId: entryId,
          note: 'إلغاء ${e.number}: ${reason.trim()}',
          createdBy: user.id,
          date: e.effectiveDate,
          locationId: e.locationId,
        );
      }
      await (db.update(db.stockEntries)..where((t) => t.id.equals(entryId))).write(StockEntriesCompanion(
          status: const Value(DocStatus.cancelled), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
        action: AuditAction.cancel,
        entity: 'stock_entry',
        entityId: entryId,
        userId: user.id,
        details: e.number,
        oldValue: formatMoney(e.total),
        newValue: '0',
        reason: reason.trim(),
      );
    });
  }

  /// Every entry, newest first.
  Stream<List<StockEntryRow>> watchRows() {
    return db.customSelect(
      '''
      SELECT e.*,
             (SELECT COUNT(*) FROM stock_entry_lines l WHERE l.entry_id = e.id) AS n,
             pl.list_type || ' V' || pl.version_no || ' (PL-' || pl.id || ')' AS list_label,
             su.name AS supplier_name, lo.name AS location_name
      FROM stock_entries e
      LEFT JOIN price_lists pl ON pl.id = e.price_list_id
      LEFT JOIN suppliers su ON su.id = e.supplier_id
      LEFT JOIN locations lo ON lo.id = e.location_id
      ORDER BY e.id DESC
      ''',
      readsFrom: {db.stockEntries, db.stockEntryLines, db.priceLists, db.suppliers, db.locations},
    ).watch().map((rows) => [
          for (final r in rows)
            StockEntryRow(
              db.stockEntries.map(r.data),
              r.read<int>('n'),
              r.readNullable<String>('list_label'),
              r.readNullable<String>('supplier_name'),
              r.readNullable<String>('location_name') ?? '',
            ),
        ]);
  }

  Future<List<StockEntryLineRow>> lines(int entryId) async {
    final rows = await (db.select(db.stockEntryLines).join([
      innerJoin(db.products, db.products.id.equalsExp(db.stockEntryLines.productId)),
      leftOuterJoin(db.brands, db.brands.id.equalsExp(db.products.brandId)),
    ])
          ..where(db.stockEntryLines.entryId.equals(entryId))
          ..orderBy([OrderingTerm.asc(db.stockEntryLines.id)]))
        .get();
    return [
      for (final r in rows)
        StockEntryLineRow(
          r.readTable(db.stockEntryLines),
          r.readTable(db.products).code,
          r.readTable(db.products).nameAr,
          r.readTable(db.products).modelNo,
          r.readTableOrNull(db.brands)?.name,
        ),
    ];
  }

  /// The list price of [productId] in the historical list [listId], and the
  /// list's usual buying discount (its category's) for a starting value.
  Future<(int? price, int discountBp)> priceIn(int listId, int productId) async {
    final q = await PriceListService(db).quoteIn(listId, productId);
    final list = await (db.select(db.priceLists)..where((l) => l.id.equals(listId))).getSingle();
    var bp = 0;
    if (list.categoryId != null) {
      final c = await (db.select(db.priceListCategories)..where((t) => t.id.equals(list.categoryId!)))
          .getSingleOrNull();
      bp = c?.buyingDiscountBp ?? 0;
    }
    return (q?.price, bp);
  }
}
