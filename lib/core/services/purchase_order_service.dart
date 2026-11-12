import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../quantity.dart';
import 'audit_service.dart';
import 'buying_policy_service.dart';
import 'doc_types.dart';
import 'errors.dart';
import 'numbering_service.dart';
import 'payment_service.dart';
import 'purchase_service.dart';
import 'stock_service.dart';

abstract final class PoStatus {
  static const draft = 'draft';
  static const approved = 'approved';
  static const partlyReceived = 'partly_received';
  static const received = 'received';
  static const cancelled = 'cancelled';
}

class PoLineInput {
  const PoLineInput({required this.productId, required this.qty});

  final int productId;

  /// Thousandths of a unit.
  final int qty;
}

class PoLineRow {
  const PoLineRow(this.line, this.productCode, this.productName);

  final PurchaseOrderLine line;
  final String productCode;
  final String productName;

  int get remaining => line.qty - line.qtyReceived;
  int get orderedValue => lineAmount(line.qty, line.unitCost);
  int get receivedValue => lineAmount(line.qtyReceived, line.unitCost);
}

class PoDetail {
  const PoDetail(this.order, this.supplierName, this.lines);

  final PurchaseOrder order;
  final String supplierName;
  final List<PoLineRow> lines;

  int get orderedValue => lines.fold(0, (s, l) => s + l.orderedValue);
  int get receivedValue => lines.fold(0, (s, l) => s + l.receivedValue);
  int get remainingValue => orderedValue - receivedValue;
}

/// Purchase orders: draft, approve (which freezes price and discount),
/// then receive in one or more parts. Admin only.
class PurchaseOrderService {
  PurchaseOrderService(this.db);

  final AppDatabase db;

  void _admin(User user) {
    if (!user.isAdmin) throw ValidationException('أوامر الشراء للمدير فقط');
  }

  Future<PurchaseOrder> _order(int id) async {
    final o = await (db.select(db.purchaseOrders)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (o == null) throw ValidationException('أمر الشراء غير موجود');
    return o;
  }

  Future<int> createDraft({
    required int supplierId,
    required List<PoLineInput> lines,
    DateTime? orderDate,
    DateTime? expectedDate,
    String? notes,
    required User user,
  }) {
    return db.transaction(() async {
      _admin(user);
      if (lines.isEmpty) throw ValidationException('أضف صنفاً واحداً على الأقل');
      final supplier = await (db.select(db.suppliers)..where((t) => t.id.equals(supplierId))).getSingleOrNull();
      if (supplier == null) throw ValidationException('اختر المورد');
      if (!supplier.isActive) throw ValidationException('المورد "${supplier.name}" موقوف');
      final units = {for (final u in await db.select(db.units).get()) u.id: u};
      for (final l in lines) {
        final p = await (db.select(db.products)..where((t) => t.id.equals(l.productId))).getSingleOrNull();
        if (p == null) throw ValidationException('الصنف غير موجود');
        if (l.qty <= 0) throw ValidationException('الكمية يجب أن تكون أكبر من صفر (${p.nameAr})');
        if (!(units[p.unitId]?.allowDecimal ?? false) && !isWholeQty(l.qty)) {
          throw ValidationException('الكمية يجب أن تكون رقماً صحيحاً (${p.nameAr})');
        }
      }
      final id = await db.into(db.purchaseOrders).insert(PurchaseOrdersCompanion.insert(
            number: await NumberingService(db).next('purchase_order'),
            supplierId: supplierId,
            orderDate: orderDate ?? DateTime.now(),
            expectedDate: Value(expectedDate),
            notes: Value((notes ?? '').trim().isEmpty ? null : notes!.trim()),
            createdBy: Value(user.id),
          ));
      for (final l in lines) {
        await db.into(db.purchaseOrderLines).insert(
            PurchaseOrderLinesCompanion.insert(orderId: id, productId: l.productId, qty: l.qty));
      }
      await AuditService(db).log(action: AuditAction.create, entity: 'purchase_order', entityId: id, userId: user.id);
      return id;
    });
  }

  /// Approves a draft and freezes each line's cost: the version in force
  /// today less this supplier's recorded buying policy, or [manualCosts]
  /// (line id -> piastres) where given. A line with neither cannot be approved:
  /// no percentage is assumed. Later versions never change it.
  Future<void> approve(int id, {Map<int, int> manualCosts = const {}, required User user}) {
    return db.transaction(() async {
      _admin(user);
      final order = await _order(id);
      if (order.status != PoStatus.draft) throw ValidationException('يمكن اعتماد المسودة فقط');
      final now = DateTime.now();
      final policies = BuyingPolicyService(db);
      final lines = await (db.select(db.purchaseOrderLines)..where((t) => t.orderId.equals(id))).get();
      for (final l in lines) {
        final manual = manualCosts[l.id];
        if (manual != null && manual < 0) throw ValidationException('التكلفة لا يمكن أن تكون سالبة');
        if (manual != null) {
          await (db.update(db.purchaseOrderLines)..where((t) => t.id.equals(l.id))).write(
              PurchaseOrderLinesCompanion(unitCost: Value(manual)));
          continue;
        }
        final p = await (db.select(db.products)..where((t) => t.id.equals(l.productId))).getSingle();
        final quotes = await policies.quotes(l.productId, supplierId: order.supplierId, asOf: now);
        if (quotes.isEmpty) {
          throw ValidationException('لا يوجد سعر قائمة ساري للصنف "${p.nameAr}"؛ أدخل التكلفة يدوياً');
        }
        final backed = quotes.where((q) => !q.missingPolicy).toList();
        if (backed.isEmpty) {
          throw ValidationException('لا توجد سياسة شراء مسجلة لهذا المورد على الصنف "${p.nameAr}"؛ '
              'سجل السياسة أو أدخل التكلفة يدوياً (لا يُفترض خصم)');
        }
        if (backed.length > 1) {
          throw ValidationException('الصنف "${p.nameAr}" له أكثر من قائمة سارية بسياسة شراء؛ أدخل التكلفة يدوياً');
        }
        final q = backed.single;
        await (db.update(db.purchaseOrderLines)..where((t) => t.id.equals(l.id))).write(
            PurchaseOrderLinesCompanion(
                priceListId: Value(q.quote.priceListId),
                listPrice: Value(q.listPrice),
                buyingPolicyId: Value(q.policy!.id),
                discountBp: Value(q.baseBp),
                extraDiscountBp: Value(q.extraBp),
                unitCost: Value(q.netCost!)));
      }
      await (db.update(db.purchaseOrders)..where((t) => t.id.equals(id))).write(PurchaseOrdersCompanion(
          status: const Value(PoStatus.approved),
          approvedBy: Value(user.id),
          approvedAt: Value(now),
          updatedAt: Value(now)));
      await AuditService(db).log(action: AuditAction.update, entity: 'purchase_order', entityId: id, userId: user.id);
    });
  }

  /// Receives goods ([qtyByLine]: line id -> thousandths) at the frozen
  /// prices. Creates an ordinary purchase invoice, so stock, cost layers and
  /// the supplier's balance follow the existing rules.
  Future<PurchaseInvoice> receive(
    int id, {
    required Map<int, int> qtyByLine,
    DateTime? date,
    String? supplierInvoiceNo,
    int paidAmount = 0,
    String paymentMethod = PaymentMethod.cash,
    ChequeInput? cheque,
    int locationId = mainLocationId,
    int discount = 0,
    int extraCosts = 0,
    bool extraCostsOnSupplier = true,
    String? extraCostsNote,
    DateTime? dueDate,
    String? notes,
    bool allowDuplicateSupplierNo = false,
    // Products on the same supplier invoice that were not on the order.
    List<PurchaseLineInput> extraLines = const [],
    required User user,
  }) {
    return db.transaction(() async {
      _admin(user);
      final order = await _order(id);
      if (order.status != PoStatus.approved && order.status != PoStatus.partlyReceived) {
        throw ValidationException('أمر الشراء غير جاهز للاستلام');
      }
      final lines = await (db.select(db.purchaseOrderLines)..where((t) => t.orderId.equals(id))).get();
      final byId = {for (final l in lines) l.id: l};
      final inputs = <PurchaseLineInput>[];
      for (final e in qtyByLine.entries) {
        if (e.value == 0) continue;
        final l = byId[e.key];
        if (l == null) throw ValidationException('سطر غير موجود في أمر الشراء');
        if (e.value < 0) throw ValidationException('الكمية لا يمكن أن تكون سالبة');
        if (e.value > l.qty - l.qtyReceived) {
          throw ValidationException('الكمية المستلمة أكبر من المتبقي في الأمر');
        }
        inputs.add(PurchaseLineInput(
          productId: l.productId,
          qty: e.value,
          unitCost: l.unitCost,
          priceListId: l.priceListId,
          listPrice: l.listPrice,
          buyingPolicyId: l.buyingPolicyId,
          baseDiscountBp: l.discountBp,
          extraDiscountBp: l.extraDiscountBp,
        ));
      }
      if (inputs.isEmpty) throw ValidationException('أدخل كمية مستلمة لصنف واحد على الأقل');

      final invoice = await PurchaseService(db).post(
        PurchaseInput(
          supplierId: order.supplierId,
          lines: [...inputs, ...extraLines],
          supplierInvoiceNo: supplierInvoiceNo,
          date: date,
          paidAmount: paidAmount,
          paymentMethod: paymentMethod,
          cheque: cheque,
          discount: discount,
          extraCosts: extraCosts,
          extraCostsOnSupplier: extraCostsOnSupplier,
          extraCostsNote: extraCostsNote,
          dueDate: dueDate,
          allowDuplicateSupplierNo: allowDuplicateSupplierNo,
          notes: (notes ?? '').trim().isEmpty ? 'أمر شراء ${order.number}' : 'أمر شراء ${order.number}\n${notes!.trim()}',
          locationId: locationId,
        ),
        user: user,
      );
      for (final e in qtyByLine.entries.where((e) => e.value > 0)) {
        final l = byId[e.key]!;
        await (db.update(db.purchaseOrderLines)..where((t) => t.id.equals(l.id)))
            .write(PurchaseOrderLinesCompanion(qtyReceived: Value(l.qtyReceived + e.value)));
      }
      final after = await (db.select(db.purchaseOrderLines)..where((t) => t.orderId.equals(id))).get();
      final allDone = after.every((l) => l.qtyReceived >= l.qty);
      await (db.update(db.purchaseOrders)..where((t) => t.id.equals(id))).write(PurchaseOrdersCompanion(
          status: Value(allDone ? PoStatus.received : PoStatus.partlyReceived),
          updatedAt: Value(DateTime.now())));
      // Advances paid on this order now count on the invoice.
      await PaymentService(db).applyAdvances(
        orderRefType: RefType.purchaseOrder,
        orderId: id,
        invoiceRefType: RefType.purchaseInvoice,
        invoiceId: invoice.id,
        invoiceTotal: invoice.total,
      );
      await db.into(db.purchaseOrderReceipts).insert(PurchaseOrderReceiptsCompanion.insert(
          orderId: id, invoiceId: invoice.id, receivedAt: date ?? DateTime.now()));
      return invoice;
    });
  }

  /// A draft or an approved order with nothing received can be cancelled.
  Future<void> cancel(int id, {required User user}) {
    return db.transaction(() async {
      _admin(user);
      final order = await _order(id);
      if (order.status != PoStatus.draft && order.status != PoStatus.approved) {
        throw ValidationException('لا يمكن إلغاء أمر تم استلام جزء منه');
      }
      await (db.update(db.purchaseOrders)..where((t) => t.id.equals(id))).write(
          PurchaseOrdersCompanion(status: const Value(PoStatus.cancelled), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(action: AuditAction.cancel, entity: 'purchase_order', entityId: id, userId: user.id);
    });
  }

  Future<PoDetail> detail(int id) async {
    final order = await _order(id);
    final supplier = await (db.select(db.suppliers)..where((t) => t.id.equals(order.supplierId))).getSingle();
    final rows = await (db.select(db.purchaseOrderLines).join([
      innerJoin(db.products, db.products.id.equalsExp(db.purchaseOrderLines.productId)),
    ])
          ..where(db.purchaseOrderLines.orderId.equals(id))
          ..orderBy([OrderingTerm.asc(db.purchaseOrderLines.id)]))
        .get();
    return PoDetail(order, supplier.name, [
      for (final r in rows)
        PoLineRow(r.readTable(db.purchaseOrderLines), r.readTable(db.products).code,
            r.readTable(db.products).nameAr),
    ]);
  }

  /// Approved orders still waiting for goods, for [supplierId] if given.
  Future<List<PoDetail>> openOrders({int? supplierId}) async {
    final orders = await (db.select(db.purchaseOrders)
          ..where((o) =>
              o.status.isIn([PoStatus.approved, PoStatus.partlyReceived]) &
              (supplierId == null ? const Constant(true) : o.supplierId.equals(supplierId)))
          ..orderBy([(o) => OrderingTerm.desc(o.id)]))
        .get();
    return [for (final o in orders) await detail(o.id)];
  }

  Stream<List<PoDetail>> watchAll() {
    return db.select(db.purchaseOrders).watch().asyncMap((orders) async {
      orders.sort((a, b) => b.id.compareTo(a.id));
      return [for (final o in orders) await detail(o.id)];
    });
  }
}
