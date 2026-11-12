import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/balance_service.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/expense_service.dart';
import 'package:sanitaryware_erp/core/services/ledger_service.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/payment_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/return_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/settings_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';

import '../support/fixture.dart';

void main() {
  late Shop shop;
  late LedgerService ledger;

  setUp(() async {
    shop = await Shop.open();
    ledger = LedgerService(shop.db);
  });

  tearDown(() => shop.close());

  Future<int> accountBalance(String key) async {
    final rows = await ledger.balances();
    final r = rows.firstWhere((b) => b.account.systemKey == key);
    return r.closing;
  }

  Future<int> partyBalance(String key, int partyId) async {
    await ledger.catchUp();
    final r = await shop.db.customSelect(
      "SELECT COALESCE(SUM(l.debit - l.credit), 0) AS b FROM journal_lines l "
      "JOIN journal_entries e ON e.id = l.entry_id JOIN accounts a ON a.id = l.account_id "
      "WHERE e.status = 'posted' AND a.system_key = '$key' AND l.party_id = $partyId",
    ).getSingle();
    return r.read<int>('b');
  }

  Future<int> stockValue() async {
    final layers = await shop.db.select(shop.db.costLayers).get();
    return layers.fold<int>(0, (s, l) => s + (l.qtyRemaining * l.unitCost / qtyScale).round());
  }

  Future<void> checkBooks() async {
    final rows = await ledger.balances();
    final dr = rows.fold(0, (s, r) => s + r.debit + r.openingDebit);
    final cr = rows.fold(0, (s, r) => s + r.credit + r.openingCredit);
    expect(dr, cr, reason: 'trial balance');
    expect(await partyBalance('ar', shop.customerId), await BalanceService(shop.db).customerBalance(shop.customerId),
        reason: 'customer in the ledger = customer statement');
    expect(-await partyBalance('ap', shop.supplierId), await BalanceService(shop.db).supplierBalance(shop.supplierId),
        reason: 'supplier in the ledger = supplier statement');
    expect((await accountBalance('inventory') - await stockValue()).abs(), lessThanOrEqualTo(5),
        reason: 'inventory account = stock value');
    final bs = await ledger.balanceSheet();
    expect(bs.balances, isTrue, reason: 'assets = liabilities + equity');
  }

  Future<PurchaseInvoice> buy(int count, int cost, {int paid = 0}) => PurchaseService(shop.db).post(
        PurchaseInput(
          supplierId: shop.supplierId,
          lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(count), unitCost: cost)],
          paidAmount: paid,
        ),
        user: shop.admin,
      );

  Future<SalesInvoice> sell(int count, {int paid = 0}) => SalesService(shop.db).post(
        SaleInput(
          customerId: shop.customerId,
          lines: [
            SaleLineInput(
                productId: shop.mixer.id, qty: qtyOf(count), unitPrice: 50000, priceListId: shop.priceListId),
          ],
          paidAmount: paid,
        ),
        userId: shop.cashier.id,
      );

  test('a sale posts receivable, sales, cost and stock', () async {
    await buy(10, 40000);
    await sell(2);
    expect(await accountBalance('ar'), 100000);
    expect(await accountBalance('sales'), -100000);
    expect(await accountBalance('cogs'), 80000);
    expect(await accountBalance('inventory'), 400000 - 80000);
    expect(await accountBalance('ap'), -400000);
    await checkBooks();
  });

  test('a cancelled invoice leaves nothing in the books', () async {
    await buy(10, 40000);
    final inv = await sell(2, paid: 30000);
    await SalesService(shop.db).cancel(inv.id, reason: 'خطأ', user: shop.admin);
    expect(await accountBalance('sales'), 0);
    expect(await accountBalance('cogs'), 0);
    await checkBooks();
  });

  test('the whole cycle keeps the books equal to the statements', () async {
    final parties = PartyService(shop.db);
    final c = await shop.db.select(shop.db.customers).getSingle();
    await parties.saveCustomer(CustomerInput(name: c.name, openingBalance: 25000), id: c.id);
    await buy(10, 40000, paid: 100000);
    await buy(5, 42000);
    final sold = await sell(6, paid: 50000);
    final payments = PaymentService(shop.db);
    final p = await payments.receive(PaymentInput(
      partyId: shop.customerId,
      amount: 60000,
      method: PaymentMethod.cheque,
      cheque: ChequeInput(number: '1', bank: 'مصر', dueDate: DateTime(2027)),
    ));
    await checkBooks();
    await SettingsService(shop.db).setBool(SettingKey.countPendingCheques, true);
    expect(await accountBalance('cheques_in'), 60000);
    await checkBooks();
    final cheque = await (shop.db.select(shop.db.cheques)..where((t) => t.paymentId.equals(p.id))).getSingle();
    await payments.clearCheque(cheque.id, user: shop.admin);
    expect(await accountBalance('cheques_in'), 0);
    await payments.pay(PaymentInput(partyId: shop.supplierId, amount: 70000), user: shop.admin);
    final returns = ReturnService(shop.db);
    await returns.postSaleReturn(
      ReturnInput(
        originalInvoiceId: sold.id,
        lines: [ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000)],
        refundAmount: 20000,
      ),
      user: shop.cashier,
    );
    await checkBooks();
    final bought = (await shop.db.select(shop.db.purchaseInvoices).get()).first;
    await returns.postPurchaseReturn(
      ReturnInput(
        originalInvoiceId: bought.id,
        lines: [ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 40000)],
      ),
      user: shop.admin,
    );
    await checkBooks();
    final stock = StockService(shop.db);
    await stock.adjust(productId: shop.mixer.id, delta: -qtyOf(1), reason: 'كسر', userId: shop.admin.id);
    await stock.adjust(productId: shop.mixer.id, delta: qtyOf(2), reason: 'جرد', userId: shop.admin.id);
    final cat = (await shop.db.select(shop.db.expenseCategories).get()).first;
    await ExpenseService(shop.db).add(ExpenseInput(categoryId: cat.id, amount: 15000), user: shop.admin);
    await checkBooks();
    expect(await accountBalance('stock_loss'), 40000);
    final pl = await ledger.profitAndLoss();
    expect(pl.operating.total, 15000);
    expect(pl.netSales, 300000 - 50000);
    final bs = await ledger.balanceSheet();
    expect(bs.profitToDate, pl.netProfit);
  });

  test('a manual entry must balance; capital shows in equity', () async {
    final accounts = await ledger.accounts();
    int id(String key) => accounts.firstWhere((a) => a.systemKey == key).id;
    await expectLater(
      ledger.addManual(
        date: DateTime.now(),
        memo: 'رأس مال',
        lines: [ManualLine(accountId: id('cash'), debit: 100), ManualLine(accountId: id('capital'), credit: 90)],
        user: shop.admin,
      ),
      throwsA(isA<ValidationException>()),
    );
    await ledger.addManual(
      date: DateTime.now(),
      memo: 'رأس مال',
      lines: [ManualLine(accountId: id('cash'), debit: 1000000), ManualLine(accountId: id('capital'), credit: 1000000)],
      user: shop.admin,
    );
    final bs = await ledger.balanceSheet();
    expect(bs.equity.total, 1000000);
    expect(bs.balances, isTrue);
    await expectLater(
      ledger.addManual(
        date: DateTime.now(),
        memo: 'x',
        lines: [ManualLine(accountId: id('cash'), debit: 1), ManualLine(accountId: id('capital'), credit: 1)],
        user: shop.cashier,
      ),
      throwsA(isA<ValidationException>()),
    );
  });

  test('a closed period refuses new documents dated in it', () async {
    await buy(10, 40000);
    await ledger.closeUntil(DateTime.now(), user: shop.admin);
    await expectLater(sell(1), throwsA(predicate((e) => '$e'.contains('PERIOD_LOCKED'))));
    await ledger.reopenFrom(DateTime.now(), reason: 'تصحيح', user: shop.admin);
    await sell(1);
    await checkBooks();
  });

  test('aging puts the balance against the newest invoices', () async {
    await buy(10, 40000);
    await sell(2);
    final rows = await ledger.aging(customers: true, asOf: DateTime.now().add(const Duration(days: 45)));
    expect(rows.single.total, 100000);
    expect(rows.single.buckets[2], 100000);
  });

  test('rebuilding gives the same books', () async {
    await buy(10, 40000, paid: 50000);
    await sell(3, paid: 20000);
    final before = {for (final b in await ledger.balances()) b.account.id: b.closing};
    await ledger.rebuild();
    final after = {for (final b in await ledger.balances()) b.account.id: b.closing};
    expect(after, before);
  });
}
