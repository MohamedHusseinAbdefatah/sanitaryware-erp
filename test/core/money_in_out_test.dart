import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/balance_service.dart';
import 'package:sanitaryware_erp/core/services/cost.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/payment_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/return_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/settings_service.dart';

import '../support/fixture.dart';

void main() {
  late Shop shop;
  late PurchaseService purchases;
  late SalesService sales;
  late PaymentService payments;
  late ReturnService returns;

  setUp(() async {
    shop = await Shop.open();
    purchases = PurchaseService(shop.db);
    sales = SalesService(shop.db);
    payments = PaymentService(shop.db);
    returns = ReturnService(shop.db);
  });

  tearDown(() => shop.close());

  Future<PurchaseInvoice> buyMixers(int count, int unitCost, {int paid = 0}) => purchases.post(
        PurchaseInput(
          supplierId: shop.supplierId,
          lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(count), unitCost: unitCost)],
          paidAmount: paid,
        ),
        user: shop.admin,
      );

  Future<SalesInvoice> sellMixers(int count, {int price = 50000, int paid = 0, int? customerId}) =>
      sales.post(
        SaleInput(
          customerId: customerId ?? shop.customerId,
          lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(count), unitPrice: price)],
          paidAmount: paid,
        ),
        userId: shop.cashier.id,
      );

  group('weighted average cost', () {
    test('the formula', () {
      // 10 at 400 + 10 at 500 = 450
      expect(averageCostAfterAdding(stock: 10000, cost: 40000, qty: 10000, unitCost: 50000), 45000);
      // No stock: the new cost replaces the old.
      expect(averageCostAfterAdding(stock: 0, cost: 40000, qty: 5000, unitCost: 50000), 50000);
      expect(averageCostAfterAdding(stock: -2000, cost: 40000, qty: 5000, unitCost: 50000), 50000);
      // Rounds to the nearest piastre: (3 x 100 + 1 x 101) / 4 = 100.25 -> 100
      expect(averageCostAfterAdding(stock: 3000, cost: 100, qty: 1000, unitCost: 101), 100);
      // Removing undoes adding.
      expect(averageCostAfterRemoving(stock: 20000, cost: 45000, qty: 10000, unitCost: 50000), 40000);
      expect(averageCostAfterRemoving(stock: 5000, cost: 45000, qty: 5000, unitCost: 50000), 45000);
    });
  });

  group('purchases', () {
    test('stock goes up and average cost follows two purchases', () async {
      await buyMixers(10, 40000);
      expect(await shop.stockOf(shop.mixer), qtyOf(10));
      expect(await shop.costOf(shop.mixer), 40000);
      await buyMixers(10, 50000);
      expect(await shop.stockOf(shop.mixer), qtyOf(20));
      expect(await shop.costOf(shop.mixer), 45000);
    });

    test('a sale copies the FIFO cost: the oldest purchase is used first', () async {
      await buyMixers(10, 40000);
      await buyMixers(10, 50000);
      await sellMixers(1);
      final item = await shop.db.select(shop.db.salesInvoiceItems).getSingle();
      expect(item.unitCost, 40000);
    });

    test('supplier balance: invoice minus what was paid', () async {
      await buyMixers(10, 40000, paid: 100000);
      expect(await shop.supplierBalance(), 400000 - 100000);
    });

    test('cancel restores stock, cost and balance; refused once goods are sold', () async {
      await buyMixers(10, 40000);
      final second = await buyMixers(10, 50000, paid: 50000);
      await purchases.cancel(second.id, reason: 'خطأ', user: shop.admin);
      expect(await shop.stockOf(shop.mixer), qtyOf(10));
      expect(await shop.costOf(shop.mixer), 40000);
      expect(await shop.supplierBalance(), 400000);

      final third = await buyMixers(5, 40000);
      await sellMixers(12);
      await expectLater(
        purchases.cancel(third.id, reason: 'x', user: shop.admin),
        throwsA(isA<ValidationException>()),
      );
    });

    test('cashier cannot buy', () async {
      await expectLater(
        purchases.post(
          PurchaseInput(
            supplierId: shop.supplierId,
            lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitCost: 1)],
          ),
          user: shop.cashier,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('list shows paid including later payments', () async {
      final inv = await buyMixers(10, 40000, paid: 100000);
      await payments.pay(
        PaymentInput(partyId: shop.supplierId, amount: 50000, invoiceId: inv.id),
        user: shop.admin,
      );
      final row = (await purchases.watchList().first).single;
      expect(row.paid, 150000);
      expect(row.supplierName, 'مورد');
    });
  });

  group('payments', () {
    setUp(() => buyMixers(20, 40000));

    test('customer balance after invoice, partial payment and overpayment on account', () async {
      final inv = await sellMixers(2); // 1,000.00 on credit
      expect(await shop.customerBalance(), 100000);
      await payments.receive(
        PaymentInput(partyId: shop.customerId, amount: 40000, invoiceId: inv.id),
        userId: shop.cashier.id,
      );
      expect(await shop.customerBalance(), 60000);
      expect(await payments.invoiceRemaining(RefType.salesInvoice, inv.id, partyId: shop.customerId), 60000);

      // More than is left on the invoice cannot be linked to it...
      await expectLater(
        payments.receive(PaymentInput(partyId: shop.customerId, amount: 70000, invoiceId: inv.id)),
        throwsA(isA<ValidationException>()),
      );
      // ...but can be taken on account, leaving the customer in credit.
      await payments.receive(PaymentInput(partyId: shop.customerId, amount: 70000));
      expect(await shop.customerBalance(), -10000);
    });

    test('opening balance counts', () async {
      await PartyService(shop.db).saveCustomer(
        const CustomerInput(name: 'عميل', openingBalance: 25000),
        id: shop.customerId,
      );
      await sellMixers(1);
      expect(await shop.customerBalance(), 75000);
    });

    test('paying a supplier is admin only and lowers what we owe', () async {
      await expectLater(
        payments.pay(PaymentInput(partyId: shop.supplierId, amount: 100), user: shop.cashier),
        throwsA(isA<ValidationException>()),
      );
      await payments.pay(PaymentInput(partyId: shop.supplierId, amount: 300000), user: shop.admin);
      expect(await shop.supplierBalance(), 800000 - 300000);
    });

    test('cancelled payment no longer counts', () async {
      await sellMixers(1);
      final p = await payments.receive(PaymentInput(partyId: shop.customerId, amount: 50000));
      expect(await shop.customerBalance(), 0);
      await payments.cancel(p.id, reason: 'خطأ', user: shop.admin);
      expect(await shop.customerBalance(), 50000);
    });

    test('open invoices list what is left, oldest first', () async {
      final a = await sellMixers(1, paid: 10000);
      await sellMixers(1, paid: 50000);
      final b = await sellMixers(2);
      final open = await payments.openInvoices(PartyType.customer, shop.customerId);
      expect(open.map((o) => (o.$1, o.$4)), [(a.id, 40000), (b.id, 100000)]);
    });

    test('an invoice from another customer cannot be paid here', () async {
      final otherId = await PartyService(shop.db).saveCustomer(const CustomerInput(name: 'آخر'));
      final inv = await sellMixers(1, customerId: otherId);
      await expectLater(
        payments.receive(PaymentInput(partyId: shop.customerId, amount: 100, invoiceId: inv.id)),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('cheques', () {
    late int chequeId;

    setUp(() async {
      await buyMixers(20, 40000);
      await sellMixers(2); // owes 1,000.00
      final p = await payments.receive(PaymentInput(
        partyId: shop.customerId,
        amount: 60000,
        method: PaymentMethod.cheque,
        cheque: ChequeInput(number: '123456', bank: 'مصر', dueDate: DateTime(2026, 12, 1)),
      ));
      chequeId = (await (shop.db.select(shop.db.cheques)..where((t) => t.paymentId.equals(p.id))).getSingle()).id;
    });

    test('a pending cheque does not reduce the balance; cleared does', () async {
      expect(await shop.customerBalance(), 100000);
      await payments.clearCheque(chequeId, user: shop.admin);
      expect(await shop.customerBalance(), 40000);
    });

    test('with the setting on, a pending cheque counts at once', () async {
      await SettingsService(shop.db).setBool(SettingKey.countPendingCheques, true);
      expect(await shop.customerBalance(), 40000);
    });

    test('a bounced cheque returns the debt, even with the setting on', () async {
      await SettingsService(shop.db).setBool(SettingKey.countPendingCheques, true);
      await payments.bounceCheque(chequeId, reason: 'رصيد غير كاف', user: shop.admin);
      expect(await shop.customerBalance(), 100000);
      // Only a pending cheque can change state.
      await expectLater(
        payments.clearCheque(chequeId, user: shop.admin),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a cheque needs a number; status changes are admin only', () async {
      await expectLater(
        payments.receive(PaymentInput(
          partyId: shop.customerId,
          amount: 100,
          method: PaymentMethod.cheque,
          cheque: ChequeInput(number: ' ', dueDate: DateTime(2026)),
        )),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        payments.clearCheque(chequeId, user: shop.cashier),
        throwsA(isA<ValidationException>()),
      );
    });

    test('the register lists cheques by due date with the party', () async {
      await payments.receive(PaymentInput(
        partyId: shop.customerId,
        amount: 100,
        method: PaymentMethod.cheque,
        cheque: ChequeInput(number: '1', dueDate: DateTime(2026, 11, 15)),
      ));
      final list = await payments.watchCheques(status: ChequeStatus.pending).first;
      expect(list.map((c) => c.cheque.chequeNo), ['1', '123456']);
      expect(list.first.partyName, 'عميل');
      expect(list.first.isReceived, isTrue);
    });
  });

  group('returns', () {
    late SalesInvoice sold;

    setUp(() async {
      await buyMixers(10, 40000);
      sold = await sellMixers(4); // 2,000.00 on credit
    });

    test('a sale return puts stock back and credits the customer', () async {
      await returns.postSaleReturn(
        ReturnInput(
          originalInvoiceId: sold.id,
          lines: [ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000)],
        ),
        user: shop.cashier,
      );
      expect(await shop.stockOf(shop.mixer), qtyOf(7));
      expect(await shop.customerBalance(), 150000);
      final m = (await shop.db.select(shop.db.stockMovements).get()).last;
      expect(m.unitCost, 40000); // original sale cost
    });

    test('a cash refund leaves the balance as it was', () async {
      await returns.postSaleReturn(
        ReturnInput(
          originalInvoiceId: sold.id,
          lines: [ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000)],
          refundAmount: 50000,
        ),
        user: shop.cashier,
      );
      expect(await shop.customerBalance(), 200000);
    });

    test('cannot return more than was sold, counting earlier returns', () async {
      final line = ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(3), unitPrice: 50000);
      await returns.postSaleReturn(ReturnInput(originalInvoiceId: sold.id, lines: [line]), user: shop.cashier);
      await expectLater(
        returns.postSaleReturn(
          ReturnInput(originalInvoiceId: sold.id, lines: [line.copyQty(qtyOf(2))]),
          user: shop.cashier,
        ),
        throwsA(isA<ValidationException>()),
      );
      final left = await returns.returnableForSale(sold.id);
      expect(left.single.returnable, qtyOf(1));
      expect(left.single.unitPrice, 50000);
    });

    test('a product not on the invoice cannot be returned against it', () async {
      await expectLater(
        returns.postSaleReturn(
          ReturnInput(
            originalInvoiceId: sold.id,
            lines: [ReturnLineInput(productId: shop.pipe.id, qty: 1000, unitPrice: 1)],
          ),
          user: shop.cashier,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a walk-in return must be refunded in full', () async {
      await expectLater(
        returns.postSaleReturn(
          ReturnInput(lines: [ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000)]),
          user: shop.cashier,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a sale with a return cannot be cancelled until the return is', () async {
      final r = await returns.postSaleReturn(
        ReturnInput(
          originalInvoiceId: sold.id,
          lines: [ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000)],
        ),
        user: shop.cashier,
      );
      await expectLater(
        sales.cancel(sold.id, reason: 'x', user: shop.admin),
        throwsA(isA<ValidationException>()),
      );
      await returns.cancel(r.id, reason: 'خطأ', user: shop.admin);
      expect(await shop.stockOf(shop.mixer), qtyOf(6));
      expect(await shop.customerBalance(), 200000);
      await sales.cancel(sold.id, reason: 'x', user: shop.admin);
      expect(await shop.customerBalance(), 0);
    });

    test('a purchase return takes stock out, lowers what we owe, keeps the cost right', () async {
      final bought = await buyMixers(10, 50000); // average now (6x400 + 10x500)/16 = 462.50
      expect(await shop.costOf(shop.mixer), 46250);
      await returns.postPurchaseReturn(
        ReturnInput(
          originalInvoiceId: bought.id,
          lines: [ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(10), unitPrice: 50000)],
        ),
        user: shop.admin,
      );
      expect(await shop.stockOf(shop.mixer), qtyOf(6));
      expect(await shop.costOf(shop.mixer), 40000);
      expect(await shop.supplierBalance(), 400000);
    });

    test('a purchase return is admin only and needs the stock', () async {
      final bought = await buyMixers(2, 40000);
      await expectLater(
        returns.postPurchaseReturn(
          ReturnInput(
            originalInvoiceId: bought.id,
            lines: [ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 40000)],
          ),
          user: shop.cashier,
        ),
        throwsA(isA<ValidationException>()),
      );
      await sellMixers(8); // stock 10 - 4 + 2 - 8 = 0
      await expectLater(
        returns.postPurchaseReturn(
          ReturnInput(
            originalInvoiceId: bought.id,
            lines: [ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 40000)],
          ),
          user: shop.admin,
        ),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('credit limit', () {
    setUp(() async {
      await shop.close();
      shop = await Shop.open(customerCreditLimit: 100000);
      sales = SalesService(shop.db);
      purchases = PurchaseService(shop.db);
      await buyMixers(10, 40000);
    });

    test('a sale over the limit is refused for the cashier', () async {
      await sellMixers(2); // exactly at the limit: fine
      await expectLater(sellMixers(1), throwsA(isA<CreditLimitException>()));
      // Paying at the counter keeps the balance within the limit.
      await sellMixers(1, paid: 50000);
    });

    test('an admin can override, a cashier cannot', () async {
      await sellMixers(2);
      final input = SaleInput(
        customerId: shop.customerId,
        lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000)],
      );
      await expectLater(
        sales.post(input, userId: shop.cashier.id, allowOverCreditLimit: true),
        throwsA(isA<CreditLimitException>()),
      );
      final inv = await sales.post(input, userId: shop.admin.id, allowOverCreditLimit: true);
      expect(inv.total, 50000);
    });
  });

  test('full cycle matches a hand calculation', () async {
    // Hand calculation (EGP):
    // Buy 10 mixers at 400 from the supplier, pay 1,000 now      -> supplier owed 3,000
    // Buy 50 m pipe at 20, on credit                             -> supplier owed 4,000
    // Sell 3 mixers at 500 + 12.5 m at 35 on credit (1,937.50),
    //   200 paid at the counter                                  -> customer owes 1,737.50
    // Customer pays a 1,000 cheque; it clears                    -> 737.50
    // Customer pays a 500 cheque; it bounces                     -> still 737.50
    // Customer returns 1 mixer (500) as credit                   -> 237.50
    // We pay the supplier 2,500 in cash                          -> supplier owed 1,500
    // We return 10 m pipe (200) to the supplier                  -> supplier owed 1,300
    // Stock: mixers 10 - 3 + 1 = 8; pipe 50 - 12.5 - 10 = 27.5
    final pay = PaymentService(shop.db);
    await purchases.post(
      PurchaseInput(
        supplierId: shop.supplierId,
        lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(10), unitCost: 40000)],
        paidAmount: 100000,
      ),
      user: shop.admin,
    );
    final pipeBuy = await purchases.post(
      PurchaseInput(
        supplierId: shop.supplierId,
        lines: [PurchaseLineInput(productId: shop.pipe.id, qty: qtyOf(50), unitCost: 2000)],
      ),
      user: shop.admin,
    );
    final sale = await sales.post(
      SaleInput(
        customerId: shop.customerId,
        lines: [
          SaleLineInput(productId: shop.mixer.id, qty: qtyOf(3), unitPrice: 50000),
          SaleLineInput(productId: shop.pipe.id, qty: 12500, unitPrice: 3500),
        ],
        paidAmount: 20000,
      ),
      userId: shop.cashier.id,
    );
    expect(sale.total, 193750);

    Future<int> cheque(int amount, String no) async {
      final p = await pay.receive(PaymentInput(
        partyId: shop.customerId,
        amount: amount,
        method: PaymentMethod.cheque,
        cheque: ChequeInput(number: no, dueDate: DateTime(2026, 12)),
        invoiceId: sale.id,
      ));
      return (await (shop.db.select(shop.db.cheques)..where((t) => t.paymentId.equals(p.id))).getSingle()).id;
    }

    await pay.clearCheque(await cheque(100000, 'A1'), user: shop.admin);
    await pay.bounceCheque(await cheque(50000, 'A2'), reason: 'مرتد', user: shop.admin);
    await returns.postSaleReturn(
      ReturnInput(
        originalInvoiceId: sale.id,
        lines: [ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000)],
      ),
      user: shop.cashier,
    );
    await pay.pay(PaymentInput(partyId: shop.supplierId, amount: 250000), user: shop.admin);
    await returns.postPurchaseReturn(
      ReturnInput(
        originalInvoiceId: pipeBuy.id,
        lines: [ReturnLineInput(productId: shop.pipe.id, qty: qtyOf(10), unitPrice: 2000)],
      ),
      user: shop.admin,
    );

    expect(await shop.customerBalance(), 23750);
    expect(await shop.supplierBalance(), 130000);
    expect(await shop.stockOf(shop.mixer), qtyOf(8));
    expect(await shop.stockOf(shop.pipe), 27500);
    expect(await shop.costOf(shop.mixer), 40000);
    expect(await shop.costOf(shop.pipe), 2000);

    final balances = BalanceService(shop.db);
    expect((await balances.watchCustomerBalances().first)[shop.customerId], 23750);
    expect((await balances.watchSupplierBalances().first)[shop.supplierId], 130000);
    expect((await sales.watchList().first).single.paid, 120000); // 200 cash + 1,000 cleared
  });
}

extension on ReturnLineInput {
  ReturnLineInput copyQty(int qty) =>
      ReturnLineInput(productId: productId, qty: qty, unitPrice: unitPrice);
}
