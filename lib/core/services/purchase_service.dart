import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../dates.dart';
import '../db/database.dart';
import '../money.dart';
import '../pricing_math.dart';
import '../quantity.dart';
import 'audit_service.dart';
import 'balance_service.dart';
import 'doc_types.dart';
import 'errors.dart';
import 'fifo_service.dart';
import 'numbering_service.dart';
import 'payment_service.dart';
import 'query_helpers.dart';
import 'settings_service.dart';
import 'stock_service.dart';
import 'supplier_advance_service.dart';

class PurchaseLineInput {
  const PurchaseLineInput({
    required this.productId,
    required this.qty,
    required this.unitCost,
    this.priceListId,
    this.listPrice,
    this.buyingPolicyId,
    this.baseDiscountBp = 0,
    this.extraDiscountBp = 0,
    this.listCategoryId,
    this.listCategoryName,
    this.locationId,
  });

  /// Where this line is received (part to the showroom, part to the
  /// warehouse); null takes the invoice's place.
  final int? locationId;

  /// The price list category whose usual discount was used (no supplier
  /// discount was recorded), kept as it was that day.
  final int? listCategoryId;
  final String? listCategoryName;

  final int productId;

  /// Thousandths of a unit.
  final int qty;

  /// Piastres per whole unit.
  final int unitCost;

  /// The version and buying policy this cost came from; null = typed by hand.
  final int? priceListId;
  final int? listPrice;
  final int? buyingPolicyId;
  final int baseDiscountBp;
  final int extraDiscountBp;

  int get total => lineAmount(qty, unitCost);
}

class PurchaseInput {
  const PurchaseInput({
    this.vatAmount = 0,
    this.isDirect = false,
    this.salesInvoiceId,
    required this.supplierId,
    required this.lines,
    this.supplierInvoiceNo,
    this.date,
    this.discount = 0,
    this.extraCosts = 0,
    this.extraCostsOnSupplier = true,
    this.extraCostsNote,
    this.dueDate,
    this.paidAmount = 0,
    this.paymentMethod = PaymentMethod.cash,
    this.cheque,
    this.notes,
    this.locationId = mainLocationId,
    this.allowDuplicateSupplierNo = false,
    this.advanceAmount = 0,
    this.discountBp,
    this.projectId,
  });

  /// Bought for this project, if any.
  final int? projectId;

  /// Paid from the supplier's advance balance (any of their advances, oldest
  /// first). Part of the invoice or all of it; 0 = none.
  final int advanceAmount;

  /// The invoice discount typed as a percent (basis points), kept with the
  /// invoice; null = typed as an amount (or none). [discount] is the amount.
  final int? discountBp;

  /// Transport, unloading and the like, added to the goods' cost. On the
  /// supplier's invoice ([extraCostsOnSupplier]) they are owed to the
  /// supplier; otherwise they were paid in cash to someone else.
  final int extraCosts;
  final bool extraCostsOnSupplier;
  final String? extraCostsNote;

  /// When what is left to pay is due.
  final DateTime? dueDate;

  /// Required when [paymentMethod] is a cheque.
  final ChequeInput? cheque;

  /// The supplier's invoice number was already used for this supplier and
  /// the person confirmed it is a different invoice.
  final bool allowDuplicateSupplierNo;

  /// Where the goods are received.
  final int locationId;
  final int supplierId;
  final List<PurchaseLineInput> lines;
  final String? supplierInvoiceNo;
  final DateTime? date;
  final int discount;
  final int paidAmount;
  final String paymentMethod;
  final String? notes;

  /// Recoverable input VAT on the supplier's tax invoice (owed to the
  /// supplier, not part of the goods' cost).
  final int vatAmount;

  /// Delivered by the supplier straight to a customer: no stock, the cost
  /// is the cost of that sale ([salesInvoiceId]).
  final bool isDirect;
  final int? salesInvoiceId;

  int get subtotal => lines.fold(0, (s, l) => s + l.total);

  /// What is owed to the supplier.
  int get total => subtotal - discount + (extraCostsOnSupplier ? extraCosts : 0) + vatAmount;
}

/// Thrown when the supplier's invoice number is already on another of this
/// supplier's invoices; the screen asks before saving again.
class DuplicateSupplierInvoiceException extends ValidationException {
  DuplicateSupplierInvoiceException(this.existing)
      : super('رقم فاتورة المورد ${existing.supplierInvoiceNo} مسجل من قبل في الفاتورة ${existing.number}');

  final PurchaseInvoice existing;
}

/// The expense category for extra purchase costs paid to someone else.
const purchaseCostsCategoryName = 'نقل وتحميل مشتريات';

class PurchaseInvoiceRow {
  const PurchaseInvoiceRow(this.invoice, this.supplierName, this.paid);
  final PurchaseInvoice invoice;
  final String supplierName;

  /// Everything paid against it so far (counted payments).
  final int paid;
}

class PurchaseInvoiceLine {
  const PurchaseInvoiceLine(this.item, this.productCode, this.productName, this.unitName, {this.modelNo});
  final PurchaseInvoiceItem item;
  final String productCode;
  final String productName;
  final String? unitName;

  /// The maker's model number, shown under the name and printed.
  final String? modelNo;
}

class PurchaseInvoiceDetail {
  const PurchaseInvoiceDetail(this.invoice, this.supplier, this.lines, this.paid);
  final PurchaseInvoice invoice;
  final Supplier supplier;
  final List<PurchaseInvoiceLine> lines;
  final int paid;
}

/// Purchase invoices: stock in, a FIFO layer at the invoice's cost, supplier owed.
/// Admin only.
class PurchaseService {
  PurchaseService(this.db);

  final AppDatabase db;

  Future<PurchaseInvoice> post(PurchaseInput input, {required User user}) {
    return db.transaction(() async {
      if (!user.can(Perm.purchase)) throw ValidationException('فواتير الشراء لصلاحية المشتريات');
      await refuseSoftClosed(db, input.date ?? DateTime.now(), user.id);
      if (input.lines.isEmpty) throw ValidationException('أضف صنفاً واحداً على الأقل');
      final supplier = await (db.select(db.suppliers)..where((t) => t.id.equals(input.supplierId)))
          .getSingleOrNull();
      if (supplier == null) throw ValidationException('اختر المورد');
      if (!supplier.isActive) throw ValidationException('المورد "${supplier.name}" موقوف');

      final units = {for (final u in await db.select(db.units).get()) u.id: u};
      final products = <int, Product>{};
      for (final line in input.lines) {
        final p = products[line.productId] ??=
            await (db.select(db.products)..where((t) => t.id.equals(line.productId))).getSingle();
        if (line.qty <= 0) throw ValidationException('الكمية يجب أن تكون أكبر من صفر (${p.nameAr})');
        if (!(units[p.unitId]?.allowDecimal ?? false) && !isWholeQty(line.qty)) {
          throw ValidationException('الكمية يجب أن تكون رقماً صحيحاً (${p.nameAr})');
        }
        if (line.unitCost < 0) throw ValidationException('التكلفة لا يمكن أن تكون سالبة (${p.nameAr})');
      }
      final subtotal = input.subtotal;
      if (input.discount < 0 || input.discount > subtotal) {
        throw ValidationException('خصم الفاتورة أكبر من قيمتها');
      }
      if (input.extraCosts < 0) throw ValidationException('المصاريف الإضافية لا يمكن أن تكون سالبة');
      if (input.vatAmount < 0) throw ValidationException('الضريبة لا تكون سالبة');
      if (input.discountBp != null && (input.discountBp! < 0 || input.discountBp! > 10000)) {
        throw ValidationException('نسبة الخصم يجب أن تكون بين 0 و 100');
      }
      final total = input.total;
      if (input.paidAmount < 0 || input.paidAmount > total) {
        throw ValidationException('المبلغ المدفوع يجب أن يكون بين صفر وإجمالي الفاتورة');
      }
      if (input.advanceAmount < 0) throw ValidationException('المبلغ من الدفعة المقدمة لا يكون سالباً');
      if (input.paidAmount + input.advanceAmount > total) {
        throw ValidationException('المدفوع والمخصوم من الدفعة المقدمة معاً أكبر من إجمالي الفاتورة');
      }
      if (input.advanceAmount > 0) {
        final available = (await SupplierAdvanceService(db).balance(input.supplierId)).remaining;
        if (input.advanceAmount > available) {
          throw ValidationException('رصيد الدفعات المقدمة لهذا المورد ${formatMoney(available)} فقط');
        }
      }
      final supplierNo = _blankToNull(input.supplierInvoiceNo);
      if (supplierNo != null && !input.allowDuplicateSupplierNo) {
        final same = await findBySupplierNo(input.supplierId, supplierNo);
        if (same != null) throw DuplicateSupplierInvoiceException(same);
      }

      final numbering = NumberingService(db);
      final date = input.date ?? DateTime.now();
      if (input.dueDate != null && dayOf(input.dueDate!).isBefore(dayOf(date))) {
        throw ValidationException('تاريخ الاستحقاق قبل تاريخ الفاتورة');
      }
      final invoiceId = await db.into(db.purchaseInvoices).insert(PurchaseInvoicesCompanion.insert(
            number: await numbering.next('purchase'),
            supplierInvoiceNo: Value(supplierNo),
            date: date,
            supplierId: input.supplierId,
            subtotal: subtotal,
            projectId: Value(input.projectId),
            discount: Value(input.discount),
            total: total,
            paidAmount: Value(input.paidAmount),
            notes: Value(_blankToNull(input.notes)),
            createdBy: Value(user.id),
            extraCosts: Value(input.extraCosts),
            extraCostsOnSupplier: Value(input.extraCostsOnSupplier),
            dueDate: Value(input.paidAmount + input.advanceAmount >= total || input.dueDate == null
                ? null
                : dayOf(input.dueDate!)),
            discountBp: Value(input.discountBp),
            vatAmount: Value(input.vatAmount),
            isDirect: Value(input.isDirect),
            salesInvoiceId: Value(input.salesInvoiceId),
          ));

      final places = {for (final l in await db.select(db.locations).get()) l.id: l};
      if (!input.isDirect) {
        for (final id in {input.locationId, for (final l in input.lines) ?l.locationId}) {
          final place = places[id];
          if (place == null || !place.isActive) throw ValidationException('مكان الاستلام غير موجود أو موقوف');
        }
      }
      final stock = StockService(db);
      final fifo = FifoService(db);
      // The invoice discount lowers the real cost of the goods, line by line.
      final shares = allocateProportionally(input.discount, [for (final l in input.lines) l.total]);
      // Extra costs raise it, split by each line's value after the discount.
      final extraShares = allocateProportionally(
          input.extraCosts, [for (var n = 0; n < input.lines.length; n++) input.lines[n].total - shares[n]]);
      for (var n = 0; n < input.lines.length; n++) {
        final line = input.lines[n];
        final net = line.total - shares[n];
        final netUnitCost = ((net + extraShares[n]) * qtyScale / line.qty).round();
        await db.into(db.purchaseInvoiceItems).insert(PurchaseInvoiceItemsCompanion.insert(
              invoiceId: invoiceId,
              productId: line.productId,
              qty: line.qty,
              unitCost: line.unitCost,
              lineTotal: line.total,
              priceListId: Value(line.priceListId),
              listPrice: Value(line.listPrice),
              buyingPolicyId: Value(line.buyingPolicyId),
              baseDiscountBp: Value(line.baseDiscountBp),
              extraDiscountBp: Value(line.extraDiscountBp),
              invoiceDiscountShare: Value(shares[n]),
              netTotal: Value(net),
              extraCostShare: Value(extraShares[n]),
              listCategoryId: Value(line.listCategoryId),
              listCategoryName: Value(line.listCategoryName),
            ));
        final p = products[line.productId]!;
        // Delivered straight to the customer: never in stock.
        if (input.isDirect) continue;
        await fifo.addLayer(
          productId: p.id,
          qty: line.qty,
          unitCost: netUnitCost,
          locationId: line.locationId ?? input.locationId,
          receivedAt: date,
          supplierId: input.supplierId,
          sourceType: 'purchase',
          sourceId: invoiceId,
          priceListId: line.priceListId,
          listPrice: line.listPrice,
        );
        await stock.record(
          productId: p.id,
          type: StockMovementType.purchase,
          qty: line.qty,
          unitCost: netUnitCost,
          refType: RefType.purchaseInvoice,
          refId: invoiceId,
          createdBy: user.id,
          date: date,
          locationId: line.locationId ?? input.locationId,
        );
      }

      if (input.paidAmount > 0) {
        // Cash, bank or a cheque, through the same rules as any payment.
        await PaymentService(db).pay(
          PaymentInput(
            partyId: input.supplierId,
            amount: input.paidAmount,
            method: input.paymentMethod,
            cheque: input.cheque,
            invoiceId: invoiceId,
            date: date,
          ),
          user: user,
        );
      }

      // Part of the supplier's advance balance pays this invoice.
      if (input.advanceAmount > 0) {
        await SupplierAdvanceService(db).allocate(invoiceId: invoiceId, amount: input.advanceAmount, user: user);
      }

      // Extra costs paid to someone else: a purchase expense tied to this
      // invoice, already in the goods' cost.
      if (input.extraCosts > 0 && !input.extraCostsOnSupplier) {
        final categoryId = await _purchaseCostsCategory();
        final invoiceNo = (await (db.select(db.purchaseInvoices)..where((t) => t.id.equals(invoiceId))).getSingle()).number;
        await db.into(db.expenses).insert(ExpensesCompanion.insert(
              date: date,
              categoryId: categoryId,
              amount: input.extraCosts,
              description: Value('مصاريف فاتورة الشراء $invoiceNo'
                  '${_blankToNull(input.extraCostsNote) == null ? '' : ' — ${input.extraCostsNote!.trim()}'}'),
              createdBy: Value(user.id),
              purchaseInvoiceId: Value(invoiceId),
              projectId: Value(input.projectId),
            ));
      }

      final invoice = await (db.select(db.purchaseInvoices)..where((t) => t.id.equals(invoiceId)))
          .getSingle();
      await AuditService(db).log(
        action: AuditAction.create,
        entity: 'purchase_invoice',
        entityId: invoiceId,
        userId: user.id,
        details: '${invoice.number} ${supplier.name} ${formatMoney(total)}',
      );
      return invoice;
    });
  }

  /// Admin only. Takes the stock back out (refused if it has been sold,
  /// unless negative stock is allowed), empties its layers and cancels
  /// the payments linked to it.
  Future<void> cancel(int invoiceId, {required String reason, required User user}) {
    return db.transaction(() async {
      if (!user.can(Perm.cancel)) throw ValidationException('إلغاء الفواتير للمدير أو المحاسب');
      final invoice = await (db.select(db.purchaseInvoices)..where((t) => t.id.equals(invoiceId)))
          .getSingle();
      if (invoice.status == DocStatus.cancelled) {
        throw ValidationException('الفاتورة ${invoice.number} ملغاة من قبل');
      }
      await refuseSoftClosed(db, invoice.date, user.id);
      if (invoice.isDirect) {
        throw ValidationException('هذه فاتورة توريد مباشر لعميل؛ تُلغى بإلغاء فاتورة البيع المرتبطة بها');
      }
      final returns = await (db.select(db.returns)
            ..where((t) =>
                t.kind.equals(ReturnKind.purchase) &
                t.originalInvoiceId.equals(invoiceId) &
                t.status.equals(DocStatus.active)))
          .get();
      if (returns.isNotEmpty) {
        throw ValidationException('لا يمكن إلغاء فاتورة عليها مرتجع؛ ألغِ المرتجع أولاً');
      }

      final items = await (db.select(db.purchaseInvoiceItems)
            ..where((t) => t.invoiceId.equals(invoiceId)))
          .get();
      final stock = StockService(db);
      final fifo = FifoService(db);
      final allowNegative = await SettingsService(db).getBool(SettingKey.allowNegativeStock);
      final note = 'سبب الإلغاء: ${reason.trim()}';
      final voided = await fifo.voidSourceLayers('purchase', invoiceId);
      for (final item in items.reversed) {
        final p = await (db.select(db.products)..where((t) => t.id.equals(item.productId))).getSingle();
        final onHand = await stock.currentStock(p.id);
        if (!allowNegative && onHand < item.qty) {
          throw ValidationException(
            'لا يمكن الإلغاء: الصنف "${p.nameAr}" المتاح ${formatQty(onHand)} '
            'وكمية الفاتورة ${formatQty(item.qty)} (تم بيع جزء منها)',
          );
        }
        // Empty the layers this purchase made, place by place; what has moved
        // on or was made before layers existed comes off the other places.
        var rest = item.qty;
        for (var k = 0; k < voided.length && rest > 0; k++) {
          final (productId, place, qty) = voided[k];
          if (productId != p.id || qty == 0) continue;
          final take = qty < rest ? qty : rest;
          voided[k] = (productId, place, qty - take);
          rest -= take;
          await stock.record(
            productId: p.id,
            type: StockMovementType.purchaseCancel,
            qty: -take,
            unitCost: item.unitCost,
            refType: RefType.purchaseInvoice,
            refId: invoiceId,
            note: note,
            createdBy: user.id,
            locationId: place,
          );
        }
        if (rest > 0) {
          final parts = await fifo.consumeAcross(
            productId: p.id,
            qty: rest,
            locationIds: await stock.allLocationIds(),
            refType: 'purchase_cancel',
            refId: invoiceId,
            fallbackCost: item.unitCost,
          );
          for (final part in parts) {
            await stock.record(
              productId: p.id,
              type: StockMovementType.purchaseCancel,
              qty: -part.take.qty,
              unitCost: item.unitCost,
              refType: RefType.purchaseInvoice,
              refId: invoiceId,
              note: note,
              createdBy: user.id,
              locationId: part.locationId,
            );
          }
        }
      }

      await (db.update(db.purchaseInvoices)..where((t) => t.id.equals(invoiceId))).write(
        PurchaseInvoicesCompanion(
          status: const Value(DocStatus.cancelled),
          notes: Value(invoice.notes == null ? note : '${invoice.notes}\n$note'),
          updatedAt: Value(DateTime.now()),
        ),
      );
      final paymentIds = (await (db.select(db.payments)
                ..where((t) =>
                    t.invoiceRefType.equals(RefType.purchaseInvoice) &
                    t.invoiceRefId.equals(invoiceId) &
                    t.status.equals(DocStatus.active)))
              .get())
          .map((p) => p.id)
          .toList();
      await (db.update(db.payments)..where((t) => t.id.isIn(paymentIds)))
          .write(PaymentsCompanion(status: const Value(DocStatus.cancelled), updatedAt: Value(DateTime.now())));
      // What it took from the supplier's advances goes back to them.
      await SupplierAdvanceService(db).releaseInvoice(invoiceId);
      // A cheque written with it is cancelled too, unless it was already paid.
      await (db.update(db.cheques)
            ..where((t) => t.paymentId.isIn(paymentIds) & t.status.equals(ChequeStatus.pending)))
          .write(ChequesCompanion(status: const Value(ChequeStatus.cancelled), updatedAt: Value(DateTime.now())));
      // Its extra costs paid to someone else.
      await (db.update(db.expenses)
            ..where((t) => t.purchaseInvoiceId.equals(invoiceId) & t.status.equals(DocStatus.active)))
          .write(ExpensesCompanion(status: const Value(DocStatus.cancelled), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
        action: AuditAction.cancel,
        entity: 'purchase_invoice',
        entityId: invoiceId,
        userId: user.id,
        details: '${invoice.number}: ${reason.trim()}',
      );
    });
  }

  /// Owner only: replaces a saved invoice with a corrected one (quantities,
  /// costs, discount, extra costs, VAT, date...). In one step the corrected
  /// invoice is posted, the payments and the advance amount of the old one
  /// move to it, and the old one is cancelled and kept on record. Stock,
  /// costs, the supplier's balance and the books follow from the documents.
  /// [replacement] must be for the same supplier; its paid amount is not
  /// used (the old payments carry over).
  Future<PurchaseInvoice> correct(int invoiceId, PurchaseInput replacement, {required String reason, required User user}) {
    return db.transaction(() async {
      if (!user.isAdmin) throw ValidationException('تصحيح فواتير الشراء للمالك فقط');
      final old = await (db.select(db.purchaseInvoices)..where((t) => t.id.equals(invoiceId))).getSingleOrNull();
      if (old == null) throw ValidationException('الفاتورة غير موجودة');
      if (old.status != DocStatus.active) throw ValidationException('الفاتورة ${old.number} ملغاة');
      if (old.isDirect) throw ValidationException('فاتورة التوريد المباشر تُصحح من فاتورة البيع المرتبطة بها');
      if (replacement.supplierId != old.supplierId) throw ValidationException('التصحيح لنفس المورد فقط');
      await refuseLocked(db, old.date);
      await refuseLocked(db, replacement.date ?? old.date);
      final payments = await (db.select(db.payments)
            ..where((t) =>
                t.invoiceRefType.equals(RefType.purchaseInvoice) &
                t.invoiceRefId.equals(invoiceId) &
                t.status.equals(DocStatus.active)))
          .get();
      final paid = payments.fold<int>(0, (s, p) => s + p.amount);
      final fromAdvance = old.advanceUsed;
      if (paid + fromAdvance > replacement.total) {
        throw ValidationException('المدفوع على الفاتورة (${formatMoney(paid + fromAdvance)}) أكبر من إجماليها بعد '
            'التصحيح (${formatMoney(replacement.total)}). ألغِ أو صحّح الدفعة الزائدة أولاً.');
      }
      final advances = SupplierAdvanceService(db);
      // The old one's advance amount is freed first so the new one can take it.
      await advances.releaseInvoice(invoiceId);
      await advances.syncInvoice(invoiceId);
      final fresh = await post(
        PurchaseInput(
          supplierId: replacement.supplierId,
          lines: replacement.lines,
          supplierInvoiceNo: replacement.supplierInvoiceNo ?? old.supplierInvoiceNo,
          date: replacement.date ?? old.date,
          discount: replacement.discount,
          discountBp: replacement.discountBp,
          extraCosts: replacement.extraCosts,
          extraCostsOnSupplier: replacement.extraCostsOnSupplier,
          extraCostsNote: replacement.extraCostsNote,
          dueDate: replacement.dueDate ?? old.dueDate,
          notes: [
            if ((replacement.notes ?? '').trim().isNotEmpty) replacement.notes!.trim(),
            'تصحيح للفاتورة ${old.number}: ${reason.trim()}',
          ].join('\n'),
          locationId: replacement.locationId,
          allowDuplicateSupplierNo: true,
          advanceAmount: fromAdvance,
          projectId: replacement.projectId ?? old.projectId,
          vatAmount: replacement.vatAmount,
        ),
        user: user,
      );
      // The money already paid stays paid, now on the corrected invoice.
      for (final p in payments) {
        await (db.update(db.payments)..where((t) => t.id.equals(p.id))).write(
            PaymentsCompanion(invoiceRefId: Value(fresh.id), updatedAt: Value(DateTime.now())));
      }
      await cancel(invoiceId, reason: 'استُبدلت بالفاتورة المصححة ${fresh.number}: ${reason.trim()}', user: user);
      await AuditService(db).log(
        action: AuditAction.correct,
        entity: 'purchase_invoice',
        entityId: fresh.id,
        userId: user.id,
        details: '${old.number} ← ${fresh.number}',
        oldValue: 'الإجمالي ${formatMoney(old.total)} · الخصم ${formatMoney(old.discount)} · ${formatDate(old.date)}',
        newValue: 'الإجمالي ${formatMoney(fresh.total)} · الخصم ${formatMoney(fresh.discount)} · ${formatDate(fresh.date)}',
        reason: reason.trim(),
      );
      return (db.select(db.purchaseInvoices)..where((t) => t.id.equals(fresh.id))).getSingle();
    });
  }

  /// Newest first; updates when invoices or payments change.
  Stream<List<PurchaseInvoiceRow>> watchList({DateTime? from, DateTime? to}) async* {
    final pending = await SettingsService(db).getBool(SettingKey.countPendingCheques);
    yield* db.customSelect(
      '''
      SELECT pi.*, su.name AS supplier_name,
             COALESCE((SELECT SUM(p.amount) FROM payments p
                       WHERE p.invoice_ref_type = '${RefType.purchaseInvoice}' AND p.invoice_ref_id = pi.id
                         AND ${BalanceService.countedPayment('p')}), 0) + pi.advance_used AS paid
      FROM purchase_invoices pi
      JOIN suppliers su ON su.id = pi.supplier_id
      WHERE (? IS NULL OR pi.date >= ?) AND (? IS NULL OR pi.date < ?)
      ORDER BY pi.id DESC
      ''',
      variables: [Variable.withBool(pending), ...dateRangeVariables(from, to)],
      readsFrom: {db.purchaseInvoices, db.suppliers, db.payments, db.cheques},
    ).watch().map((rows) => [
          for (final r in rows)
            PurchaseInvoiceRow(
              db.purchaseInvoices.map(r.data),
              r.read<String>('supplier_name'),
              r.read<int>('paid'),
            ),
        ]);
  }

  Future<PurchaseInvoiceDetail> detail(int invoiceId) async {
    final invoice = await (db.select(db.purchaseInvoices)..where((t) => t.id.equals(invoiceId))).getSingle();
    final supplier = await (db.select(db.suppliers)..where((t) => t.id.equals(invoice.supplierId))).getSingle();
    final rows = await (db.select(db.purchaseInvoiceItems).join([
      innerJoin(db.products, db.products.id.equalsExp(db.purchaseInvoiceItems.productId)),
      leftOuterJoin(db.units, db.units.id.equalsExp(db.products.unitId)),
    ])
          ..where(db.purchaseInvoiceItems.invoiceId.equals(invoiceId))
          ..orderBy([OrderingTerm(expression: db.purchaseInvoiceItems.id)]))
        .get();
    return PurchaseInvoiceDetail(
      invoice,
      supplier,
      [
        for (final r in rows)
          PurchaseInvoiceLine(
            r.readTable(db.purchaseInvoiceItems),
            r.readTable(db.products).code,
            r.readTable(db.products).nameAr,
            r.readTableOrNull(db.units)?.nameAr,
            modelNo: r.readTable(db.products).modelNo,
          ),
      ],
      await BalanceService(db).paidOnInvoice(RefType.purchaseInvoice, invoiceId),
    );
  }

  /// This supplier's active invoice with that number of theirs, if any.
  Future<PurchaseInvoice?> findBySupplierNo(int supplierId, String supplierInvoiceNo) async {
    final no = supplierInvoiceNo.trim();
    if (no.isEmpty) return null;
    final rows = await (db.select(db.purchaseInvoices)
          ..where((t) =>
              t.supplierId.equals(supplierId) &
              t.supplierInvoiceNo.equals(no) &
              t.status.equals(DocStatus.active)))
        .get();
    return rows.firstOrNull;
  }

  Future<int> _purchaseCostsCategory() async {
    final all = await db.select(db.expenseCategories).get();
    final found = all.where((c) => c.nameAr == purchaseCostsCategoryName).firstOrNull;
    if (found != null) return found.id;
    return db.into(db.expenseCategories).insert(ExpenseCategoriesCompanion.insert(nameAr: purchaseCostsCategoryName));
  }

  /// Credit purchases with something left to pay and a due date, the
  /// earliest first: overdue ones, and those due within [days].
  Stream<List<SupplierDue>> watchDue({int days = 7}) async* {
    final pending = await SettingsService(db).getBool(SettingKey.countPendingCheques);
    final until = dayOf(DateTime.now()).add(Duration(days: days + 1));
    yield* db.customSelect(
      '''
      SELECT pi.*, su.name AS supplier_name,
             COALESCE((SELECT SUM(p.amount) FROM payments p
                       WHERE p.invoice_ref_type = '${RefType.purchaseInvoice}' AND p.invoice_ref_id = pi.id
                         AND ${BalanceService.countedPayment('p')}), 0) + pi.advance_used AS paid
      FROM purchase_invoices pi
      JOIN suppliers su ON su.id = pi.supplier_id
      WHERE pi.status = '${DocStatus.active}' AND pi.due_date IS NOT NULL AND pi.due_date < ?
      ORDER BY pi.due_date, pi.id
      ''',
      variables: [Variable.withBool(pending), Variable.withDateTime(until)],
      readsFrom: {db.purchaseInvoices, db.suppliers, db.payments, db.cheques},
    ).watch().map((rows) => [
          for (final r in rows)
            if (r.read<int>('total') - r.read<int>('paid') > 0)
              SupplierDue(db.purchaseInvoices.map(r.data), r.read<String>('supplier_name'),
                  r.read<int>('total') - r.read<int>('paid')),
        ]);
  }

  static String? _blankToNull(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();
}

/// A purchase invoice with money still owed and a due date.
class SupplierDue {
  const SupplierDue(this.invoice, this.supplierName, this.remaining);

  final PurchaseInvoice invoice;
  final String supplierName;
  final int remaining;

  bool get overdue => dayOf(invoice.dueDate!).isBefore(dayOf(DateTime.now()));
}
