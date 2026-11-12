import 'package:drift/drift.dart';

import '../db/database.dart';
import 'balance_service.dart';
import 'buying_policy_service.dart';
import 'doc_types.dart';
import 'price_list_service.dart';
import 'product_service.dart';
import 'purchase_order_service.dart';
import 'reservation_service.dart';
import 'sales_order_service.dart';
import 'selling_policy_service.dart';
import 'settings_service.dart';
import 'stock_price_service.dart';
import 'supplier_advance_service.dart';

/// One invoice in a party's history.
class InvoiceSummary {
  const InvoiceSummary({
    required this.id,
    required this.number,
    required this.date,
    required this.total,
    required this.paid,
    required this.status,
    this.dueDate,
    this.extra,
  });

  final int id;
  final String number;
  final DateTime date;
  final int total;
  final int paid;
  final String status;
  final DateTime? dueDate;

  /// The supplier's own number for a purchase.
  final String? extra;

  bool get cancelled => status == DocStatus.cancelled;
  int get remaining => cancelled ? 0 : total - paid;
}

/// One payment, with its cheque when it was paid by cheque.
class PaymentSummary {
  const PaymentSummary(this.payment, this.cheque);

  final Payment payment;
  final Cheque? cheque;
}

/// A product bought from or sold to a party, all time.
class ProductTotal {
  const ProductTotal(this.productId, this.name, this.qty, this.value);

  final int productId;
  final String name;
  final int qty;
  final int value;
}

class PartyProfile {
  const PartyProfile({
    required this.balance,
    required this.invoices,
    required this.payments,
    required this.returns,
    required this.topProducts,
  });

  final int balance;
  final List<InvoiceSummary> invoices;
  final List<PaymentSummary> payments;
  final List<ReturnDoc> returns;
  final List<ProductTotal> topProducts;

  Iterable<InvoiceSummary> get active => invoices.where((i) => !i.cancelled);
  int get invoicedTotal => active.fold(0, (s, i) => s + i.total);
  int get paidTotal => payments.where((p) => p.payment.status == DocStatus.active).fold(0, (s, p) => s + p.payment.amount);
  List<InvoiceSummary> get open => active.where((i) => i.remaining > 0).toList();
  DateTime? get lastInvoice => active.isEmpty ? null : active.first.date;
}

class SupplierProfile extends PartyProfile {
  const SupplierProfile({
    required this.supplier,
    required super.balance,
    required super.invoices,
    required super.payments,
    required super.returns,
    required super.topProducts,
    required this.orders,
    required this.advances,
    required this.policies,
  });

  final Supplier supplier;
  final List<PoDetail> orders;
  final List<AdvanceRow> advances;
  final List<BuyingPolicyRow> policies;

  int get overdue => open
      .where((i) => i.dueDate != null && i.dueDate!.isBefore(DateTime.now()))
      .fold(0, (s, i) => s + i.remaining);
}

class CustomerProfile extends PartyProfile {
  const CustomerProfile({
    required this.customer,
    required this.categoryName,
    required super.balance,
    required super.invoices,
    required super.payments,
    required super.returns,
    required super.topProducts,
    required this.orders,
    required this.reservations,
  });

  final Customer customer;
  final String categoryName;
  final List<SoDetail> orders;
  final List<ReservationRow> reservations;
}

/// One receipt or sale line of a product.
class ProductMove {
  const ProductMove({
    required this.invoiceId,
    required this.number,
    required this.date,
    required this.party,
    required this.qty,
    required this.unitPrice,
    this.listPrice,
  });

  final int invoiceId;
  final String number;
  final DateTime date;
  final String party;
  final int qty;
  final int unitPrice;
  final int? listPrice;
}

class ProductProfile {
  const ProductProfile({
    required this.row,
    required this.places,
    required this.byPrice,
    required this.quotes,
    required this.purchases,
    required this.sales,
    required this.reservations,
    required this.reserved,
  });

  final ProductRow row;

  /// Stock by place: (name, qty).
  final List<(String, int)> places;
  final StockPriceSummary? byPrice;

  /// List prices in force today.
  final List<PriceQuote> quotes;
  final List<ProductMove> purchases;
  final List<ProductMove> sales;
  final List<ReservationRow> reservations;
  final int reserved;

  int get soldQty => sales.fold(0, (s, m) => s + m.qty);
  int get boughtQty => purchases.fold(0, (s, m) => s + m.qty);
}

/// Everything about one supplier, customer or product on one page.
class ProfileService {
  ProfileService(this.db);

  final AppDatabase db;

  Future<bool> _pending() => SettingsService(db).getBool(SettingKey.countPendingCheques);

  Future<List<PaymentSummary>> _payments(String partyType, int partyId) async {
    final rows = await (db.select(db.payments).join([
      leftOuterJoin(db.cheques, db.cheques.paymentId.equalsExp(db.payments.id)),
    ])
          ..where(db.payments.partyType.equals(partyType) & db.payments.partyId.equals(partyId))
          ..orderBy([OrderingTerm.desc(db.payments.date), OrderingTerm.desc(db.payments.id)]))
        .get();
    return [for (final r in rows) PaymentSummary(r.readTable(db.payments), r.readTableOrNull(db.cheques))];
  }

  Future<List<ReturnDoc>> _returns(String kind, int partyId) => (db.select(db.returns)
        ..where((t) => t.kind.equals(kind) & t.partyId.equals(partyId))
        ..orderBy([(t) => OrderingTerm.desc(t.date), (t) => OrderingTerm.desc(t.id)]))
      .get();

  Future<SupplierProfile> supplier(int id) async {
    final supplier = await (db.select(db.suppliers)..where((t) => t.id.equals(id))).getSingle();
    final pending = await _pending();
    final inv = await db.customSelect(
      '''
      SELECT pi.*, COALESCE((SELECT SUM(p.amount) FROM payments p
               WHERE p.invoice_ref_type = '${RefType.purchaseInvoice}' AND p.invoice_ref_id = pi.id
                 AND ${BalanceService.countedPayment('p')}), 0) + pi.advance_used AS paid
      FROM purchase_invoices pi WHERE pi.supplier_id = ?
      ORDER BY pi.date DESC, pi.id DESC
      ''',
      variables: [Variable.withBool(pending), Variable.withInt(id)],
    ).get();
    final top = await db.customSelect(
      '''
      SELECT i.product_id, p.name_ar, SUM(i.qty) AS q, SUM(i.net_total) AS v
      FROM purchase_invoice_items i
      JOIN purchase_invoices pi ON pi.id = i.invoice_id
      JOIN products p ON p.id = i.product_id
      WHERE pi.supplier_id = ? AND pi.status = '${DocStatus.active}'
      GROUP BY i.product_id ORDER BY v DESC LIMIT 10
      ''',
      variables: [Variable.withInt(id)],
    ).get();
    final orders = await PurchaseOrderService(db).watchAll().first;
    return SupplierProfile(
      supplier: supplier,
      balance: await BalanceService(db).supplierBalance(id),
      invoices: [
        for (final r in inv)
          InvoiceSummary(
            id: r.read<int>('id'),
            number: r.read<String>('number'),
            date: db.purchaseInvoices.map(r.data).date,
            total: r.read<int>('total'),
            paid: r.read<int>('paid'),
            status: r.read<String>('status'),
            dueDate: db.purchaseInvoices.map(r.data).dueDate,
            extra: r.readNullable<String>('supplier_invoice_no'),
          ),
      ],
      payments: await _payments(PartyType.supplier, id),
      returns: await _returns(ReturnKind.purchase, id),
      topProducts: [
        for (final r in top)
          ProductTotal(r.read<int>('product_id'), r.read<String>('name_ar'), r.read<int>('q'), r.read<int>('v')),
      ],
      orders: orders.where((o) => o.order.supplierId == id).toList(),
      advances: await SupplierAdvanceService(db).rows(supplierId: id),
      policies: (await BuyingPolicyService(db).rows()).where((p) => p.policy.supplierId == id).toList(),
    );
  }

  Future<CustomerProfile> customer(int id) async {
    final customer = await (db.select(db.customers)..where((t) => t.id.equals(id))).getSingle();
    final pending = await _pending();
    final inv = await db.customSelect(
      '''
      SELECT s.*, COALESCE((SELECT SUM(p.amount) FROM payments p
               WHERE p.invoice_ref_type = '${RefType.salesInvoice}' AND p.invoice_ref_id = s.id
                 AND ${BalanceService.countedPayment('p')}), 0) AS paid
      FROM sales_invoices s WHERE s.customer_id = ?
      ORDER BY s.date DESC, s.id DESC
      ''',
      variables: [Variable.withBool(pending), Variable.withInt(id)],
    ).get();
    final top = await db.customSelect(
      '''
      SELECT i.product_id, p.name_ar, SUM(i.qty) AS q, SUM(i.net_total) AS v
      FROM sales_invoice_items i
      JOIN sales_invoices s ON s.id = i.invoice_id
      JOIN products p ON p.id = i.product_id
      WHERE s.customer_id = ? AND s.status = '${DocStatus.active}'
      GROUP BY i.product_id ORDER BY v DESC LIMIT 10
      ''',
      variables: [Variable.withInt(id)],
    ).get();
    final category = await SellingPolicyService(db).categoryOf(customer);
    final orders = await SalesOrderService(db).watchAll().first;
    final reservations = await ReservationService(db).watchActive().first;
    return CustomerProfile(
      customer: customer,
      categoryName: category?.name ?? '',
      balance: await BalanceService(db).customerBalance(id),
      invoices: [
        for (final r in inv)
          InvoiceSummary(
            id: r.read<int>('id'),
            number: r.read<String>('number'),
            date: db.salesInvoices.map(r.data).date,
            total: r.read<int>('total'),
            paid: r.read<int>('paid'),
            status: r.read<String>('status'),
          ),
      ],
      payments: await _payments(PartyType.customer, id),
      returns: await _returns(ReturnKind.sale, id),
      topProducts: [
        for (final r in top)
          ProductTotal(r.read<int>('product_id'), r.read<String>('name_ar'), r.read<int>('q'), r.read<int>('v')),
      ],
      orders: orders.where((o) => o.order.customerId == id).toList(),
      reservations: reservations.where((r) => r.reservation.customerId == id).toList(),
    );
  }

  Future<ProductProfile> product(int id) async {
    final row = await ProductService(db).row(id);
    final places = await db.customSelect(
      '''
      SELECT l.name, SUM(m.qty) AS q FROM stock_movements m
      JOIN locations l ON l.id = m.location_id
      WHERE m.product_id = ? GROUP BY m.location_id HAVING SUM(m.qty) <> 0 ORDER BY l.id
      ''',
      variables: [Variable.withInt(id)],
    ).get();
    final bought = await db.customSelect(
      '''
      SELECT pi.id, pi.number, pi.date, su.name AS party, i.qty, i.unit_cost AS price, i.list_price
      FROM purchase_invoice_items i
      JOIN purchase_invoices pi ON pi.id = i.invoice_id
      JOIN suppliers su ON su.id = pi.supplier_id
      WHERE i.product_id = ? AND pi.status = '${DocStatus.active}'
      ORDER BY pi.date DESC, pi.id DESC LIMIT 200
      ''',
      variables: [Variable.withInt(id)],
    ).get();
    final sold = await db.customSelect(
      '''
      SELECT s.id, s.number, s.date, COALESCE(c.name, 'بيع نقدي') AS party, i.qty, i.unit_price AS price, i.list_price
      FROM sales_invoice_items i
      JOIN sales_invoices s ON s.id = i.invoice_id
      LEFT JOIN customers c ON c.id = s.customer_id
      WHERE i.product_id = ? AND s.status = '${DocStatus.active}'
      ORDER BY s.date DESC, s.id DESC LIMIT 200
      ''',
      variables: [Variable.withInt(id)],
    ).get();
    ProductMove move(QueryRow r) => ProductMove(
          invoiceId: r.read<int>('id'),
          number: r.read<String>('number'),
          date: DateTime.fromMillisecondsSinceEpoch(r.read<int>('date') * 1000),
          party: r.read<String>('party'),
          qty: r.read<int>('qty'),
          unitPrice: r.read<int>('price'),
          listPrice: r.readNullable<int>('list_price'),
        );
    final reservations = ReservationService(db);
    return ProductProfile(
      row: row,
      places: [for (final r in places) (r.read<String>('name'), r.read<int>('q'))],
      byPrice: (await StockPriceService(db).watchSummaries().first)[id],
      quotes: await PriceListService(db).quotesFor(id),
      purchases: [for (final r in bought) move(r)],
      sales: [for (final r in sold) move(r)],
      reservations: (await reservations.watchActive().first).where((r) => r.reservation.productId == id).toList(),
      reserved: await reservations.reservedQty(id),
    );
  }
}
