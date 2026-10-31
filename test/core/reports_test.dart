import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/reports/report_excel.dart';
import 'package:sanitaryware_erp/core/reports/report_service.dart';
import 'package:sanitaryware_erp/core/reports/report_table.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/expense_service.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/payment_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/return_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/statement_service.dart';

import '../support/fixture.dart';

/// The fixed sample data set (all in October 2026), in EGP:
///
/// Oct 1  Buy 10 mixers at 400, 1,000 paid; buy 50 m pipe at 20 on credit.
/// Oct 2  S1 to "عميل": 2 mixers at 500, invoice discount 50 -> 950, credit.
///        S2 walk-in: 10 m pipe at 35 -> 350, paid.
/// Oct 3  S3 to "مقاول" (opening balance 100): 1 mixer at 450 + 5 m at 35
///        -> 625, 125 paid.  S4 to "عميل": 1 mixer at 500, then cancelled.
/// Oct 4  "عميل" returns 1 mixer from S1 at 500 (credit); pays 200 on account.
/// Oct 5  Expenses: rent 1,500; transport 100 and 50; one of 999 cancelled.
///        Cheque from "مقاول" 300 due Oct 20; our cheque to the supplier
///        1,000 due Oct 25 (both still pending).
void main() {
  late Shop shop;
  late ReportService reports;
  late int contractorId;
  late Expense cancelledExpense;

  DateTime oct(int day, [int hour = 10]) => DateTime(2026, 10, day, hour);
  final from = DateTime(2026, 10, 1);
  final to = DateTime(2026, 10, 5);

  setUp(() async {
    shop = await Shop.open();
    reports = ReportService(shop.db);
    final db = shop.db;
    final purchases = PurchaseService(db);
    final sales = SalesService(db);
    final payments = PaymentService(db);
    final expenses = ExpenseService(db);
    final admin = shop.admin;

    await ProductService(db).update(
      shop.mixer.id,
      ProductInput(code: 'M1', nameAr: 'خلاط', unitId: shop.mixer.unitId, priceRetail: 50000, minStock: qtyOf(10)),
    );
    contractorId = await PartyService(db).saveCustomer(const CustomerInput(name: 'مقاول', openingBalance: 10000));

    await purchases.post(
      PurchaseInput(
        supplierId: shop.supplierId,
        date: oct(1),
        lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(10), unitCost: 40000)],
        paidAmount: 100000,
      ),
      user: admin,
    );
    await purchases.post(
      PurchaseInput(
        supplierId: shop.supplierId,
        date: oct(1),
        lines: [PurchaseLineInput(productId: shop.pipe.id, qty: qtyOf(50), unitCost: 2000)],
      ),
      user: admin,
    );

    final s1 = await sales.post(
      SaleInput(
        customerId: shop.customerId,
        date: oct(2),
        lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(2), unitPrice: 50000)],
        discount: 5000,
      ),
      userId: admin.id,
    );
    await sales.post(
      SaleInput(
        date: oct(2, 11),
        lines: [SaleLineInput(productId: shop.pipe.id, qty: qtyOf(10), unitPrice: 3500)],
        paidAmount: 35000,
      ),
      userId: admin.id,
    );
    await sales.post(
      SaleInput(
        customerId: contractorId,
        date: oct(3),
        lines: [
          SaleLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 45000),
          SaleLineInput(productId: shop.pipe.id, qty: qtyOf(5), unitPrice: 3500),
        ],
        paidAmount: 12500,
      ),
      userId: admin.id,
    );
    final s4 = await sales.post(
      SaleInput(
        customerId: shop.customerId,
        date: oct(3, 12),
        lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000)],
      ),
      userId: admin.id,
    );
    await sales.cancel(s4.id, reason: 'خطأ', user: admin);

    await ReturnService(db).postSaleReturn(
      ReturnInput(
        originalInvoiceId: s1.id,
        date: oct(4),
        lines: [ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000)],
      ),
      user: admin,
    );
    await payments.receive(PaymentInput(partyId: shop.customerId, amount: 20000, date: oct(4, 15)));

    final cats = {for (final c in await db.select(db.expenseCategories).get()) c.nameAr: c.id};
    await expenses.add(ExpenseInput(categoryId: cats['إيجار']!, amount: 150000, date: oct(5)), user: admin);
    await expenses.add(ExpenseInput(categoryId: cats['نقل ومشال']!, amount: 10000, date: oct(5)), user: admin);
    await expenses.add(ExpenseInput(categoryId: cats['نقل ومشال']!, amount: 5000, date: oct(5)), user: admin);
    cancelledExpense =
        await expenses.add(ExpenseInput(categoryId: cats['نثريات']!, amount: 99900, date: oct(5)), user: admin);
    await expenses.cancel(cancelledExpense.id, reason: 'مكرر', user: admin);

    await payments.receive(PaymentInput(
      partyId: contractorId,
      amount: 30000,
      method: PaymentMethod.cheque,
      cheque: ChequeInput(number: 'C-300', dueDate: DateTime(2026, 10, 20)),
      date: oct(5),
    ));
    await payments.pay(
      PaymentInput(
        partyId: shop.supplierId,
        amount: 100000,
        method: PaymentMethod.cheque,
        cheque: ChequeInput(number: 'OUT-1', dueDate: DateTime(2026, 10, 25)),
        date: oct(5),
      ),
      user: admin,
    );
  });

  tearDown(() => shop.close());

  test('daily sales', () async {
    final t = await reports.dailySales(from: from, to: to);
    expect(t.rows.map((r) => (r[0] as DateTime).day), [2, 3, 4]);
    expect(t.rows[0].sublist(1), [2, 130000, 0, 130000]);
    expect(t.rows[1].sublist(1), [1, 62500, 0, 62500]); // S4 is cancelled
    expect(t.rows[2].sublist(1), [0, 0, 50000, -50000]);
    expect(t.totals.sublist(1), [3, 192500, 50000, 142500]);
  });

  test('sales by customer', () async {
    final t = await reports.salesByCustomer(from: from, to: to);
    expect(t.rows, [
      ['مقاول', 1, 62500, 0, 62500],
      ['عميل', 1, 95000, 50000, 45000],
      ['نقدي', 1, 35000, 0, 35000],
    ]);
  });

  test('sales by product (before the invoice discount)', () async {
    final t = await reports.salesByProduct(from: from, to: to);
    expect(t.rows, [
      ['M1', 'خلاط', qtyOf(3), 145000, qtyOf(1), 50000, 95000],
      ['P1', 'ماسورة', qtyOf(15), 52500, 0, 0, 52500],
    ]);
    expect(t.total('الصافي'), 147500);
  });

  test('profit', () async {
    final t = await reports.profit(from: from, to: to);
    final v = {for (final r in t.rows) r[0]: r[1]};
    expect(v['المبيعات (بعد الخصم)'], 192500);
    expect(v['مرتجعات المبيعات'], -50000);
    expect(v['صافي المبيعات'], 142500);
    expect(v['تكلفة البضاعة المباعة'], -150000); // 800 + 200 + 500
    expect(v['تكلفة البضاعة المرتجعة'], 40000);
    expect(v['مجمل الربح'], 32500);
    expect(v['المصروفات'], -165000);
    expect(v['صافي الربح'], -132500);
  });

  test('a range that leaves days out', () async {
    final t = await reports.dailySales(from: DateTime(2026, 10, 3), to: DateTime(2026, 10, 3));
    expect(t.totals.sublist(1), [1, 62500, 0, 62500]);
  });

  test('expenses by category ignore cancelled ones', () async {
    final t = await reports.expensesByCategory(from: from, to: to);
    expect(t.rows, [
      ['إيجار', 1, 150000],
      ['نقل ومشال', 2, 15000],
    ]);
    expect(t.totals.sublist(1), [3, 165000]);
  });

  test('cheques due', () async {
    final t = await reports.chequesDue(from: DateTime(2026, 10, 1), to: DateTime(2026, 10, 31));
    expect(t.rows.map((r) => r.sublist(1)), [
      ['C-300', '', 'مقاول', 'وارد', 30000],
      ['OUT-1', '', 'مورد', 'صادر', 100000],
    ]);
    final early = await reports.chequesDue(from: DateTime(2026, 10, 1), to: DateTime(2026, 10, 21));
    expect(early.rows, hasLength(1));
  });

  test('stock levels, low stock and valuation', () async {
    final levels = await reports.stockLevels();
    expect({for (final r in levels.rows) r[0]: r[4]}, {'M1': qtyOf(8), 'P1': qtyOf(35)});

    final low = await reports.lowStock();
    expect(low.rows, [
      ['M1', 'خلاط', qtyOf(8), qtyOf(10), qtyOf(2)],
    ]);

    final value = await reports.stockValuation();
    expect(value.rows, [
      ['M1', 'خلاط', qtyOf(8), 40000, 320000],
      ['P1', 'ماسورة', qtyOf(35), 2000, 70000],
    ]);
    expect(value.total('القيمة'), 390000);
  });

  test('customers owing and supplier balances (pending cheques not counted)', () async {
    final owing = await reports.customersOwing();
    expect(owing.rows, [
      ['مقاول', '', 60000, null],
      ['عميل', '', 25000, null],
    ]);
    final suppliers = await reports.supplierBalances();
    expect(suppliers.rows, [
      ['مورد', '', 400000],
    ]);
  });

  test('every report builds through the shared entry point', () async {
    for (final kind in ReportKind.values) {
      final t = await reports.build(kind, from: from, to: to);
      expect(t.title, kind.title);
      for (final row in t.rows) {
        expect(row, hasLength(t.columns.length), reason: kind.title);
      }
    }
  });

  group('statements', () {
    test('a range starts from the balance before it; closing equals the balance', () async {
      final s = await StatementService(shop.db).customer(shop.customerId, from: DateTime(2026, 10, 3), to: to);
      expect(s.openingBalance, 95000); // S1 on Oct 2
      expect(s.entries.map((e) => (e.kind, e.increase, e.decrease, e.balance)), [
        ('مرتجع بيع', 0, 50000, 45000),
        ('سداد من العميل', 0, 20000, 25000),
      ]);
      expect(s.closingBalance, await shop.customerBalance());
    });

    test('opening balance, payment at the counter, pending cheque listed apart', () async {
      final s = await StatementService(shop.db).customer(contractorId);
      expect(s.openingBalance, 10000);
      expect(s.entries.map((e) => e.balance), [72500, 60000]);
      expect(s.pendingCheques.single.chequeNo, 'C-300');
    });

    test('supplier statement', () async {
      final s = await StatementService(shop.db).supplier(shop.supplierId);
      expect(s.entries.map((e) => (e.kind, e.balance)), [
        ('فاتورة شراء', 400000),
        ('دفعة للمورد', 300000),
        ('فاتورة شراء', 400000),
      ]);
      expect(s.closingBalance, await shop.supplierBalance());
      expect(s.totalIncrease, 500000);
      expect(s.totalDecrease, 100000);
    });
  });

  group('expenses', () {
    test('admin only, positive amounts, cancelled once', () async {
      final service = ExpenseService(shop.db);
      final cat = (await shop.db.select(shop.db.expenseCategories).get()).first.id;
      await expectLater(
        service.add(ExpenseInput(categoryId: cat, amount: 100), user: shop.cashier),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        service.add(ExpenseInput(categoryId: cat, amount: 0), user: shop.admin),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        service.cancel(cancelledExpense.id, reason: 'x', user: shop.admin),
        throwsA(isA<ValidationException>()),
      );
      final list = await service.watchList(from: from, to: to).first;
      expect(list, hasLength(4));
      expect(list.where((e) => e.expense.status == 'active'), hasLength(3));
    });

    test('duplicate category names are refused', () async {
      await expectLater(
        ExpenseService(shop.db).saveCategory(name: 'ايجار'),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  test('Excel export keeps numbers as numbers and adds the totals row', () async {
    final t = await reports.dailySales(from: from, to: to);
    final bytes = reportToExcel(t, from: from, to: to, companyName: 'معرض');
    final sheet = Excel.decodeBytes(bytes).tables.values.first;
    final values = [
      for (final row in sheet.rows) [for (final c in row) c?.value],
    ];
    expect(values.first.first.toString(), 'معرض');
    final header = values.indexWhere((r) => r.isNotEmpty && r.first.toString() == 'التاريخ');
    expect(header, greaterThan(0));
    final totals = values.last;
    expect(totals.first.toString(), 'الإجمالي');
    num number(Object? v) => v is DoubleCellValue ? v.value : (v as IntCellValue).value;
    expect(number(totals[2]), 1925);
    expect(number(totals[1]), 3);
    expect(number(values[header + 1][2]), 1300); // Oct 2 sales, in pounds
    expect(values.length - header - 2, 3); // three day rows
  });

  test('dashboard for Oct 3', () async {
    final d = await reports.dashboard(now: oct(3, 18));
    expect(d.todaySales, 62500); // S4 is cancelled
    expect(d.todayInvoices, 1);
    expect(d.todayReceived, 12500); // paid at the counter on S3
    expect(d.lowStockCount, 1);
    expect(d.chequesInDue, 0); // due Oct 20, more than a week away
    expect(d.topDebtors, [('مقاول', 60000), ('عميل', 25000)]);
    final later = await reports.dashboard(now: oct(18));
    expect((later.chequesInDue, later.chequesInDueTotal), (1, 30000));
    expect((later.chequesOutDue, later.chequesOutDueTotal), (1, 100000));
  });

  test('display formatting', () {
    expect(ReportTable.display(192500, ColumnType.money), '1,925.00');
    expect(ReportTable.display(qtyOf(35), ColumnType.qty), '35');
    expect(ReportTable.display(DateTime(2026, 10, 4), ColumnType.date), '2026/10/04');
    expect(ReportTable.display(null, ColumnType.money), '');
    expect(ReportTable.display('الإجمالي', ColumnType.date), 'الإجمالي'); // totals row
  });
}
