import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/auth/auth_service.dart';
import 'package:sanitaryware_erp/core/auth/password_hasher.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/balance_service.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/expense_plan_service.dart';
import 'package:sanitaryware_erp/core/services/ledger_service.dart';
import 'package:sanitaryware_erp/core/services/lead_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_order_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/sales_order_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';

import '../support/fixture.dart';

/// The blueprint items finished in 2.2.0.
void main() {
  late Shop shop;
  late LedgerService ledger;

  setUp(() async {
    shop = await Shop.open();
    ledger = LedgerService(shop.db);
    await PurchaseService(shop.db).post(
      PurchaseInput(
        supplierId: shop.supplierId,
        lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(10), unitCost: 30000)],
      ),
      user: shop.admin,
    );
  });
  tearDown(() => shop.close());

  Future<int> account(String key) async =>
      (await ledger.balances()).firstWhere((b) => b.account.systemKey == key).closing;

  Future<void> booksBalance() async {
    final rows = await ledger.balances();
    expect(rows.fold(0, (s, r) => s + r.debit), rows.fold(0, (s, r) => s + r.credit));
    expect((await ledger.balanceSheet()).balances, isTrue);
    final ap = await shop.db.customSelect(
      "SELECT COALESCE(SUM(l.credit - l.debit), 0) AS b FROM journal_lines l JOIN journal_entries e ON e.id = l.entry_id "
      "JOIN accounts a ON a.id = l.account_id WHERE e.status = 'posted' AND a.system_key = 'ap' AND l.party_id = ${shop.supplierId}",
    ).getSingle();
    expect(ap.read<int>('b'), await BalanceService(shop.db).supplierBalance(shop.supplierId));
  }

  SaleLineInput mixer(int n, {int? directFrom, int directCost = 0}) => SaleLineInput(
        productId: shop.mixer.id,
        qty: qtyOf(n),
        unitPrice: 50000,
        priceListId: shop.priceListId,
        directSupplierId: directFrom,
        directUnitCost: directCost,
      );

  test('a quotation has a validity; a revision copies it and retires the old one', () async {
    final orders = SalesOrderService(shop.db);
    final id = await orders.createDraft(
      customerId: shop.customerId,
      lines: [SoLineInput(productId: shop.mixer.id, qty: qtyOf(2))],
      asQuotation: true,
      user: shop.admin,
    );
    var q = (await orders.detail(id)).order;
    expect(q.validUntil!.difference(q.orderDate).inDays, defaultQuoteValidityDays);
    final newId = await orders.revise(id, user: shop.admin);
    final old = (await orders.detail(id)).order;
    final rev = await orders.detail(newId);
    expect(old.status, SoStatus.revised);
    expect(rev.order.revision, 1);
    expect(rev.order.revisedFromId, id);
    expect(rev.lines.single.line.qty, qtyOf(2));
    await expectLater(orders.confirm(id, user: shop.admin), throwsA(isA<ValidationException>()), reason: 'retired');
    // Expired: the cashier cannot confirm it, the owner can.
    await orders.setValidUntil(newId, DateTime.now().subtract(const Duration(days: 3)), user: shop.admin);
    q = (await orders.detail(newId)).order;
    expect(SalesOrderService.isExpired(q), isTrue);
    await expectLater(orders.confirm(newId, user: shop.cashier), throwsA(isA<ValidationException>()));
    await orders.confirm(newId, user: shop.admin);
  });

  test('receiving: only accepted goods enter stock; rejected stay open on the order', () async {
    final orders = PurchaseOrderService(shop.db);
    final id = await orders.createDraft(
      supplierId: shop.supplierId,
      lines: [PoLineInput(productId: shop.mixer.id, qty: qtyOf(5))],
      user: shop.admin,
    );
    final lineId = (await orders.detail(id)).lines.single.line.id;
    await orders.approve(id, manualCosts: {lineId: 30000}, user: shop.admin);
    final inv = await orders.receive(id, qtyByLine: {lineId: qtyOf(3)}, user: shop.admin);
    await orders.reject(id, qtyByLine: {lineId: qtyOf(2)}, reason: 'كسر', invoiceId: inv.id, user: shop.admin);
    expect(await shop.stockOf(shop.mixer), qtyOf(13));
    final line = (await orders.detail(id)).lines.single;
    expect(line.line.qtyRejected, qtyOf(2));
    expect(line.remaining, qtyOf(2), reason: 'the supplier can send them again');
    expect((await orders.rejections(id)).single.reason, 'كسر');
    expect(inv.total, 90000, reason: 'the invoice is for what was accepted');
  });

  test('direct from supplier: no stock, owed to the supplier, cost of the sale', () async {
    final before = await BalanceService(shop.db).supplierBalance(shop.supplierId);
    final sale = await SalesService(shop.db).post(
      SaleInput(customerId: shop.customerId, lines: [mixer(2, directFrom: shop.supplierId, directCost: 32000), mixer(1)]),
      userId: shop.admin.id,
    );
    expect(await shop.stockOf(shop.mixer), qtyOf(9), reason: 'only the stock line left the shop');
    expect(await BalanceService(shop.db).supplierBalance(shop.supplierId), before + 64000);
    final direct = await (shop.db.select(shop.db.purchaseInvoices)..where((p) => p.isDirect.equals(true))).getSingle();
    expect(direct.salesInvoiceId, sale.id);
    expect(await account('cogs'), 64000 + 30000);
    expect(await account('inventory'), 300000 - 30000);
    await booksBalance();
    await SalesService(shop.db).cancel(sale.id, reason: 'خطأ', user: shop.admin);
    expect(await BalanceService(shop.db).supplierBalance(shop.supplierId), before);
    expect(await shop.stockOf(shop.mixer), qtyOf(10));
    await booksBalance();
    await expectLater(
      SalesService(shop.db).post(
        SaleInput(customerId: shop.customerId, lines: [mixer(1, directFrom: shop.supplierId, directCost: 1)]),
        userId: shop.cashier.id,
      ),
      throwsA(isA<ValidationException>()),
      reason: 'a direct purchase needs the right to buy',
    );
  });

  test('input VAT: owed to the supplier, not in the stock cost, reported', () async {
    await PurchaseService(shop.db).post(
      PurchaseInput(
        supplierId: shop.supplierId,
        lines: [PurchaseLineInput(productId: shop.pipe.id, qty: qtyOf(10), unitCost: 10000)],
        vatAmount: 14000,
      ),
      user: shop.admin,
    );
    expect(await account('vat_in'), 14000);
    expect(await account('inventory'), 300000 + 100000);
    final vat = await ledger.vat(from: DateTime(2000), to: DateTime.now());
    expect(vat.inputVat, 14000);
    await booksBalance();
  });

  test('delivery: the fee is on the invoice and income; delivered needs proof', () async {
    final sales = SalesService(shop.db);
    final inv = await sales.post(
      SaleInput(
        customerId: shop.customerId,
        lines: [mixer(1)],
        deliveryMethod: DeliveryMethod.delivery,
        deliveryAddress: 'المنصورة',
        deliveryFee: 5000,
      ),
      userId: shop.cashier.id,
    );
    expect(inv.total, 55000);
    expect(inv.deliveryStatus, DeliveryStatus.preparing);
    expect(await account('delivery_income'), -5000);
    await expectLater(sales.setDeliveryStatus(inv.id, DeliveryStatus.delivered, user: shop.cashier),
        throwsA(isA<ValidationException>()));
    await sales.setDeliveryStatus(inv.id, DeliveryStatus.delivered, proof: 'استلمه أحمد', user: shop.cashier);
    final d = await (shop.db.select(shop.db.salesInvoices)..where((s) => s.id.equals(inv.id))).getSingle();
    expect(d.deliveryProof, 'استلمه أحمد');
    expect(d.deliveredAt, isNotNull);
    expect((await sales.watchDeliveries().first).single.$1.id, inv.id);
  });

  test('soft close: only the owner and the accountant record in the period', () async {
    final accountant = await AuthService(shop.db, hasher: const PasswordHasher(iterations: 1))
        .addUser(fullName: 'محاسب', username: 'acc', password: '123456', role: UserRole.accountant, by: shop.admin);
    await ledger.softClose(DateTime.now(), user: accountant);
    final sales = SalesService(shop.db);
    final input = SaleInput(customerId: shop.customerId, lines: [mixer(1)]);
    await expectLater(sales.post(input, userId: shop.cashier.id), throwsA(isA<ValidationException>()));
    await sales.post(input, userId: accountant.id);
    await ledger.softClose(null, user: accountant);
    await sales.post(input, userId: shop.cashier.id);
  });

  test('leads: stages, a reason when lost, and conversion to a customer', () async {
    final leads = LeadService(shop.db);
    final id = await leads.save(const LeadInput(name: 'م. سامي', phone: '0109', interest: 'حمام كامل', expectedValue: 4000000),
        user: shop.cashier);
    await leads.setStage(id, LeadStage.quoted, user: shop.cashier);
    await expectLater(leads.setStage(id, LeadStage.lost, user: shop.cashier), throwsA(isA<ValidationException>()));
    final customerId = await leads.convert(id, user: shop.cashier);
    final c = await (shop.db.select(shop.db.customers)..where((t) => t.id.equals(customerId))).getSingle();
    expect(c.name, 'م. سامي');
    final lead = (await leads.watchAll().first).single;
    expect(lead.stage, LeadStage.won);
    expect(await leads.convert(id, user: shop.cashier), customerId, reason: 'converting twice is harmless');
  });

  test('expense plans record once and move on; past expenses import with their dates', () async {
    final plans = ExpensePlanService(shop.db);
    final cat = (await shop.db.select(shop.db.expenseCategories).get()).first;
    final due = DateTime(DateTime.now().year, DateTime.now().month, 1);
    final planId = await plans.savePlan(categoryId: cat.id, amount: 1500000, nextDue: due, user: shop.admin);
    expect((await shop.db.select(shop.db.expenses).get()), isEmpty, reason: 'a plan is not an expense');
    await plans.record(planId, amount: 1600000, user: shop.admin);
    final e = (await shop.db.select(shop.db.expenses).get()).single;
    expect(e.amount, 1600000);
    final p = (await plans.watchPlans().first).single.plan;
    expect(p.nextDue, DateTime(due.year, due.month + 1, 1));

    final excel = Excel.createExcel();
    final sheet = excel[excel.getDefaultSheet()!];
    sheet.appendRow([for (final h in ExpensePlanService.headers) TextCellValue(h)]);
    sheet.appendRow([TextCellValue('2026/01/31'), TextCellValue(cat.nameAr), IntCellValue(900), TextCellValue('نقدي'), TextCellValue('يناير')]);
    sheet.appendRow([TextCellValue('2026/01/31'), TextCellValue(cat.nameAr), IntCellValue(900), TextCellValue('نقدي'), TextCellValue('مكرر')]);
    sheet.appendRow([TextCellValue('28/02/2026'), TextCellValue('صيانة'), IntCellValue(300), TextCellValue('بنك'), TextCellValue('')]);
    sheet.appendRow([TextCellValue('2026/02/10'), TextCellValue('صيانة'), TextCellValue('abc'), TextCellValue(''), TextCellValue('')]);
    final rows = await plans.preview(excel.encode()!);
    expect(rows.length, 4);
    expect(rows[0].ok, isTrue);
    expect(rows[1].duplicate, isTrue);
    expect(rows[2].problems, isEmpty, reason: 'day/month/year is understood');
    expect(rows[2].newCategory, isTrue);
    expect(rows[3].problems, isNotEmpty);
    expect(await plans.import(rows, user: shop.admin), 2);
    final imported = await (shop.db.select(shop.db.expenses)..where((t) => t.amount.equals(90000))).getSingle();
    expect(imported.date.year, 2026);
    expect(imported.date.month, 1);
  });
}
