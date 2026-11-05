import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../quantity.dart';
import 'approval_service.dart';
import 'audit_service.dart';
import 'discount_service.dart';
import 'errors.dart';
import 'numbering_service.dart';
import 'payment_service.dart';
import 'product_service.dart';
import 'sales_service.dart';

abstract final class SoStatus {
  static const quotation = 'quotation';
  static const draft = 'draft';
  static const confirmed = 'confirmed';
  static const partlyDelivered = 'partly_delivered';
  static const delivered = 'delivered';
  static const cancelled = 'cancelled';
}

abstract final class SaleChannel {
  static const showroom = 'showroom';
  static const shopify = 'shopify';
  static const whatsapp = 'whatsapp';
  static const phone = 'phone';
  static const project = 'project';
  static const all = [showroom, shopify, whatsapp, phone, project];

  static String label(String c) => switch (c) {
        showroom => 'المعرض',
        shopify => 'شوبيفاي',
        whatsapp => 'واتساب',
        phone => 'هاتف',
        project => 'مشروع',
        _ => c,
      };
}

class SoLineInput {
  const SoLineInput({required this.productId, required this.qty, this.extraDiscountBp = 0});

  final int productId;

  /// Thousandths of a unit.
  final int qty;

  /// Extra discount points typed on top of the customer's usual discount.
  final int extraDiscountBp;
}

class SoLineRow {
  const SoLineRow(this.line, this.productCode, this.productName);

  final SalesOrderLine line;
  final String productCode;
  final String productName;

  int get remaining => line.qty - line.qtyDelivered;
  int get orderedValue => lineAmount(line.qty, line.unitPrice);
  int get deliveredValue => lineAmount(line.qtyDelivered, line.unitPrice);
}

class SoDetail {
  const SoDetail(this.order, this.customerName, this.lines);

  final SalesOrder order;
  final String customerName;
  final List<SoLineRow> lines;

  int get orderedValue => lines.fold(0, (s, l) => s + l.orderedValue);
  int get deliveredValue => lines.fold(0, (s, l) => s + l.deliveredValue);
  int get remainingValue => orderedValue - deliveredValue;
}

/// Sales orders: draft, confirm (which freezes price and discount), then
/// deliver in one or more parts. Each delivery is an ordinary sales invoice.
class SalesOrderService {
  SalesOrderService(this.db);

  final AppDatabase db;

  /// The most extra discount (basis points) a cashier may give without a
  /// manager. Higher needs the admin to enter or confirm it.
  static const cashierMaxExtraBp = 500;

  Future<SalesOrder> _order(int id) async {
    final o = await (db.select(db.salesOrders)..where((t) => t.id.equals(id))).getSingleOrNull();
    if (o == null) throw ValidationException('أمر البيع غير موجود');
    return o;
  }

  void _checkExtra(int bp, User user) {
    if (bp < 0 || bp > 10000) throw ValidationException('نسبة الخصم يجب أن تكون بين 0 و 100');
    if (!user.isAdmin && bp > cashierMaxExtraBp) {
      throw ValidationException('الخصم الإضافي أكبر من المسموح للكاشير — يلزم موافقة المدير');
    }
  }

  Future<int> createDraft({
    required int customerId,
    required List<SoLineInput> lines,
    String channel = SaleChannel.showroom,
    DateTime? orderDate,
    String? notes,
    String? externalId,
    bool asQuotation = false,
    String? approvalReason,
    required User user,
  }) {
    return db.transaction(() async {
      if (lines.isEmpty) throw ValidationException('أضف صنفاً واحداً على الأقل');
      if (!SaleChannel.all.contains(channel)) throw ArgumentError.value(channel, 'channel');
      final customer = await (db.select(db.customers)..where((t) => t.id.equals(customerId))).getSingleOrNull();
      if (customer == null) throw ValidationException('اختر العميل');
      if (!customer.isActive) throw ValidationException('العميل "${customer.name}" موقوف');
      final ext = (externalId ?? '').trim();
      if (ext.isNotEmpty) {
        final dup = await (db.select(db.salesOrders)
              ..where((t) => t.channel.equals(channel) & t.externalId.equals(ext)))
            .get();
        if (dup.isNotEmpty) throw ValidationException('هذا الطلب مسجل من قبل (${dup.first.number})');
      }
      final units = {for (final u in await db.select(db.units).get()) u.id: u};
      for (final l in lines) {
        final p = await (db.select(db.products)..where((t) => t.id.equals(l.productId))).getSingleOrNull();
        if (p == null) throw ValidationException('الصنف غير موجود');
        if (l.qty <= 0) throw ValidationException('الكمية يجب أن تكون أكبر من صفر (${p.nameAr})');
        if (!(units[p.unitId]?.allowDecimal ?? false) && !isWholeQty(l.qty)) {
          throw ValidationException('الكمية يجب أن تكون رقماً صحيحاً (${p.nameAr})');
        }
        _checkExtra(l.extraDiscountBp, user);
      }
      final id = await db.into(db.salesOrders).insert(SalesOrdersCompanion.insert(
            number: await NumberingService(db).next('sales_order'),
            customerId: customerId,
            channel: Value(channel),
            status: Value(asQuotation ? SoStatus.quotation : SoStatus.draft),
            orderDate: orderDate ?? DateTime.now(),
            notes: Value((notes ?? '').trim().isEmpty ? null : notes!.trim()),
            externalId: Value(ext.isEmpty ? null : ext),
            createdBy: Value(user.id),
          ));
      for (final l in lines) {
        await db.into(db.salesOrderLines).insert(SalesOrderLinesCompanion.insert(
            orderId: id,
            productId: l.productId,
            qty: l.qty,
            extraDiscountBp: Value(l.extraDiscountBp)));
      }
      await AuditService(db).log(action: AuditAction.create, entity: 'sales_order', entityId: id, userId: user.id);
      if (lines.any((l) => l.extraDiscountBp > cashierMaxExtraBp)) {
        // Only an admin gets this far (the check above); keep the reason.
        await ApprovalService(db).record(
          kind: ApprovalKind.extraDiscount,
          docType: 'sales_order',
          docId: id,
          reason: (approvalReason ?? '').trim().isEmpty ? 'خصم إضافي من المدير' : approvalReason!,
          requestedBy: user.id,
          approvedBy: user.id,
        );
      }
      return id;
    });
  }

  /// Confirms a draft and freezes each line's price: the product's price for
  /// the customer's price level, less the customer's usual discount and the
  /// line's extra points. Later price changes never alter it.
  Future<void> confirm(int id, {required User user}) {
    return db.transaction(() async {
      final order = await _order(id);
      if (order.status != SoStatus.draft && order.status != SoStatus.quotation) {
        throw ValidationException('يمكن تأكيد المسودة أو عرض السعر فقط');
      }
      final customer = await (db.select(db.customers)..where((t) => t.id.equals(order.customerId))).getSingle();
      final lines = await (db.select(db.salesOrderLines)..where((t) => t.orderId.equals(id))).get();
      for (final l in lines) {
        _checkExtra(l.extraDiscountBp, user);
        final p = await (db.select(db.products)..where((t) => t.id.equals(l.productId))).getSingle();
        final list = p.priceFor(customer.priceLevel);
        final base = customer.discountBp;
        final sum = base + l.extraDiscountBp;
        final total = sum > 10000 ? 10000 : sum;
        await (db.update(db.salesOrderLines)..where((t) => t.id.equals(l.id))).write(SalesOrderLinesCompanion(
            listPrice: Value(list), baseDiscountBp: Value(base), unitPrice: Value(applyDiscount(list, total))));
      }
      final now = DateTime.now();
      await (db.update(db.salesOrders)..where((t) => t.id.equals(id))).write(SalesOrdersCompanion(
          status: const Value(SoStatus.confirmed),
          confirmedBy: Value(user.id),
          confirmedAt: Value(now),
          updatedAt: Value(now)));
      await AuditService(db).log(action: AuditAction.update, entity: 'sales_order', entityId: id, userId: user.id);
    });
  }

  /// Delivers goods ([qtyByLine]: line id -> thousandths) at the frozen
  /// prices. Creates an ordinary sales invoice, so stock, FIFO cost and the
  /// customer's balance follow the existing rules.
  Future<SalesInvoice> deliver(
    int id, {
    required Map<int, int> qtyByLine,
    int paidAmount = 0,
    String paymentMethod = PaymentMethod.cash,
    bool allowOverCreditLimit = false,
    String? belowCostReason,
    required User user,
  }) {
    return db.transaction(() async {
      final order = await _order(id);
      if (order.status != SoStatus.confirmed && order.status != SoStatus.partlyDelivered) {
        throw ValidationException('أمر البيع غير جاهز للتسليم');
      }
      final lines = await (db.select(db.salesOrderLines)..where((t) => t.orderId.equals(id))).get();
      final byId = {for (final l in lines) l.id: l};
      final inputs = <SaleLineInput>[];
      for (final e in qtyByLine.entries) {
        if (e.value == 0) continue;
        final l = byId[e.key];
        if (l == null) throw ValidationException('سطر غير موجود في أمر البيع');
        if (e.value < 0) throw ValidationException('الكمية لا يمكن أن تكون سالبة');
        if (e.value > l.qty - l.qtyDelivered) {
          throw ValidationException('الكمية المسلّمة أكبر من المتبقي في الأمر');
        }
        inputs.add(SaleLineInput(productId: l.productId, qty: e.value, unitPrice: l.unitPrice));
      }
      if (inputs.isEmpty) throw ValidationException('أدخل كمية مسلّمة لصنف واحد على الأقل');

      // A price under cost needs the manager and a reason, which is logged.
      var belowCost = false;
      for (final i in inputs) {
        final p = await (db.select(db.products)..where((t) => t.id.equals(i.productId))).getSingle();
        if (i.unitPrice < p.costPrice) belowCost = true;
      }
      if (belowCost) {
        if (!user.isAdmin) throw ValidationException('السعر أقل من التكلفة — يلزم موافقة المدير');
        if ((belowCostReason ?? '').trim().isEmpty) {
          throw ValidationException('السعر أقل من التكلفة — اكتب سبب البيع');
        }
      }

      final invoice = await SalesService(db).post(
        SaleInput(
          customerId: order.customerId,
          lines: inputs,
          paidAmount: paidAmount,
          paymentMethod: paymentMethod,
          notes: 'أمر بيع ${order.number}',
        ),
        userId: user.id,
        allowOverCreditLimit: allowOverCreditLimit,
        belowCostReason: belowCostReason,
      );
      for (final e in qtyByLine.entries.where((e) => e.value > 0)) {
        final l = byId[e.key]!;
        await (db.update(db.salesOrderLines)..where((t) => t.id.equals(l.id)))
            .write(SalesOrderLinesCompanion(qtyDelivered: Value(l.qtyDelivered + e.value)));
      }
      final after = await (db.select(db.salesOrderLines)..where((t) => t.orderId.equals(id))).get();
      final allDone = after.every((l) => l.qtyDelivered >= l.qty);
      await (db.update(db.salesOrders)..where((t) => t.id.equals(id))).write(SalesOrdersCompanion(
          status: Value(allDone ? SoStatus.delivered : SoStatus.partlyDelivered),
          updatedAt: Value(DateTime.now())));
      // Advances taken on this order now count on the invoice.
      await PaymentService(db).applyAdvances(
        orderRefType: RefType.salesOrder,
        orderId: id,
        invoiceRefType: RefType.salesInvoice,
        invoiceId: invoice.id,
        invoiceTotal: invoice.total,
      );
      await db.into(db.salesOrderDeliveries).insert(SalesOrderDeliveriesCompanion.insert(
          orderId: id, invoiceId: invoice.id, deliveredAt: DateTime.now()));
      return invoice;
    });
  }

  /// A draft or a confirmed order with nothing delivered can be cancelled.
  Future<void> cancel(int id, {required User user}) {
    return db.transaction(() async {
      final order = await _order(id);
      if (order.status != SoStatus.draft &&
          order.status != SoStatus.quotation &&
          order.status != SoStatus.confirmed) {
        throw ValidationException('لا يمكن إلغاء أمر تم تسليم جزء منه');
      }
      await (db.update(db.salesOrders)..where((t) => t.id.equals(id))).write(
          SalesOrdersCompanion(status: const Value(SoStatus.cancelled), updatedAt: Value(DateTime.now())));
      await AuditService(db).log(action: AuditAction.cancel, entity: 'sales_order', entityId: id, userId: user.id);
    });
  }

  Future<SoDetail> detail(int id) async {
    final order = await _order(id);
    final customer = await (db.select(db.customers)..where((t) => t.id.equals(order.customerId))).getSingle();
    final rows = await (db.select(db.salesOrderLines).join([
      innerJoin(db.products, db.products.id.equalsExp(db.salesOrderLines.productId)),
    ])
          ..where(db.salesOrderLines.orderId.equals(id))
          ..orderBy([OrderingTerm.asc(db.salesOrderLines.id)]))
        .get();
    return SoDetail(order, customer.name, [
      for (final r in rows)
        SoLineRow(r.readTable(db.salesOrderLines), r.readTable(db.products).code,
            r.readTable(db.products).nameAr),
    ]);
  }

  Stream<List<SoDetail>> watchAll() {
    return db.select(db.salesOrders).watch().asyncMap((orders) async {
      orders.sort((a, b) => b.id.compareTo(a.id));
      return [for (final o in orders) await detail(o.id)];
    });
  }
}
