import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../money.dart';
import '../pricing_math.dart';
import '../quantity.dart';
import 'approval_service.dart';
import 'audit_service.dart';
import 'balance_service.dart';
import 'doc_types.dart';
import 'errors.dart';
import 'fifo_service.dart';
import 'numbering_service.dart';
import 'query_helpers.dart';
import 'reservation_service.dart';
import 'selling_policy_service.dart';
import 'settings_service.dart';
import 'stock_service.dart';

export 'doc_types.dart';

class SaleLineInput {
  const SaleLineInput({
    required this.productId,
    required this.qty,
    required this.unitPrice,
    this.discount = 0,
    this.priceListId,
    this.locked,
    this.locationId,
  });

  final int productId;

  /// Thousandths of a unit.
  final int qty;

  /// Piastres per whole unit.
  final int unitPrice;

  /// Piastres off this line.
  final int discount;

  /// The price list version this line is priced from. Null is a manual price,
  /// which needs a manager.
  final int? priceListId;

  /// From an approved order: the frozen price, whatever versions came later.
  final PricingSnapshot? locked;

  /// The place it is sold from. Null takes it from the sellable places in
  /// order, the main warehouse first. A display-only place cannot be chosen.
  final int? locationId;

  /// qty x price, rounded once, minus the line discount.
  int get total => lineAmount(qty, unitPrice) - discount;
}

class SaleInput {
  const SaleInput({
    required this.lines,
    this.customerId,
    this.date,
    this.discount = 0,
    this.paidAmount = 0,
    this.paymentMethod = PaymentMethod.cash,
    this.notes,
  });

  final List<SaleLineInput> lines;

  /// Null for a cash sale to an unnamed customer.
  final int? customerId;
  final DateTime? date;

  /// Piastres off the whole invoice.
  final int discount;
  final int paidAmount;
  final String paymentMethod;
  final String? notes;

  int get subtotal => lines.fold(0, (sum, l) => sum + l.total);
  int get total => subtotal - discount;
}

/// One stock problem per product when a sale would take stock below zero.
class StockShortage {
  const StockShortage(this.productName, this.available, this.needed);
  final String productName;
  final int available;
  final int needed;
}

class InsufficientStockException extends ValidationException {
  InsufficientStockException(this.shortages)
      : super('الكمية غير متاحة في المخزن:\n${shortages.map((s) => '• ${s.productName}: '
            'المتاح ${formatQty(s.available)} والمطلوب ${formatQty(s.needed)}').join('\n')}');

  final List<StockShortage> shortages;
}

/// The sale would take the customer past their credit limit. Only an admin
/// can post it anyway (with `allowOverCreditLimit`).
class CreditLimitException extends ValidationException {
  CreditLimitException({required this.limit, required this.balanceAfter})
      : super('هذه الفاتورة تتجاوز حد الائتمان للعميل.\n'
            'حد الائتمان ${formatMoney(limit)} والرصيد بعد الفاتورة ${formatMoney(balanceAfter)}');

  final int limit;
  final int balanceAfter;
}

/// Stock exists but part of it is held for other customers.
class ReservedStockException extends ValidationException {
  ReservedStockException(this.shortages)
      : super('الكمية المتاحة محجوزة لعملاء آخرين:\n${shortages.map((s) => '• ${s.productName}: '
            'المتاح للبيع ${formatQty(s.available)} والمطلوب ${formatQty(s.needed)}').join('\n')}');

  final List<StockShortage> shortages;
}

/// A line is priced under its real cost. A cashier cannot post it; an admin
/// can, after writing why ([needsReason] is true for the admin).
class BelowCostException extends ValidationException {
  BelowCostException({required this.needsReason, required this.productNames})
      : super(needsReason
            ? 'السعر أقل من التكلفة — اكتب سبب البيع\n${productNames.map((n) => '• $n').join('\n')}'
            : 'السعر أقل من التكلفة — يلزم موافقة المدير\n${productNames.map((n) => '• $n').join('\n')}');

  /// True when the person is an admin and only the reason is missing.
  final bool needsReason;
  final List<String> productNames;
}

/// A line needs a manager: a price that is not the approved list price, a
/// discount past the limit, or a margin under the minimum. An admin posting
/// the sale is the approval, and it is logged.
class ApprovalRequiredException extends ValidationException {
  ApprovalRequiredException(this.problems)
      : super('يلزم موافقة المدير:\n${problems.map((p) => '• $p').join('\n')}');

  final List<String> problems;
}

class SalesInvoiceRow {
  const SalesInvoiceRow(this.invoice, this.customerName, this.paid);
  final SalesInvoice invoice;

  /// Null for a cash sale.
  final String? customerName;

  /// Everything paid against it so far (counted payments).
  final int paid;
}

class SalesInvoiceLine {
  const SalesInvoiceLine(this.item, this.productCode, this.productName, this.unitName);
  final SalesInvoiceItem item;
  final String productCode;
  final String productName;
  final String? unitName;
}

class SalesInvoiceDetail {
  const SalesInvoiceDetail({
    required this.invoice,
    required this.customer,
    required this.lines,
    required this.paid,
    this.customerBalance,
    this.createdByName,
  });

  final SalesInvoice invoice;
  final Customer? customer;
  final List<SalesInvoiceLine> lines;

  /// Everything paid against it so far (counted payments).
  final int paid;

  /// The customer's whole balance today (all documents), if any customer.
  final int? customerBalance;
  final String? createdByName;
}

/// Posting and cancelling sales invoices. Each runs in one transaction:
/// if any step fails, nothing is saved and no number is used up.
class SalesService {
  SalesService(this.db);

  final AppDatabase db;

  /// [allowOverCreditLimit] is honoured only for an admin [userId].
  Future<SalesInvoice> post(
    SaleInput input, {
    int? userId,
    bool allowOverCreditLimit = false,
    String? belowCostReason,
    String? approvalReason,
  }) {
    return db.transaction(() async {
      // 1. Validate the lines.
      if (input.lines.isEmpty) throw ValidationException('أضف صنفاً واحداً على الأقل');
      final products = <int, Product>{};
      final units = {for (final u in await db.select(db.units).get()) u.id: u};
      for (final line in input.lines) {
        final p = products[line.productId] ??= await (db.select(db.products)
              ..where((t) => t.id.equals(line.productId)))
            .getSingle();
        if (!p.isActive) throw ValidationException('الصنف "${p.nameAr}" موقوف');
        if (line.qty <= 0) throw ValidationException('الكمية يجب أن تكون أكبر من صفر (${p.nameAr})');
        if (!(units[p.unitId]?.allowDecimal ?? false) && !isWholeQty(line.qty)) {
          throw ValidationException('الكمية يجب أن تكون رقماً صحيحاً (${p.nameAr})');
        }
        if (line.unitPrice < 0) throw ValidationException('السعر لا يمكن أن يكون سالباً (${p.nameAr})');
        if (line.discount < 0 || line.discount > lineAmount(line.qty, line.unitPrice)) {
          throw ValidationException('خصم الصنف "${p.nameAr}" أكبر من قيمته');
        }
      }

      // 2. Totals and payment.
      final subtotal = input.subtotal;
      if (input.discount < 0 || input.discount > subtotal) {
        throw ValidationException('خصم الفاتورة أكبر من قيمتها');
      }
      final total = input.total;
      if (input.paidAmount < 0) throw ValidationException('المبلغ المدفوع لا يمكن أن يكون سالباً');
      if (input.paidAmount > total) {
        throw ValidationException('المبلغ المدفوع أكبر من إجمالي الفاتورة');
      }
      Customer? customer;
      String? creditOverride;
      if (input.customerId == null) {
        if (input.paidAmount != total) {
          throw ValidationException('البيع النقدي بدون عميل يجب أن يُدفع بالكامل؛ اختر عميلاً للبيع الآجل');
        }
      } else {
        customer = await (db.select(db.customers)..where((t) => t.id.equals(input.customerId!)))
            .getSingle();
        if (!customer.isActive) throw ValidationException('العميل "${customer.name}" موقوف');
        if (customer.creditLimit > 0) {
          final balanceAfter =
              await BalanceService(db).customerBalance(customer.id) + total - input.paidAmount;
          if (balanceAfter > customer.creditLimit) {
            final user = userId == null
                ? null
                : await (db.select(db.users)..where((t) => t.id.equals(userId))).getSingleOrNull();
            if (!allowOverCreditLimit || !(user?.isAdmin ?? false)) {
              throw CreditLimitException(limit: customer.creditLimit, balanceAfter: balanceAfter);
            }
            creditOverride = 'تجاوز حد الائتمان: الحد ${formatMoney(customer.creditLimit)} '
                'والرصيد بعد الفاتورة ${formatMoney(balanceAfter)}';
          }
        }
      }
      if (input.paidAmount > 0 &&
          input.paymentMethod != PaymentMethod.cash &&
          input.paymentMethod != PaymentMethod.bank) {
        // Cheques are received from the payments screen, where their details are entered.
        throw ArgumentError.value(input.paymentMethod, 'paymentMethod');
      }

      // 3. Stock, per product (the same product may be on several lines).
      final stock = StockService(db);
      if (!await SettingsService(db).getBool(SettingKey.allowNegativeStock)) {
        final needed = <int, int>{};
        for (final line in input.lines) {
          needed[line.productId] = (needed[line.productId] ?? 0) + line.qty;
        }
        final shortages = <StockShortage>[];
        for (final entry in needed.entries) {
          final available = await stock.sellableStock(entry.key);
          if (available < entry.value) {
            shortages.add(StockShortage(products[entry.key]!.nameAr, available, entry.value));
          }
        }
        if (shortages.isNotEmpty) throw InsufficientStockException(shortages);
      }

      // 3a. A place chosen on the line must be able to sell, and hold enough.
      final sellable = await stock.sellableLocationIds();
      final allowNegative = await SettingsService(db).getBool(SettingKey.allowNegativeStock);
      final fromPlace = <(int, int), int>{};
      for (final line in input.lines) {
        if (line.locationId == null) continue;
        if (!sellable.contains(line.locationId)) {
          throw ValidationException('المكان المختار للصنف "${products[line.productId]!.nameAr}" للعرض فقط أو موقوف');
        }
        final key = (line.productId, line.locationId!);
        fromPlace[key] = (fromPlace[key] ?? 0) + line.qty;
      }
      if (!allowNegative) {
        final shortages = <StockShortage>[];
        for (final e in fromPlace.entries) {
          final here = await stock.currentStock(e.key.$1, locationId: e.key.$2);
          if (here < e.value) shortages.add(StockShortage(products[e.key.$1]!.nameAr, here, e.value));
        }
        if (shortages.isNotEmpty) throw InsufficientStockException(shortages);
      }

      // 3b. Stock held for other customers cannot be sold from under them.
      final reservations = ReservationService(db);
      final soldQty = <int, int>{};
      for (final line in input.lines) {
        soldQty[line.productId] = (soldQty[line.productId] ?? 0) + line.qty;
      }
      final held = <StockShortage>[];
      for (final entry in soldQty.entries) {
        final others = await reservations.reservedByOthers(entry.key, input.customerId);
        if (others <= 0) continue;
        final onHand = await stock.sellableStock(entry.key);
        if (onHand - others < entry.value) {
          held.add(StockShortage(products[entry.key]!.nameAr, onHand - others < 0 ? 0 : onHand - others, entry.value));
        }
      }
      if (held.isNotEmpty) throw ReservedStockException(held);

      // 4. Number, invoice and items, keeping the version each line used.
      final numbering = NumberingService(db);
      final date = input.date ?? DateTime.now();
      final invoiceId = await db.into(db.salesInvoices).insert(SalesInvoicesCompanion.insert(
            number: await numbering.next('sales'),
            date: date,
            customerId: Value(input.customerId),
            subtotal: subtotal,
            discount: Value(input.discount),
            total: total,
            paidAmount: Value(input.paidAmount),
            notes: Value(_blankToNull(input.notes)),
            createdBy: Value(userId),
          ));
      final fifo = FifoService(db);
      final policies = SellingPolicyService(db);
      final belowCostNames = <String>[];
      final manualNames = <String>[], overLimitNames = <String>[], lowMarginNames = <String>[];
      // The invoice discount is split over the lines, exactly, for profit and tax.
      final shares = allocateProportionally(input.discount, [for (final l in input.lines) l.total]);
      for (var n = 0; n < input.lines.length; n++) {
        final line = input.lines[n];
        final net = line.total - shares[n];
        final name = products[line.productId]!.nameAr;
        final check = await policies.check(
          product: products[line.productId]!,
          qty: line.qty,
          unitPrice: line.unitPrice,
          lineTotal: line.total,
          netTotal: net,
          priceListId: line.priceListId,
          locked: line.locked,
          customer: customer,
          date: date,
        );
        if (check.manualPrice) manualNames.add(name);
        if (check.overDiscountLimit) overLimitNames.add(name);
        // Real cost: the oldest layers first. Anything without a layer
        // (negative stock) is priced at the last known cost.
        final parts = await fifo.consumeAcross(
          productId: line.productId,
          qty: line.qty,
          locationIds: line.locationId == null ? sellable : [line.locationId!],
          refType: RefType.salesInvoice,
          refId: invoiceId,
          date: date,
          fallbackCost: await fifo.lastKnownCost(line.productId) ?? 0,
        );
        final costValue = parts.fold<int>(0, (s, p) => s + p.take.totalCost);
        final cost = (costValue * qtyScale / line.qty).round();
        final snap = check.snapshot;
        final vat = vatOf(net, snap.vatStatus, snap.vatRateBp);
        // Profit is measured without VAT once the VAT is verified.
        final netForProfit = vat?.netOfVat ?? net;
        if (netForProfit < costValue) belowCostNames.add(name);
        final margin = marginBp(netForProfit, costValue);
        if (check.minMarginBp != null && margin != null && margin < check.minMarginBp!) {
          lowMarginNames.add(name);
        }
        await db.into(db.salesInvoiceItems).insert(SalesInvoiceItemsCompanion.insert(
              invoiceId: invoiceId,
              productId: line.productId,
              qty: line.qty,
              unitPrice: line.unitPrice,
              unitCost: Value(cost),
              costTotal: Value(costValue),
              discount: Value(line.discount),
              lineTotal: line.total,
              priceListId: Value(snap.priceListId),
              listPrice: Value(snap.listPrice),
              pricingType: Value(snap.pricingType),
              sellingPolicyId: Value(snap.sellingPolicyId),
              policyDiscountBp: Value(snap.policyBp),
              customerDiscountBp: Value(snap.customerBp),
              extraDiscountBp: Value(snap.extraBp),
              invoiceDiscountShare: Value(shares[n]),
              netTotal: Value(net),
              vatStatus: Value(snap.vatStatus),
              vatRateBp: Value(snap.vatRateBp),
              vatAmount: Value(vat?.vat),
            ));
        // 5. One stock movement for each place the line took from.
        for (final part in parts) {
          await stock.record(
            productId: line.productId,
            type: StockMovementType.sale,
            qty: -part.take.qty,
            unitCost: part.take.averageUnitCost,
            refType: RefType.salesInvoice,
            refId: invoiceId,
            createdBy: userId,
            date: date,
            locationId: part.locationId,
          );
        }
      }

      // 5b. Under cost: admin only, with a reason that is logged.
      // (No user = a system caller, which is not checked.)
      var belowCostApproved = false;
      if (belowCostNames.isNotEmpty && userId != null) {
        final user = await (db.select(db.users)..where((t) => t.id.equals(userId))).getSingleOrNull();
        final isAdmin = user?.isAdmin ?? false;
        if (!isAdmin || (belowCostReason ?? '').trim().isEmpty) {
          throw BelowCostException(needsReason: isAdmin, productNames: belowCostNames);
        }
        belowCostApproved = true;
      }

      // 5a. Manual price, discount past the limit, margin under the minimum:
      // a cashier cannot post these; an admin posting them is the approval.
      final problems = <String>[
        for (final n in manualNames) 'سعر غير معتمد من قائمة أسعار: $n',
        for (final n in overLimitNames) 'خصم أكبر من الحد المسموح: $n',
        for (final n in lowMarginNames) 'هامش أقل من الحد الأدنى: $n',
      ];
      final loggedApprovals = <(String, String)>[];
      if (problems.isNotEmpty && userId != null) {
        final user = await (db.select(db.users)..where((t) => t.id.equals(userId))).getSingleOrNull();
        if (!(user?.isAdmin ?? false)) throw ApprovalRequiredException(problems);
        final why = (approvalReason ?? '').trim().isEmpty ? 'موافقة المدير عند الحفظ' : approvalReason!.trim();
        if (manualNames.isNotEmpty) {
          loggedApprovals.add((ApprovalKind.priceOverride, '$why: ${manualNames.join('، ')}'));
        }
        if (overLimitNames.isNotEmpty) {
          loggedApprovals.add((ApprovalKind.extraDiscount, '$why: ${overLimitNames.join('، ')}'));
        }
        if (lowMarginNames.isNotEmpty) {
          loggedApprovals.add((ApprovalKind.lowMargin, '$why: ${lowMarginNames.join('، ')}'));
        }
      }

      // 5c. The customer's own reservations are used up by what they buy.
      if (input.customerId != null) {
        for (final entry in soldQty.entries) {
          await reservations.consumeForCustomer(input.customerId!, entry.key, entry.value, userId: userId);
        }
      }

      // 6. The payment made at the counter.
      if (input.paidAmount > 0) {
        await db.into(db.payments).insert(PaymentsCompanion.insert(
              number: await numbering.next('payment'),
              date: date,
              direction: PaymentDirection.inbound,
              partyType: PartyType.customer,
              partyId: input.customerId ?? walkInCustomerId,
              amount: input.paidAmount,
              method: input.paymentMethod,
              invoiceRefType: const Value(RefType.salesInvoice),
              invoiceRefId: Value(invoiceId),
              createdBy: Value(userId),
            ));
      }

      // 7. Audit.
      final invoice = await (db.select(db.salesInvoices)..where((t) => t.id.equals(invoiceId)))
          .getSingle();
      if (belowCostApproved) {
        await ApprovalService(db).record(
          kind: ApprovalKind.belowCost,
          docType: 'sales_invoice',
          docId: invoiceId,
          reason: belowCostReason!,
          requestedBy: userId,
          approvedBy: userId,
        );
      }
      if (creditOverride != null) {
        final why = (approvalReason ?? '').trim();
        loggedApprovals.add((ApprovalKind.creditLimit, why.isEmpty ? creditOverride : '$why — $creditOverride'));
      }
      for (final (kind, reason) in loggedApprovals) {
        await ApprovalService(db).record(
          kind: kind,
          docType: 'sales_invoice',
          docId: invoiceId,
          reason: reason,
          requestedBy: userId,
          approvedBy: userId,
        );
      }
      await AuditService(db).log(
        action: AuditAction.create,
        entity: 'sales_invoice',
        entityId: invoiceId,
        userId: userId,
        details: '${invoice.number} ${customer?.name ?? 'نقدي'} ${formatMoney(total)}',
      );
      return invoice;
    });
  }

  /// Admin only. Marks the invoice cancelled, puts the stock back and
  /// cancels the payment taken with it. Nothing is deleted.
  Future<void> cancel(int invoiceId, {required String reason, required User user}) {
    return db.transaction(() async {
      if (!user.isAdmin) throw ValidationException('إلغاء الفواتير للمدير فقط');
      if (reason.trim().isEmpty) throw ValidationException('سبب الإلغاء مطلوب');
      final invoice = await (db.select(db.salesInvoices)..where((t) => t.id.equals(invoiceId)))
          .getSingle();
      if (invoice.status == DocStatus.cancelled) {
        throw ValidationException('الفاتورة ${invoice.number} ملغاة من قبل');
      }
      final returns = await (db.select(db.returns)
            ..where((t) =>
                t.kind.equals(ReturnKind.sale) &
                t.originalInvoiceId.equals(invoiceId) &
                t.status.equals(DocStatus.active)))
          .get();
      if (returns.isNotEmpty) {
        throw ValidationException('لا يمكن إلغاء فاتورة عليها مرتجع؛ ألغِ المرتجع أولاً');
      }

      final note = 'سبب الإلغاء: ${reason.trim()}';
      await (db.update(db.salesInvoices)..where((t) => t.id.equals(invoiceId))).write(
        SalesInvoicesCompanion(
          status: const Value(DocStatus.cancelled),
          notes: Value(invoice.notes == null ? note : '${invoice.notes}\n$note'),
          updatedAt: Value(DateTime.now()),
        ),
      );

      final stock = StockService(db);
      final fifo = FifoService(db);
      final items = await (db.select(db.salesInvoiceItems)
            ..where((t) => t.invoiceId.equals(invoiceId)))
          .get();
      // Put back into the layers what the sale took.
      final restored = await fifo.reverseAll(RefType.salesInvoice, invoiceId);
      final leftBack = <int, int>{};
      for (final item in items) {
        leftBack[item.productId] = (leftBack[item.productId] ?? 0) + item.qty;
      }
      for (final e in leftBack.entries) {
        final missing = e.value - (restored[e.key] ?? 0);
        if (missing > 0) {
          // Sold before layers existed, or with no layer: restore at the sale's cost.
          final item = items.firstWhere((i) => i.productId == e.key);
          final where = await (db.select(db.stockMovements)
                ..where((m) =>
                    m.productId.equals(e.key) &
                    m.refType.equals(RefType.salesInvoice) &
                    m.refId.equals(invoiceId))
                ..limit(1))
              .getSingleOrNull();
          await fifo.addLayer(
            locationId: where?.locationId ?? mainLocationId,
            productId: e.key,
            qty: missing,
            unitCost: item.unitCost,
            sourceType: 'sale_cancel',
            sourceId: invoiceId,
          );
        }
      }
      // Each place gets back exactly what it gave.
      final sold = await (db.select(db.stockMovements)
            ..where((m) =>
                m.refType.equals(RefType.salesInvoice) &
                m.refId.equals(invoiceId) &
                m.type.equals(StockMovementType.sale)))
          .get();
      for (final m in sold) {
        await stock.record(
          productId: m.productId,
          type: StockMovementType.saleCancel,
          qty: -m.qty,
          unitCost: m.unitCost,
          refType: RefType.salesInvoice,
          refId: invoiceId,
          note: note,
          createdBy: user.id,
          locationId: m.locationId,
        );
      }

      await (db.update(db.payments)
            ..where((t) =>
                t.invoiceRefType.equals(RefType.salesInvoice) &
                t.invoiceRefId.equals(invoiceId) &
                t.status.equals(DocStatus.active)))
          .write(PaymentsCompanion(
        status: const Value(DocStatus.cancelled),
        updatedAt: Value(DateTime.now()),
      ));

      await AuditService(db).log(
        action: AuditAction.cancel,
        entity: 'sales_invoice',
        entityId: invoiceId,
        userId: user.id,
        details: '${invoice.number}: ${reason.trim()}',
      );
    });
  }

  /// Newest first, optionally limited to a date range (inclusive days).
  /// Newest first, optionally limited to a date range (inclusive days).
  /// Updates when invoices or payments change.
  Stream<List<SalesInvoiceRow>> watchList({DateTime? from, DateTime? to}) async* {
    final pending = await SettingsService(db).getBool(SettingKey.countPendingCheques);
    yield* db.customSelect(
      '''
      SELECT s.*, c.name AS customer_name,
             COALESCE((SELECT SUM(p.amount) FROM payments p
                       WHERE p.invoice_ref_type = '${RefType.salesInvoice}' AND p.invoice_ref_id = s.id
                         AND ${BalanceService.countedPayment('p')}), 0) AS paid
      FROM sales_invoices s
      LEFT JOIN customers c ON c.id = s.customer_id
      WHERE (? IS NULL OR s.date >= ?) AND (? IS NULL OR s.date < ?)
      ORDER BY s.id DESC
      ''',
      variables: [
        Variable.withBool(pending),
        ...dateRangeVariables(from, to),
      ],
      readsFrom: {db.salesInvoices, db.customers, db.payments, db.cheques},
    ).watch().map((rows) => [
          for (final r in rows)
            SalesInvoiceRow(
              db.salesInvoices.map(r.data),
              r.readNullable<String>('customer_name'),
              r.read<int>('paid'),
            ),
        ]);
  }

  Future<SalesInvoiceDetail> detail(int invoiceId) async {
    final invoice = await (db.select(db.salesInvoices)..where((t) => t.id.equals(invoiceId)))
        .getSingle();
    final customer = invoice.customerId == null
        ? null
        : await (db.select(db.customers)..where((t) => t.id.equals(invoice.customerId!)))
            .getSingle();
    final rows = await (db.select(db.salesInvoiceItems).join([
      innerJoin(db.products, db.products.id.equalsExp(db.salesInvoiceItems.productId)),
      leftOuterJoin(db.units, db.units.id.equalsExp(db.products.unitId)),
    ])
          ..where(db.salesInvoiceItems.invoiceId.equals(invoiceId))
          ..orderBy([OrderingTerm(expression: db.salesInvoiceItems.id)]))
        .get();
    final createdBy = invoice.createdBy == null
        ? null
        : await (db.select(db.users)..where((t) => t.id.equals(invoice.createdBy!)))
            .getSingleOrNull();
    final balances = BalanceService(db);
    return SalesInvoiceDetail(
      invoice: invoice,
      customer: customer,
      paid: await balances.paidOnInvoice(RefType.salesInvoice, invoiceId),
      customerBalance: customer == null ? null : await balances.customerBalance(customer.id),
      createdByName: createdBy?.fullName,
      lines: [
        for (final r in rows)
          SalesInvoiceLine(
            r.readTable(db.salesInvoiceItems),
            r.readTable(db.products).code,
            r.readTable(db.products).nameAr,
            r.readTableOrNull(db.units)?.nameAr,
          ),
      ],
    );
  }

  static String? _blankToNull(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();
}
