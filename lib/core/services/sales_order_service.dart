import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../pricing_math.dart';
import '../quantity.dart';
import 'approval_service.dart';
import 'audit_service.dart';
import 'errors.dart';
import 'numbering_service.dart';
import 'payment_service.dart';
import 'price_list_service.dart';
import 'sales_service.dart';
import 'selling_policy_service.dart';

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
  const SoLineInput({required this.productId, required this.qty, this.extraDiscountBp = 0, this.priceListId});

  final int productId;

  /// Thousandths of a unit.
  final int qty;

  /// Extra discount points typed on top of the policy and the customer's discount.
  final int extraDiscountBp;

  /// The version chosen when more than one can price the product.
  final int? priceListId;
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
            extraDiscountBp: Value(l.extraDiscountBp),
            priceListId: Value(l.priceListId)));
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

  /// What each line would be if the order were approved today, for the
  /// display before approval. One row per line; a line with no approved price
  /// has no quote.
  Future<List<(SalesOrderLine, SellQuote?)>> quotesForApproval(int id) async {
    final order = await _order(id);
    final customer = await (db.select(db.customers)..where((t) => t.id.equals(order.customerId))).getSingle();
    final lines = await (db.select(db.salesOrderLines)..where((t) => t.orderId.equals(id))).get();
    final now = DateTime.now();
    return [for (final l in lines) (l, await _quote(l, customer, now))];
  }

  Future<SellQuote?> _quote(SalesOrderLine l, Customer customer, DateTime now) async {
    final policies = SellingPolicyService(db);
    if (l.priceListId != null) {
      return policies.quoteIn(l.priceListId!, l.productId, customer: customer, asOf: now, extraBp: l.extraDiscountBp);
    }
    final quotes = await policies.quotes(l.productId, customer: customer, asOf: now, extraBp: l.extraDiscountBp);
    if (quotes.length > 1) {
      final p = await (db.select(db.products)..where((t) => t.id.equals(l.productId))).getSingle();
      throw ValidationException('الصنف "${p.nameAr}" له أكثر من قائمة سارية؛ حدد القائمة في السطر');
    }
    return quotes.firstOrNull;
  }

  /// Approves a draft or quotation and freezes each line: the version in force
  /// today, its list price, each discount and the VAT status. The order keeps
  /// them whatever versions come later (the price lock). A line with no
  /// approved price needs [manualPrices] (line id -> piastres), admin only.
  Future<void> confirm(
    int id, {
    Map<int, int> manualPrices = const {},
    String? approvalReason,
    required User user,
  }) {
    return db.transaction(() async {
      final order = await _order(id);
      if (order.status != SoStatus.draft && order.status != SoStatus.quotation) {
        throw ValidationException('يمكن تأكيد المسودة أو عرض السعر فقط');
      }
      final customer = await (db.select(db.customers)..where((t) => t.id.equals(order.customerId))).getSingle();
      final lines = await (db.select(db.salesOrderLines)..where((t) => t.orderId.equals(id))).get();
      final now = DateTime.now();
      final exceptions = <String>[];
      final alreadyLogged = (await ApprovalService(db).forDocument('sales_order', id))
          .any((a) => a.kind == ApprovalKind.extraDiscount);
      for (final l in lines) {
        final p = await (db.select(db.products)..where((t) => t.id.equals(l.productId))).getSingle();
        final manual = manualPrices[l.id];
        if (manual != null) {
          if (!user.isAdmin) throw ValidationException('السعر اليدوي يلزمه موافقة المدير (${p.nameAr})');
          if (manual < 0) throw ValidationException('السعر لا يمكن أن يكون سالباً (${p.nameAr})');
          exceptions.add('سعر يدوي: ${p.nameAr}');
          await (db.update(db.salesOrderLines)..where((t) => t.id.equals(l.id))).write(SalesOrderLinesCompanion(
              listPrice: Value(manual),
              unitPrice: Value(applyDiscount(manual, l.extraDiscountBp > 10000 ? 10000 : l.extraDiscountBp)),
              pricingType: Value(PricingType.ofLevel(customer.priceLevel)),
              vatStatus: Value(p.vatBasis),
              vatRateBp: Value(p.vatRateBp)));
          continue;
        }
        final q = await _quote(l, customer, now);
        if (q == null) {
          throw ValidationException('لا يوجد سعر معتمد للصنف "${p.nameAr}"؛ أضفه لقائمة أسعار أو أدخل سعراً يدوياً بموافقة المدير');
        }
        if (!PriceListService.inForce(q.quote.priceList, now)) {
          throw ValidationException('القائمة المختارة للصنف "${p.nameAr}" غير سارية اليوم');
        }
        final max = q.policy?.maxDiscountBp;
        final over = max != null ? q.totalBp > max : l.extraDiscountBp > cashierMaxExtraBp;
        if (l.extraDiscountBp < 0 || l.extraDiscountBp > 10000) {
          throw ValidationException('نسبة الخصم يجب أن تكون بين 0 و 100');
        }
        if (over) {
          if (!user.isAdmin) {
            throw ValidationException('الخصم أكبر من المسموح للصنف "${p.nameAr}" — يلزم موافقة المدير');
          }
          if (!alreadyLogged) exceptions.add('خصم أكبر من الحد: ${p.nameAr}');
        }
        await (db.update(db.salesOrderLines)..where((t) => t.id.equals(l.id))).write(SalesOrderLinesCompanion(
            priceListId: Value(q.quote.priceListId),
            listPrice: Value(q.listPrice),
            pricingType: Value(q.pricingType),
            sellingPolicyId: Value(q.policy?.id),
            policyDiscountBp: Value(q.policyBp),
            customerDiscountBp: Value(q.customerBp),
            vatStatus: Value(q.quote.priceList.vatStatus),
            vatRateBp: Value(q.quote.priceList.vatRateBp ?? p.vatRateBp),
            unitPrice: Value(q.unitPrice)));
      }
      if (exceptions.isNotEmpty) {
        final why = (approvalReason ?? '').trim().isEmpty ? 'موافقة المدير عند التأكيد' : approvalReason!.trim();
        await ApprovalService(db).record(
          kind: manualPrices.isNotEmpty ? ApprovalKind.priceOverride : ApprovalKind.extraDiscount,
          docType: 'sales_order',
          docId: id,
          reason: '$why: ${exceptions.join('، ')}',
          requestedBy: user.id,
          approvedBy: user.id,
        );
      }
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
        inputs.add(SaleLineInput(
          productId: l.productId,
          qty: e.value,
          unitPrice: l.unitPrice,
          locked: PricingSnapshot(
            priceListId: l.priceListId,
            listPrice: l.priceListId == null ? null : l.listPrice,
            pricingType: l.pricingType,
            sellingPolicyId: l.sellingPolicyId,
            policyBp: l.policyDiscountBp,
            customerBp: l.customerDiscountBp,
            extraBp: l.extraDiscountBp,
            vatStatus: l.vatStatus,
            vatRateBp: l.vatRateBp,
          ),
        ));
      }
      if (inputs.isEmpty) throw ValidationException('أدخل كمية مسلّمة لصنف واحد على الأقل');

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
