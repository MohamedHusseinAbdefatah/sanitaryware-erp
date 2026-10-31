import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../money.dart';
import '../quantity.dart';
import 'audit_service.dart';
import 'errors.dart';
import 'numbering_service.dart';
import 'settings_service.dart';
import 'stock_service.dart';

abstract final class DocStatus {
  static const active = 'active';
  static const cancelled = 'cancelled';
}

abstract final class PaymentMethod {
  static const cash = 'cash';
  static const bank = 'bank';
  static const cheque = 'cheque';
}

/// Values used to link payments and stock movements back to an invoice.
abstract final class RefType {
  static const salesInvoice = 'sales_invoice';
}

/// Party id on a payment for a cash sale with no named customer. It never
/// matches a real customer, so it never affects anyone's balance.
const walkInCustomerId = 0;

class SaleLineInput {
  const SaleLineInput({
    required this.productId,
    required this.qty,
    required this.unitPrice,
    this.discount = 0,
  });

  final int productId;

  /// Thousandths of a unit.
  final int qty;

  /// Piastres per whole unit.
  final int unitPrice;

  /// Piastres off this line.
  final int discount;

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

class SalesInvoiceRow {
  const SalesInvoiceRow(this.invoice, this.customerName);
  final SalesInvoice invoice;

  /// Null for a cash sale.
  final String? customerName;
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
    this.createdByName,
  });

  final SalesInvoice invoice;
  final Customer? customer;
  final List<SalesInvoiceLine> lines;
  final String? createdByName;
}

/// Posting and cancelling sales invoices. Each runs in one transaction:
/// if any step fails, nothing is saved and no number is used up.
class SalesService {
  SalesService(this.db);

  final AppDatabase db;

  Future<SalesInvoice> post(SaleInput input, {int? userId}) {
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
      if (input.customerId == null) {
        if (input.paidAmount != total) {
          throw ValidationException('البيع النقدي بدون عميل يجب أن يُدفع بالكامل؛ اختر عميلاً للبيع الآجل');
        }
      } else {
        customer = await (db.select(db.customers)..where((t) => t.id.equals(input.customerId!)))
            .getSingle();
        if (!customer.isActive) throw ValidationException('العميل "${customer.name}" موقوف');
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
          final available = await stock.currentStock(entry.key);
          if (available < entry.value) {
            shortages.add(StockShortage(products[entry.key]!.nameAr, available, entry.value));
          }
        }
        if (shortages.isNotEmpty) throw InsufficientStockException(shortages);
      }

      // 4. Number, invoice and items, copying price and current average cost.
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
      for (final line in input.lines) {
        final cost = products[line.productId]!.costPrice;
        await db.into(db.salesInvoiceItems).insert(SalesInvoiceItemsCompanion.insert(
              invoiceId: invoiceId,
              productId: line.productId,
              qty: line.qty,
              unitPrice: line.unitPrice,
              unitCost: Value(cost),
              discount: Value(line.discount),
              lineTotal: line.total,
            ));
        // 5. One stock movement per line.
        await stock.record(
          productId: line.productId,
          type: StockMovementType.sale,
          qty: -line.qty,
          unitCost: cost,
          refType: RefType.salesInvoice,
          refId: invoiceId,
          createdBy: userId,
          date: date,
        );
      }

      // 6. The payment made at the counter.
      if (input.paidAmount > 0) {
        await db.into(db.payments).insert(PaymentsCompanion.insert(
              number: await numbering.next('payment'),
              date: date,
              direction: 'in',
              partyType: 'customer',
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
                t.kind.equals('sale') &
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
      final items = await (db.select(db.salesInvoiceItems)
            ..where((t) => t.invoiceId.equals(invoiceId)))
          .get();
      for (final item in items) {
        await stock.record(
          productId: item.productId,
          type: StockMovementType.saleCancel,
          qty: item.qty,
          unitCost: item.unitCost,
          refType: RefType.salesInvoice,
          refId: invoiceId,
          note: note,
          createdBy: user.id,
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
  Stream<List<SalesInvoiceRow>> watchList({DateTime? from, DateTime? to}) {
    final query = db.select(db.salesInvoices).join([
      leftOuterJoin(db.customers, db.customers.id.equalsExp(db.salesInvoices.customerId)),
    ]);
    if (from != null) {
      query.where(db.salesInvoices.date.isBiggerOrEqualValue(DateTime(from.year, from.month, from.day)));
    }
    if (to != null) {
      query.where(db.salesInvoices.date.isSmallerThanValue(DateTime(to.year, to.month, to.day + 1)));
    }
    query.orderBy([OrderingTerm.desc(db.salesInvoices.id)]);
    return query.watch().map((rows) => [
          for (final r in rows)
            SalesInvoiceRow(r.readTable(db.salesInvoices), r.readTableOrNull(db.customers)?.name),
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
    return SalesInvoiceDetail(
      invoice: invoice,
      customer: customer,
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
