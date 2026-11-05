import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../money.dart';
import '../quantity.dart';
import 'audit_service.dart';
import 'balance_service.dart';
import 'doc_types.dart';
import 'errors.dart';
import 'fifo_service.dart';
import 'numbering_service.dart';
import 'query_helpers.dart';
import 'settings_service.dart';
import 'stock_service.dart';

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
  });

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
    required this.supplierId,
    required this.lines,
    this.supplierInvoiceNo,
    this.date,
    this.discount = 0,
    this.paidAmount = 0,
    this.paymentMethod = PaymentMethod.cash,
    this.notes,
  });

  final int supplierId;
  final List<PurchaseLineInput> lines;
  final String? supplierInvoiceNo;
  final DateTime? date;
  final int discount;
  final int paidAmount;
  final String paymentMethod;
  final String? notes;

  int get subtotal => lines.fold(0, (s, l) => s + l.total);
  int get total => subtotal - discount;
}

class PurchaseInvoiceRow {
  const PurchaseInvoiceRow(this.invoice, this.supplierName, this.paid);
  final PurchaseInvoice invoice;
  final String supplierName;

  /// Everything paid against it so far (counted payments).
  final int paid;
}

class PurchaseInvoiceLine {
  const PurchaseInvoiceLine(this.item, this.productCode, this.productName, this.unitName);
  final PurchaseInvoiceItem item;
  final String productCode;
  final String productName;
  final String? unitName;
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
      if (!user.isAdmin) throw ValidationException('فواتير الشراء للمدير فقط');
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
      final total = input.total;
      if (input.paidAmount < 0 || input.paidAmount > total) {
        throw ValidationException('المبلغ المدفوع يجب أن يكون بين صفر وإجمالي الفاتورة');
      }

      final numbering = NumberingService(db);
      final date = input.date ?? DateTime.now();
      final invoiceId = await db.into(db.purchaseInvoices).insert(PurchaseInvoicesCompanion.insert(
            number: await numbering.next('purchase'),
            supplierInvoiceNo: Value(_blankToNull(input.supplierInvoiceNo)),
            date: date,
            supplierId: input.supplierId,
            subtotal: subtotal,
            discount: Value(input.discount),
            total: total,
            paidAmount: Value(input.paidAmount),
            notes: Value(_blankToNull(input.notes)),
            createdBy: Value(user.id),
          ));

      final stock = StockService(db);
      final fifo = FifoService(db);
      for (final line in input.lines) {
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
            ));
        final p = products[line.productId]!;
        await fifo.addLayer(
          productId: p.id,
          qty: line.qty,
          unitCost: line.unitCost,
          receivedAt: date,
          supplierId: input.supplierId,
          sourceType: 'purchase',
          sourceId: invoiceId,
        );
        await stock.record(
          productId: p.id,
          type: StockMovementType.purchase,
          qty: line.qty,
          unitCost: line.unitCost,
          refType: RefType.purchaseInvoice,
          refId: invoiceId,
          createdBy: user.id,
          date: date,
        );
      }

      if (input.paidAmount > 0) {
        if (input.paymentMethod != PaymentMethod.cash && input.paymentMethod != PaymentMethod.bank) {
          throw ArgumentError.value(input.paymentMethod, 'paymentMethod');
        }
        await db.into(db.payments).insert(PaymentsCompanion.insert(
              number: await numbering.next('payment'),
              date: date,
              direction: PaymentDirection.outbound,
              partyType: PartyType.supplier,
              partyId: input.supplierId,
              amount: input.paidAmount,
              method: input.paymentMethod,
              invoiceRefType: const Value(RefType.purchaseInvoice),
              invoiceRefId: Value(invoiceId),
              createdBy: Value(user.id),
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
      if (!user.isAdmin) throw ValidationException('إلغاء الفواتير للمدير فقط');
      if (reason.trim().isEmpty) throw ValidationException('سبب الإلغاء مطلوب');
      final invoice = await (db.select(db.purchaseInvoices)..where((t) => t.id.equals(invoiceId)))
          .getSingle();
      if (invoice.status == DocStatus.cancelled) {
        throw ValidationException('الفاتورة ${invoice.number} ملغاة من قبل');
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
        // Empty the layers this purchase made; anything it made before
        // layers existed comes off the oldest layers instead.
        final emptied = voided[p.id] ?? 0;
        final rest = item.qty - (emptied < item.qty ? emptied : item.qty);
        voided[p.id] = emptied - (item.qty - rest);
        if (rest > 0) {
          await fifo.consume(
            productId: p.id,
            qty: rest,
            refType: 'purchase_cancel',
            refId: invoiceId,
            fallbackCost: item.unitCost,
          );
        }
        await stock.record(
          productId: p.id,
          type: StockMovementType.purchaseCancel,
          qty: -item.qty,
          unitCost: item.unitCost,
          refType: RefType.purchaseInvoice,
          refId: invoiceId,
          note: note,
          createdBy: user.id,
        );
      }

      await (db.update(db.purchaseInvoices)..where((t) => t.id.equals(invoiceId))).write(
        PurchaseInvoicesCompanion(
          status: const Value(DocStatus.cancelled),
          notes: Value(invoice.notes == null ? note : '${invoice.notes}\n$note'),
          updatedAt: Value(DateTime.now()),
        ),
      );
      await (db.update(db.payments)
            ..where((t) =>
                t.invoiceRefType.equals(RefType.purchaseInvoice) &
                t.invoiceRefId.equals(invoiceId) &
                t.status.equals(DocStatus.active)))
          .write(PaymentsCompanion(status: const Value(DocStatus.cancelled), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(
        action: AuditAction.cancel,
        entity: 'purchase_invoice',
        entityId: invoiceId,
        userId: user.id,
        details: '${invoice.number}: ${reason.trim()}',
      );
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
                         AND ${BalanceService.countedPayment('p')}), 0) AS paid
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
          ),
      ],
      await BalanceService(db).paidOnInvoice(RefType.purchaseInvoice, invoiceId),
    );
  }

  static String? _blankToNull(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();
}
