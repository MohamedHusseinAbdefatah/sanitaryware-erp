import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../money.dart';
import '../quantity.dart';
import 'audit_service.dart';
import 'cost.dart';
import 'doc_types.dart';
import 'errors.dart';
import 'numbering_service.dart';
import 'settings_service.dart';
import 'stock_service.dart';

class ReturnLineInput {
  const ReturnLineInput({required this.productId, required this.qty, required this.unitPrice});

  final int productId;

  /// Thousandths of a unit.
  final int qty;

  /// Piastres per whole unit: the selling price for a sale return, the cost
  /// for a purchase return.
  final int unitPrice;

  int get total => lineAmount(qty, unitPrice);
}

class ReturnInput {
  const ReturnInput({
    required this.lines,
    this.partyId,
    this.originalInvoiceId,
    this.refundAmount = 0,
    this.refundMethod = PaymentMethod.cash,
    this.date,
    this.notes,
  });

  final List<ReturnLineInput> lines;

  /// Customer or supplier. Taken from the original invoice when there is
  /// one. A sale return with no customer is a walk-in refund.
  final int? partyId;
  final int? originalInvoiceId;

  /// Cash actually handed back (sale return) or received back (purchase
  /// return). The rest of the total changes the party's balance.
  final int refundAmount;
  final String refundMethod;
  final DateTime? date;
  final String? notes;

  int get total => lines.fold(0, (s, l) => s + l.total);
}

/// A product on the original invoice and how much of it can still go back.
class ReturnableLine {
  const ReturnableLine({
    required this.productId,
    required this.code,
    required this.name,
    required this.unitName,
    required this.allowDecimal,
    required this.invoicedQty,
    required this.returnedQty,
    required this.unitPrice,
    required this.unitCost,
  });

  final int productId;
  final String code;
  final String name;
  final String? unitName;
  final bool allowDecimal;
  final int invoicedQty;
  final int returnedQty;

  /// Net per whole unit after the line discount (sales) or the unit cost
  /// (purchases): the default refund value.
  final int unitPrice;
  final int unitCost;

  int get returnable => invoicedQty - returnedQty;
}

/// The original invoice a return is made against.
class ReturnSource {
  const ReturnSource({required this.id, required this.number, this.partyId, this.partyName});
  final int id;
  final String number;

  /// Null for a walk-in cash sale.
  final int? partyId;
  final String? partyName;
}

class ReturnDetailLine {
  const ReturnDetailLine(this.item, this.productCode, this.productName);
  final ReturnItem item;
  final String productCode;
  final String productName;
}

class ReturnRow {
  const ReturnRow(this.doc, this.partyName, this.invoiceNumber);
  final ReturnDoc doc;
  final String? partyName;
  final String? invoiceNumber;
}

/// Sale returns (goods back in, customer credited or refunded) and purchase
/// returns (goods back to the supplier, the mirror image).
class ReturnService {
  ReturnService(this.db);

  final AppDatabase db;

  /// Finds an active invoice by number ("S-000012", or just "12") or id.
  Future<ReturnSource?> findInvoice(String kind, {String? number, int? id}) async {
    String? full;
    if (number != null) {
      final n = number.trim().toUpperCase();
      final prefix = kind == ReturnKind.sale ? 'S' : 'P';
      final digits = int.tryParse(n.replaceFirst(RegExp('^$prefix-?'), ''));
      full = digits == null ? n : '$prefix-${digits.toString().padLeft(6, '0')}';
    }
    if (kind == ReturnKind.sale) {
      final inv = await (db.select(db.salesInvoices)
            ..where((t) => (id != null ? t.id.equals(id) : t.number.equals(full!)) &
                t.status.equals(DocStatus.active)))
          .getSingleOrNull();
      if (inv == null) return null;
      final c = inv.customerId == null
          ? null
          : await (db.select(db.customers)..where((t) => t.id.equals(inv.customerId!))).getSingle();
      return ReturnSource(id: inv.id, number: inv.number, partyId: c?.id, partyName: c?.name);
    }
    final inv = await (db.select(db.purchaseInvoices)
          ..where((t) => (id != null ? t.id.equals(id) : t.number.equals(full!)) &
              t.status.equals(DocStatus.active)))
        .getSingleOrNull();
    if (inv == null) return null;
    final s = await (db.select(db.suppliers)..where((t) => t.id.equals(inv.supplierId))).getSingle();
    return ReturnSource(id: inv.id, number: inv.number, partyId: s.id, partyName: s.name);
  }

  Future<List<ReturnDetailLine>> lines(int returnId) async {
    final rows = await (db.select(db.returnItems).join([
      innerJoin(db.products, db.products.id.equalsExp(db.returnItems.productId)),
    ])
          ..where(db.returnItems.returnId.equals(returnId))
          ..orderBy([OrderingTerm(expression: db.returnItems.id)]))
        .get();
    return [
      for (final r in rows)
        ReturnDetailLine(r.readTable(db.returnItems), r.readTable(db.products).code, r.readTable(db.products).nameAr),
    ];
  }

  Future<List<ReturnableLine>> returnableForSale(int invoiceId) async {
    final rows = await (db.select(db.salesInvoiceItems).join([
      innerJoin(db.products, db.products.id.equalsExp(db.salesInvoiceItems.productId)),
      leftOuterJoin(db.units, db.units.id.equalsExp(db.products.unitId)),
    ])
          ..where(db.salesInvoiceItems.invoiceId.equals(invoiceId))
          ..orderBy([OrderingTerm(expression: db.salesInvoiceItems.id)]))
        .get();
    final returned = await _returnedQty(ReturnKind.sale, invoiceId);
    final byProduct = <int, ReturnableLine>{};
    for (final r in rows) {
      final item = r.readTable(db.salesInvoiceItems);
      final p = r.readTable(db.products);
      final prev = byProduct[p.id];
      final qty = (prev?.invoicedQty ?? 0) + item.qty;
      final value = (prev == null ? 0 : lineAmount(prev.invoicedQty, prev.unitPrice)) + item.lineTotal;
      byProduct[p.id] = ReturnableLine(
        productId: p.id,
        code: p.code,
        name: p.nameAr,
        unitName: r.readTableOrNull(db.units)?.nameAr,
        allowDecimal: r.readTableOrNull(db.units)?.allowDecimal ?? false,
        invoicedQty: qty,
        returnedQty: returned[p.id] ?? 0,
        // Value per whole unit after line discounts.
        unitPrice: qty == 0 ? 0 : (value * qtyScale + qty ~/ 2) ~/ qty,
        unitCost: prev?.unitCost ?? item.unitCost,
      );
    }
    return byProduct.values.toList();
  }

  Future<List<ReturnableLine>> returnableForPurchase(int invoiceId) async {
    final rows = await (db.select(db.purchaseInvoiceItems).join([
      innerJoin(db.products, db.products.id.equalsExp(db.purchaseInvoiceItems.productId)),
      leftOuterJoin(db.units, db.units.id.equalsExp(db.products.unitId)),
    ])
          ..where(db.purchaseInvoiceItems.invoiceId.equals(invoiceId))
          ..orderBy([OrderingTerm(expression: db.purchaseInvoiceItems.id)]))
        .get();
    final returned = await _returnedQty(ReturnKind.purchase, invoiceId);
    final byProduct = <int, ReturnableLine>{};
    for (final r in rows) {
      final item = r.readTable(db.purchaseInvoiceItems);
      final p = r.readTable(db.products);
      final prev = byProduct[p.id];
      byProduct[p.id] = ReturnableLine(
        productId: p.id,
        code: p.code,
        name: p.nameAr,
        unitName: r.readTableOrNull(db.units)?.nameAr,
        allowDecimal: r.readTableOrNull(db.units)?.allowDecimal ?? false,
        invoicedQty: (prev?.invoicedQty ?? 0) + item.qty,
        returnedQty: returned[p.id] ?? 0,
        unitPrice: prev?.unitPrice ?? item.unitCost,
        unitCost: prev?.unitCost ?? item.unitCost,
      );
    }
    return byProduct.values.toList();
  }

  Future<Map<int, int>> _returnedQty(String kind, int invoiceId) async {
    final rows = await (db.select(db.returnItems).join([
      innerJoin(db.returns, db.returns.id.equalsExp(db.returnItems.returnId)),
    ])
          ..where(db.returns.kind.equals(kind) &
              db.returns.originalInvoiceId.equals(invoiceId) &
              db.returns.status.equals(DocStatus.active)))
        .get();
    final result = <int, int>{};
    for (final r in rows) {
      final item = r.readTable(db.returnItems);
      result[item.productId] = (result[item.productId] ?? 0) + item.qty;
    }
    return result;
  }

  /// Goods come back from a customer. Anyone may post a sale return.
  Future<ReturnDoc> postSaleReturn(ReturnInput input, {required User user}) {
    return db.transaction(() async {
      int? customerId = input.partyId;
      Map<int, ReturnableLine>? returnable;
      if (input.originalInvoiceId != null) {
        final inv = await (db.select(db.salesInvoices)..where((t) => t.id.equals(input.originalInvoiceId!)))
            .getSingle();
        if (inv.status != DocStatus.active) throw ValidationException('الفاتورة ${inv.number} ملغاة');
        customerId = inv.customerId;
        returnable = {for (final l in await returnableForSale(inv.id)) l.productId: l};
      }
      final total = await _validate(input, returnable);
      if (customerId == null && input.refundAmount != total) {
        throw ValidationException('مرتجع بيع نقدي بدون عميل يجب رد قيمته بالكامل');
      }
      if (customerId != null) {
        final c = await (db.select(db.customers)..where((t) => t.id.equals(customerId!))).getSingleOrNull();
        if (c == null) throw ValidationException('اختر العميل');
      }

      final date = input.date ?? DateTime.now();
      final returnId = await _insertDoc(input, ReturnKind.sale, customerId, total, date);
      final stock = StockService(db);
      for (final line in input.lines) {
        final p = await (db.select(db.products)..where((t) => t.id.equals(line.productId))).getSingle();
        // Back into stock at the original sale cost (or today's cost).
        final cost = returnable?[line.productId]?.unitCost ?? p.costPrice;
        await _setCost(
          p.id,
          averageCostAfterAdding(
            stock: await stock.currentStock(p.id),
            cost: p.costPrice,
            qty: line.qty,
            unitCost: cost,
          ),
        );
        await stock.record(
          productId: p.id,
          type: StockMovementType.saleReturn,
          qty: line.qty,
          unitCost: cost,
          refType: RefType.returnDoc,
          refId: returnId,
          createdBy: user.id,
          date: date,
        );
      }
      if (input.refundAmount > 0) {
        await _refund(
          input,
          returnId,
          direction: PaymentDirection.outbound,
          partyType: PartyType.customer,
          partyId: customerId ?? walkInCustomerId,
          date: date,
          userId: user.id,
        );
      }
      return _finish(returnId, user.id);
    });
  }

  /// Goods go back to a supplier. Admin only.
  Future<ReturnDoc> postPurchaseReturn(ReturnInput input, {required User user}) {
    return db.transaction(() async {
      if (!user.isAdmin) throw ValidationException('مرتجع الشراء للمدير فقط');
      int? supplierId = input.partyId;
      Map<int, ReturnableLine>? returnable;
      if (input.originalInvoiceId != null) {
        final inv = await (db.select(db.purchaseInvoices)
              ..where((t) => t.id.equals(input.originalInvoiceId!)))
            .getSingle();
        if (inv.status != DocStatus.active) throw ValidationException('الفاتورة ${inv.number} ملغاة');
        supplierId = inv.supplierId;
        returnable = {for (final l in await returnableForPurchase(inv.id)) l.productId: l};
      }
      if (supplierId == null) throw ValidationException('اختر المورد');
      final total = await _validate(input, returnable);

      final stock = StockService(db);
      final allowNegative = await SettingsService(db).getBool(SettingKey.allowNegativeStock);
      final needed = <int, int>{};
      for (final l in input.lines) {
        needed[l.productId] = (needed[l.productId] ?? 0) + l.qty;
      }
      for (final e in needed.entries) {
        final onHand = await stock.currentStock(e.key);
        if (!allowNegative && onHand < e.value) {
          final p = await (db.select(db.products)..where((t) => t.id.equals(e.key))).getSingle();
          throw ValidationException(
            'الكمية غير متاحة: "${p.nameAr}" المتاح ${formatQty(onHand)} والمطلوب ${formatQty(e.value)}',
          );
        }
      }

      final date = input.date ?? DateTime.now();
      final returnId = await _insertDoc(input, ReturnKind.purchase, supplierId, total, date);
      for (final line in input.lines) {
        final p = await (db.select(db.products)..where((t) => t.id.equals(line.productId))).getSingle();
        final cost = returnable?[line.productId]?.unitCost ?? line.unitPrice;
        await _setCost(
          p.id,
          averageCostAfterRemoving(
            stock: await stock.currentStock(p.id),
            cost: p.costPrice,
            qty: line.qty,
            unitCost: cost,
          ),
        );
        await stock.record(
          productId: p.id,
          type: StockMovementType.purchaseReturn,
          qty: -line.qty,
          unitCost: cost,
          refType: RefType.returnDoc,
          refId: returnId,
          createdBy: user.id,
          date: date,
        );
      }
      if (input.refundAmount > 0) {
        await _refund(
          input,
          returnId,
          direction: PaymentDirection.inbound,
          partyType: PartyType.supplier,
          partyId: supplierId,
          date: date,
          userId: user.id,
        );
      }
      return _finish(returnId, user.id);
    });
  }

  /// Admin only. Reverses the stock and cancels the refund payment.
  Future<void> cancel(int returnId, {required String reason, required User user}) {
    return db.transaction(() async {
      if (!user.isAdmin) throw ValidationException('إلغاء المرتجعات للمدير فقط');
      if (reason.trim().isEmpty) throw ValidationException('سبب الإلغاء مطلوب');
      final doc = await (db.select(db.returns)..where((t) => t.id.equals(returnId))).getSingle();
      if (doc.status == DocStatus.cancelled) throw ValidationException('المرتجع ${doc.number} ملغى من قبل');
      final note = 'سبب الإلغاء: ${reason.trim()}';
      final stock = StockService(db);
      final allowNegative = await SettingsService(db).getBool(SettingKey.allowNegativeStock);
      final movements = await (db.select(db.stockMovements)
            ..where((t) => t.refType.equals(RefType.returnDoc) & t.refId.equals(returnId)))
          .get();
      for (final m in movements) {
        final p = await (db.select(db.products)..where((t) => t.id.equals(m.productId))).getSingle();
        final onHand = await stock.currentStock(p.id);
        // A sale return put stock in; cancelling takes it out again.
        if (m.qty > 0 && !allowNegative && onHand < m.qty) {
          throw ValidationException('لا يمكن الإلغاء: الكمية المتاحة من "${p.nameAr}" أقل من كمية المرتجع');
        }
        await _setCost(
          p.id,
          m.qty > 0
              ? averageCostAfterRemoving(stock: onHand, cost: p.costPrice, qty: m.qty, unitCost: m.unitCost)
              : averageCostAfterAdding(stock: onHand, cost: p.costPrice, qty: -m.qty, unitCost: m.unitCost),
        );
        await stock.record(
          productId: p.id,
          type: StockMovementType.returnCancel,
          qty: -m.qty,
          unitCost: m.unitCost,
          refType: RefType.returnDoc,
          refId: returnId,
          note: note,
          createdBy: user.id,
        );
      }
      await (db.update(db.returns)..where((t) => t.id.equals(returnId))).write(ReturnsCompanion(
            status: const Value(DocStatus.cancelled),
            notes: Value(doc.notes == null ? note : '${doc.notes}\n$note'),
            updatedAt: Value(DateTime.now()),
          ));
      await (db.update(db.payments)
            ..where((t) =>
                t.invoiceRefType.equals(RefType.returnDoc) &
                t.invoiceRefId.equals(returnId) &
                t.status.equals(DocStatus.active)))
          .write(PaymentsCompanion(status: const Value(DocStatus.cancelled), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
        action: AuditAction.cancel,
        entity: 'return',
        entityId: returnId,
        userId: user.id,
        details: '${doc.number}: ${reason.trim()}',
      );
    });
  }

  Stream<List<ReturnRow>> watchList({String? kind}) {
    final query = db.select(db.returns).join([
      leftOuterJoin(db.customers,
          db.customers.id.equalsExp(db.returns.partyId) & db.returns.kind.equals(ReturnKind.sale)),
      leftOuterJoin(db.suppliers,
          db.suppliers.id.equalsExp(db.returns.partyId) & db.returns.kind.equals(ReturnKind.purchase)),
      leftOuterJoin(db.salesInvoices,
          db.salesInvoices.id.equalsExp(db.returns.originalInvoiceId) & db.returns.kind.equals(ReturnKind.sale)),
      leftOuterJoin(db.purchaseInvoices,
          db.purchaseInvoices.id.equalsExp(db.returns.originalInvoiceId) &
              db.returns.kind.equals(ReturnKind.purchase)),
    ]);
    if (kind != null) query.where(db.returns.kind.equals(kind));
    query.orderBy([OrderingTerm.desc(db.returns.id)]);
    return query.watch().map((rows) => [
          for (final r in rows)
            ReturnRow(
              r.readTable(db.returns),
              r.readTableOrNull(db.customers)?.name ?? r.readTableOrNull(db.suppliers)?.name,
              r.readTableOrNull(db.salesInvoices)?.number ?? r.readTableOrNull(db.purchaseInvoices)?.number,
            ),
        ]);
  }

  /// Checks the lines (and, with an original invoice, that no more goes back
  /// than was invoiced) and returns the total.
  Future<int> _validate(ReturnInput input, Map<int, ReturnableLine>? returnable) async {
    if (input.lines.isEmpty) throw ValidationException('أضف صنفاً واحداً على الأقل');
    final units = {for (final u in await db.select(db.units).get()) u.id: u};
    final perProduct = <int, int>{};
    for (final line in input.lines) {
      final p = await (db.select(db.products)..where((t) => t.id.equals(line.productId))).getSingle();
      if (line.qty <= 0) throw ValidationException('الكمية يجب أن تكون أكبر من صفر (${p.nameAr})');
      if (!(units[p.unitId]?.allowDecimal ?? false) && !isWholeQty(line.qty)) {
        throw ValidationException('الكمية يجب أن تكون رقماً صحيحاً (${p.nameAr})');
      }
      if (line.unitPrice < 0) throw ValidationException('السعر لا يمكن أن يكون سالباً (${p.nameAr})');
      perProduct[p.id] = (perProduct[p.id] ?? 0) + line.qty;
      if (returnable != null) {
        final r = returnable[p.id];
        if (r == null) throw ValidationException('الصنف "${p.nameAr}" ليس في الفاتورة الأصلية');
        if (perProduct[p.id]! > r.returnable) {
          throw ValidationException(
            'الكمية المرتجعة من "${p.nameAr}" أكبر من المتاح للإرجاع (${formatQty(r.returnable)})',
          );
        }
      }
    }
    final total = input.total;
    if (input.refundAmount < 0 || input.refundAmount > total) {
      throw ValidationException('المبلغ المردود يجب أن يكون بين صفر وإجمالي المرتجع');
    }
    if (input.refundAmount > 0 &&
        input.refundMethod != PaymentMethod.cash &&
        input.refundMethod != PaymentMethod.bank) {
      throw ArgumentError.value(input.refundMethod, 'refundMethod');
    }
    return total;
  }

  Future<int> _insertDoc(ReturnInput input, String kind, int? partyId, int total, DateTime date) async {
    final id = await db.into(db.returns).insert(ReturnsCompanion.insert(
          number: await NumberingService(db).next('return'),
          kind: kind,
          date: date,
          partyId: Value(partyId),
          originalInvoiceId: Value(input.originalInvoiceId),
          total: total,
          refundAmount: Value(input.refundAmount),
          notes: Value((input.notes ?? '').trim().isEmpty ? null : input.notes!.trim()),
        ));
    for (final line in input.lines) {
      await db.into(db.returnItems).insert(ReturnItemsCompanion.insert(
            returnId: id,
            productId: line.productId,
            qty: line.qty,
            unitPrice: line.unitPrice,
            lineTotal: line.total,
          ));
    }
    return id;
  }

  Future<void> _refund(
    ReturnInput input,
    int returnId, {
    required String direction,
    required String partyType,
    required int partyId,
    required DateTime date,
    int? userId,
  }) async {
    await db.into(db.payments).insert(PaymentsCompanion.insert(
          number: await NumberingService(db).next('payment'),
          date: date,
          direction: direction,
          partyType: partyType,
          partyId: partyId,
          amount: input.refundAmount,
          method: input.refundMethod,
          invoiceRefType: const Value(RefType.returnDoc),
          invoiceRefId: Value(returnId),
          createdBy: Value(userId),
        ));
  }

  Future<ReturnDoc> _finish(int returnId, int userId) async {
    final doc = await (db.select(db.returns)..where((t) => t.id.equals(returnId))).getSingle();
    await AuditService(db).log(
      action: AuditAction.create,
      entity: 'return',
      entityId: returnId,
      userId: userId,
      details: '${doc.number} ${formatMoney(doc.total)}',
    );
    return doc;
  }

  Future<void> _setCost(int productId, int cost) =>
      (db.update(db.products)..where((t) => t.id.equals(productId))).write(
        ProductsCompanion(costPrice: Value(cost), updatedAt: Value(DateTime.now())),
      );
}
