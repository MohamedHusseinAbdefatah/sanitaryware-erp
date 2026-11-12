import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/reports/report_service.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/doc_types.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/expense_service.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/payment_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_order_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';

import '../support/fixture.dart';

/// 1.8.0: transport and other costs, a due date, payment by cheque, the
/// supplier's invoice number entered twice, and receiving an order from the
/// purchase invoice.
void main() {
  late Shop shop;
  late PurchaseService purchases;

  setUp(() async {
    shop = await Shop.open();
    purchases = PurchaseService(shop.db);
  });
  tearDown(() => shop.close());

  PurchaseInput input({
    int extra = 0,
    bool onSupplier = true,
    String? no,
    int paid = 0,
    String method = PaymentMethod.cash,
    ChequeInput? cheque,
    DateTime? due,
    bool allowDuplicate = false,
    int? supplierId,
  }) =>
      PurchaseInput(
        supplierId: supplierId ?? shop.supplierId,
        // 4 mixers at 300 and 10 pipes at 30: 1,200 + 300 = 1,500.
        lines: [
          PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(4), unitCost: 30000),
          PurchaseLineInput(productId: shop.pipe.id, qty: qtyOf(10), unitCost: 3000),
        ],
        extraCosts: extra,
        extraCostsOnSupplier: onSupplier,
        supplierInvoiceNo: no,
        paidAmount: paid,
        paymentMethod: method,
        cheque: cheque,
        dueDate: due,
        allowDuplicateSupplierNo: allowDuplicate,
      );

  group('transport and other costs', () {
    test('on the supplier\'s invoice: owed to the supplier and in the goods\' cost, split by value', () async {
      final inv = await purchases.post(input(extra: 15000), user: shop.admin); // 150 on 1,500 = 10%
      expect(inv.total, 165000);
      expect(inv.extraCosts, 15000);
      expect(await shop.supplierBalance(), 165000);
      final items = await (shop.db.select(shop.db.purchaseInvoiceItems)..where((t) => t.invoiceId.equals(inv.id))).get();
      expect(items.map((i) => i.extraCostShare), [12000, 3000]);
      expect(items.map((i) => i.netTotal), [120000, 30000], reason: 'what the supplier is owed per line');
      expect(await shop.costOf(shop.mixer), 33000, reason: '300 + 10%');
      expect(await shop.costOf(shop.pipe), 3300);
    });

    test('paid to someone else: not owed to the supplier, a purchase expense not taken twice off profit', () async {
      final inv = await purchases.post(input(extra: 15000, onSupplier: false), user: shop.admin);
      expect(inv.total, 150000);
      expect(await shop.supplierBalance(), 150000);
      expect(await shop.costOf(shop.mixer), 33000);
      final expense = (await shop.db.select(shop.db.expenses).get()).single;
      expect(expense.amount, 15000);
      expect(expense.purchaseInvoiceId, inv.id);
      expect(expense.description, contains(inv.number));
      // Net profit with no sales: the purchase expense is not subtracted.
      final profit = await ReportService(shop.db).profit();
      expect(profit.rows.last.last, 0);
      // It can only go with its invoice.
      await expectLater(ExpenseService(shop.db).cancel(expense.id, reason: 'خطأ', user: shop.admin),
          throwsA(isA<ValidationException>()));
      await purchases.cancel(inv.id, reason: 'خطأ', user: shop.admin);
      final after = (await shop.db.select(shop.db.expenses).get()).single;
      expect(after.status, DocStatus.cancelled);
    });

    test('the invoice discount comes off first, then the costs are split on what is left', () async {
      final inv = await purchases.post(
        PurchaseInput(
          supplierId: shop.supplierId,
          lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(2), unitCost: 50000)],
          discount: 10000,
          extraCosts: 4500,
        ),
        user: shop.admin,
      );
      expect(inv.total, 94500);
      expect(await shop.costOf(shop.mixer), 47250); // (1,000 - 100 + 45) / 2
    });
  });

  group('the supplier\'s invoice number', () {
    test('the same number for the same supplier stops unless confirmed', () async {
      final first = await purchases.post(input(no: 'A-77'), user: shop.admin);
      await expectLater(
        purchases.post(input(no: ' A-77 '), user: shop.admin),
        throwsA(isA<DuplicateSupplierInvoiceException>().having((e) => e.existing.id, 'existing', first.id)),
      );
      final second = await purchases.post(input(no: 'A-77', allowDuplicate: true), user: shop.admin);
      expect(second.supplierInvoiceNo, 'A-77');
    });

    test('another supplier, or a cancelled invoice, does not count', () async {
      final first = await purchases.post(input(no: 'B-1'), user: shop.admin);
      final other = await PartyService(shop.db).saveSupplier(const SupplierInput(name: 'مورد آخر'));
      await purchases.post(input(no: 'B-1', supplierId: other), user: shop.admin);
      await purchases.cancel(first.id, reason: 'خطأ', user: shop.admin);
      await purchases.post(input(no: 'B-1'), user: shop.admin);
    });
  });

  group('due date and paying by cheque', () {
    test('a credit purchase keeps its due date and shows when due; paid in full it has none', () async {
      final soon = DateTime.now().add(const Duration(days: 3));
      final credit = await purchases.post(input(paid: 50000, due: soon), user: shop.admin);
      expect(credit.dueDate, isNotNull);
      final paid = await purchases.post(input(paid: 150000, due: soon), user: shop.admin);
      expect(paid.dueDate, isNull);
      final later = await purchases.post(input(due: DateTime.now().add(const Duration(days: 40))), user: shop.admin);
      final dues = await purchases.watchDue().first;
      expect(dues.map((d) => d.invoice.id), [credit.id], reason: 'within a week only');
      expect(dues.single.remaining, 100000);
      expect(dues.single.overdue, isFalse);
      expect(later.dueDate, isNotNull);
      await expectLater(
        purchases.post(input(due: DateTime.now().subtract(const Duration(days: 2))), user: shop.admin),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a cheque from the invoice is a pending cheque; cancelling the invoice cancels it', () async {
      final inv = await purchases.post(
        input(
          paid: 150000,
          method: PaymentMethod.cheque,
          cheque: ChequeInput(number: '123456', bank: 'مصر', dueDate: DateTime.now().add(const Duration(days: 30))),
        ),
        user: shop.admin,
      );
      final payment = (await shop.db.select(shop.db.payments).get()).single;
      expect(payment.method, PaymentMethod.cheque);
      expect(payment.invoiceRefId, inv.id);
      final cheque = (await shop.db.select(shop.db.cheques).get()).single;
      expect(cheque.chequeNo, '123456');
      expect(cheque.status, ChequeStatus.pending);
      await purchases.cancel(inv.id, reason: 'خطأ', user: shop.admin);
      expect((await shop.db.select(shop.db.cheques).get()).single.status, ChequeStatus.cancelled);
    });

    test('a cheque needs its number', () async {
      await expectLater(
        purchases.post(input(paid: 1000, method: PaymentMethod.cheque), user: shop.admin),
        throwsA(isA<ValidationException>()),
      );
      expect(await shop.db.select(shop.db.purchaseInvoices).get(), isEmpty, reason: 'nothing half saved');
    });
  });

  test('an order received from the purchase invoice, with another product and transport', () async {
    final orders = PurchaseOrderService(shop.db);
    final id = await orders.createDraft(
      supplierId: shop.supplierId,
      lines: [PoLineInput(productId: shop.mixer.id, qty: qtyOf(5))],
      user: shop.admin,
    );
    await orders.approve(id, manualCosts: {
      (await orders.detail(id)).lines.single.line.id: 40000,
    }, user: shop.admin);
    final open = await orders.openOrders(supplierId: shop.supplierId);
    expect(open.single.order.id, id);
    final line = open.single.lines.single;
    final inv = await orders.receive(
      id,
      qtyByLine: {line.line.id: qtyOf(3)},
      extraLines: [PurchaseLineInput(productId: shop.pipe.id, qty: qtyOf(10), unitCost: 2000)],
      extraCosts: 1400,
      supplierInvoiceNo: 'S-9',
      user: shop.admin,
    );
    expect(inv.subtotal, 140000);
    expect(inv.total, 141400);
    final after = await orders.detail(id);
    expect(after.lines.single.remaining, qtyOf(2));
    expect(after.order.status, PoStatus.partlyReceived);
    expect(await shop.costOf(shop.mixer), 40400);
    expect(await shop.costOf(shop.pipe), 2020);
  });
}
