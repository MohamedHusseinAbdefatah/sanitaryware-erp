@Timeout(Duration(minutes: 2))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sanitaryware_erp/core/auth/auth_service.dart';
import 'package:sanitaryware_erp/core/auth/password_hasher.dart';
import 'package:sanitaryware_erp/core/backup/backup_actions.dart';
import 'package:sanitaryware_erp/core/backup/backup_service.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/printing/documents.dart';
import 'package:sanitaryware_erp/core/printing/pdf_fonts.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/reports/report_service.dart';
import 'package:sanitaryware_erp/core/services/balance_service.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/expense_service.dart';
import 'package:sanitaryware_erp/core/services/import_service.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/payment_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/return_service.dart';
import 'package:sanitaryware_erp/core/services/fifo_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/settings_service.dart';
import 'package:sanitaryware_erp/core/services/statement_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';
import 'package:sanitaryware_erp/features/parties/statement_dialog.dart';

/// The plan's manual test script (section 8), run against a real database
/// file. Every expected number below was worked out by hand first.
///
/// 1. Import 40 products: P01 cost 100 / retail 150 / 10 in stock; P02 cost
///    200 / 300 / 5; P03..P39 cost 100+i / 150+i / 4 each; P40 pipe by the
///    meter, cost 10 / 20 / 100 m.
/// 2. Supplier A: 10 x P01 at 120, paid 1,200 cash. Supplier B: 10 x P02 at
///    180 on credit (1,800).
///    Average cost: P01 (10x100 + 10x120)/20 = 110; P02 (5x200 + 10x180)/15
///    = 186.666... -> 186.67.
/// 3. S1 cash (walk-in): 2 x P01 at 150 = 300, paid.
///    S2 credit to C1: 3 x P02 at 300 = 900.
///    S3 partial to C2: 12.5 m P40 at 20 + 1 x P01 at 150 = 400, 100 paid.
/// 4. C1 cheque 500 against S2 -> cleared. C1 cheque 300 -> bounced.
/// 5. C1 returns 1 x P02 from S2 at 300 (credit).
/// 6. S4 to C2 (1 x P01 at 150) cancelled by the admin; the cashier may not
///    cancel S1.
/// 7. Expenses: rent 1,000, transport 200, misc 50.
///
/// Expected:
///   C1 owes 900 - 500 - 300 = 100; C2 owes 400 - 100 = 300.
///   Supplier A 0; supplier B 1,800.
///   Stock: P01 10+10-2-1 = 17; P02 5+10-3+1 = 13; P40 100-12.5 = 87.5 m.
///   Sales 1,600 in 3 invoices, returns 300, net 1,300.
///   Cost of sales: S1 2x110 = 220; S2 3x186.67 = 560.01; S3 125 + 110 = 235
///     -> 1,015.01; returned cost 186.67; net cost 828.34.
///   Gross profit 1,300 - 828.34 = 471.66; expenses 1,250; net -778.34.
///   Stock value: P01 17x110 = 1,870; P02 13x186.67 = 2,426.71;
///     P40 87.5x10 = 875; P03..P39 4 x sum(100+i, i=3..39) = 4 x 4,477
///     = 17,908 -> total 23,079.71.
void main() {
  late Directory root;
  late File dbFile;
  late BackupService backups;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('erp_acceptance');
    dbFile = File(p.join(root.path, 'erp.sqlite'));
    backups = BackupService(dir: Directory(p.join(root.path, 'backups')));
  });

  tearDown(() => root.delete(recursive: true));

  AppDatabase open() => AppDatabase(NativeDatabase(dbFile));

  List<int> productSheet() {
    final excel = Excel.createExcel();
    final s = excel[excel.getDefaultSheet()!];
    s.appendRow([for (final h in ['الكود', 'اسم الصنف', 'التصنيف', 'الوحدة', 'سعر التكلفة', 'سعر القطاعي', 'رصيد أول المدة'])
      TextCellValue(h)]);
    void row(String code, String name, String cat, String unit, int cost, int retail, num opening) => s.appendRow([
          TextCellValue(code),
          TextCellValue(name),
          TextCellValue(cat),
          TextCellValue(unit),
          IntCellValue(cost),
          IntCellValue(retail),
          opening is int ? IntCellValue(opening) : DoubleCellValue(opening.toDouble()),
        ]);
    row('P01', 'خلاط حوض جروهي كروم', 'خلاطات', 'قطعة', 100, 150, 10);
    row('P02', 'حوض معلق إيديال ستاندرد أبيض', 'أحواض', 'قطعة', 200, 300, 5);
    for (var i = 3; i <= 39; i++) {
      row('P${i.toString().padLeft(2, '0')}', 'صنف تجريبي رقم $i', 'متنوع', 'قطعة', 100 + i, 150 + i, 4);
    }
    row('P40', 'ماسورة بولي بروبلين 25 مم', 'مواسير', 'متر', 10, 20, 100);
    return excel.encode()!;
  }

  test('the plan\'s manual test script, start to finish', () async {
    var db = open();
    final auth = AuthService(db, hasher: const PasswordHasher(iterations: 1));
    final admin = await auth.firstRunSetup(
      company: const CompanyInfo(name: 'معرض الاختبار', address: 'المنصورة', phone: '0100'),
      fullName: 'المدير',
      username: 'admin',
      password: '1234',
    );
    final cashier = await auth.addUser(
        fullName: 'الكاشير', username: 'cashier', password: '1234', role: UserRole.cashier, by: admin);

    // 1. Import products.
    final imports = ImportService(db);
    final preview = await imports.preview(ImportKind.products, productSheet());
    expect(preview.errorCount, 0, reason: preview.rows.expand((r) => r.errors).join(' | '));
    expect(await imports.import(preview, user: admin), 40);
    final byCode = {for (final pr in await db.select(db.products).get()) pr.code: pr.id};

    // 2. Two suppliers, two prices, one on credit.
    final parties = PartyService(db);
    final supplierA = await parties.saveSupplier(const SupplierInput(name: 'مورد أ'));
    final supplierB = await parties.saveSupplier(const SupplierInput(name: 'مورد ب'));
    final purchases = PurchaseService(db);
    await purchases.post(
      PurchaseInput(
        supplierId: supplierA,
        lines: [PurchaseLineInput(productId: byCode['P01']!, qty: qtyOf(10), unitCost: 12000)],
        paidAmount: 120000,
      ),
      user: admin,
    );
    await purchases.post(
      PurchaseInput(supplierId: supplierB, lines: [PurchaseLineInput(productId: byCode['P02']!, qty: qtyOf(10), unitCost: 18000)]),
      user: admin,
    );

    // 3. Cash, credit and partial sales. Typed prices need the admin; a
    // cashier selling from a price list is in pricing_policy_test.
    final c1 = await parties.saveCustomer(const CustomerInput(name: 'عميل آجل'));
    final c2 = await parties.saveCustomer(const CustomerInput(name: 'مقاول', priceLevel: 'contractor'));
    final sales = SalesService(db);
    final s1 = await sales.post(
      SaleInput(lines: [SaleLineInput(productId: byCode['P01']!, qty: qtyOf(2), unitPrice: 15000)], paidAmount: 30000),
      userId: admin.id,
    );
    final s2 = await sales.post(
      SaleInput(customerId: c1, lines: [SaleLineInput(productId: byCode['P02']!, qty: qtyOf(3), unitPrice: 30000)]),
      userId: admin.id,
    );
    await sales.post(
      SaleInput(
        customerId: c2,
        lines: [
          SaleLineInput(productId: byCode['P40']!, qty: 12500, unitPrice: 2000),
          SaleLineInput(productId: byCode['P01']!, qty: qtyOf(1), unitPrice: 15000),
        ],
        paidAmount: 10000,
      ),
      userId: admin.id,
    );

    // 4. One cheque clears, one bounces.
    final payments = PaymentService(db);
    Future<int> cheque(int amount, String no, {int? invoiceId}) async {
      final pay = await payments.receive(
        PaymentInput(
          partyId: c1,
          amount: amount,
          method: PaymentMethod.cheque,
          cheque: ChequeInput(number: no, dueDate: DateTime.now().add(const Duration(days: 3))),
          invoiceId: invoiceId,
        ),
        userId: admin.id,
      );
      return (await (db.select(db.cheques)..where((t) => t.paymentId.equals(pay.id))).getSingle()).id;
    }

    await payments.clearCheque(await cheque(50000, 'CH-1', invoiceId: s2.id), user: admin);
    await payments.bounceCheque(await cheque(30000, 'CH-2'), reason: 'رصيد غير كاف', user: admin);

    // 5. A return from a sold invoice.
    await ReturnService(db).postSaleReturn(
      ReturnInput(
        originalInvoiceId: s2.id,
        lines: [ReturnLineInput(productId: byCode['P02']!, qty: qtyOf(1), unitPrice: 30000)],
      ),
      user: cashier,
    );

    // 6. The admin cancels an invoice; the cashier cannot.
    final s4 = await sales.post(
      SaleInput(customerId: c2, lines: [SaleLineInput(productId: byCode['P01']!, qty: qtyOf(1), unitPrice: 15000)]),
      userId: admin.id,
    );
    await sales.cancel(s4.id, reason: 'خطأ في العميل', user: admin);
    await expectLater(sales.cancel(s1.id, reason: 'x', user: cashier), throwsA(isA<ValidationException>()));

    // 7. Three expenses.
    final expenses = ExpenseService(db);
    final cats = {for (final c in await db.select(db.expenseCategories).get()) c.nameAr: c.id};
    for (final (cat, amount) in [('إيجار', 100000), ('نقل ومشال', 20000), ('نثريات', 5000)]) {
      await expenses.add(ExpenseInput(categoryId: cats[cat]!, amount: amount), user: admin);
    }

    // Balances and stock against the hand calculation.
    final balances = BalanceService(db);
    expect(await balances.customerBalance(c1), 10000);
    expect(await balances.customerBalance(c2), 30000);
    expect(await balances.supplierBalance(supplierA), 0);
    expect(await balances.supplierBalance(supplierB), 180000);
    final stock = StockService(db);
    expect(await stock.currentStock(byCode['P01']!), qtyOf(17));
    expect(await stock.currentStock(byCode['P02']!), qtyOf(13));
    expect(await stock.currentStock(byCode['P40']!), 87500);

    // 9. Every report total against the hand calculation.
    final reports = ReportService(db);
    final today = DateTime.now();
    final daily = await reports.dailySales(from: today, to: today);
    expect(daily.totals.sublist(1), [3, 160000, 30000, 130000]);
    final profit = {for (final r in (await reports.profit(from: today, to: today)).rows) r[0]: r[1]};
    expect(profit['تكلفة البضاعة المباعة'], -102500);
    expect(profit['تكلفة البضاعة المرتجعة'], 20000);
    expect(profit['مجمل الربح'], 47500);
    expect(profit['المصروفات'], -125000);
    expect(profit['صافي الربح'], -77500);
    expect((await reports.expensesByCategory(from: today, to: today)).total('المبلغ'), 125000);
    expect((await reports.customersOwing()).total('الرصيد'), 40000);
    expect((await reports.supplierBalances()).total('الرصيد'), 180000);
    expect((await reports.stockValuation()).total('القيمة'), 2308300);
    expect((await reports.salesByCustomer(from: today, to: today)).total('الصافي'), 130000);

    // 8. Printing: the invoice, the statement and a receipt build.
    final fonts = PdfFonts.fromBytes(
      regular: ByteData.sublistView(File('assets/fonts/Cairo-Regular.ttf').readAsBytesSync()),
      bold: ByteData.sublistView(File('assets/fonts/Cairo-Bold.ttf').readAsBytesSync()),
    );
    const company = PrintCompany(name: 'معرض الاختبار');
    for (final pdf in [
      await salesInvoicePdf(await sales.detail(s2.id), company, fonts),
      await tablePdf(statementTable(await StatementService(db).customer(c1), isCustomer: true), company, fonts),
      await receiptPdf(
        ReceiptData(number: 'R-1', date: today, received: true, partyName: 'عميل آجل', amount: 50000, method: 'cheque'),
        company,
        fonts,
      ),
    ]) {
      expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    }

    // 10. Back up, make a mistake, restore, and the mistake is gone.
    final actions = BackupActions(db: db, backups: backups, databaseFile: dbFile);
    final backup = await actions.backupNow(userId: admin.id);
    await sales.post(
      SaleInput(customerId: c2, lines: [SaleLineInput(productId: byCode['P02']!, qty: qtyOf(5), unitPrice: 30000)]),
      userId: admin.id,
    );
    expect(await balances.customerBalance(c2), 180000);
    await actions.restore(backup, userId: admin.id);
    await db.close();
    expect(await BackupService.applyPendingRestore(dbFile), isTrue);

    // 11. Close and reopen: the restored data, intact.
    db = open();
    expect(await db.integrityOk(), isTrue);
    expect(await BalanceService(db).customerBalance(c2), 30000);
    expect(await StockService(db).currentStock(byCode['P02']!), qtyOf(13));
    expect((await db.select(db.salesInvoices).get()).length, 4);
    await db.close();
  });

  group('edge cases from the plan', () {
    late AppDatabase db;
    late User admin;
    late int productId;
    late int customerId;

    setUp(() async {
      db = open();
      admin = await AuthService(db, hasher: const PasswordHasher(iterations: 1)).firstRunSetup(
        company: const CompanyInfo(name: 'x'),
        fullName: 'المدير',
        username: 'admin',
        password: '1234',
      );
      await SettingsService(db).setBool(SettingKey.allowNegativeStock, true);
      productId = await db.into(db.products).insert(ProductsCompanion.insert(code: 'A', nameAr: 'خلاط'));
      customerId = await PartyService(db).saveCustomer(const CustomerInput(name: 'عميل'));
    });

    tearDown(() => db.close());

    SaleInput sale({int qty = 1000, int price = 10000}) => SaleInput(
          customerId: customerId,
          lines: [SaleLineInput(productId: productId, qty: qty, unitPrice: price)],
        );

    test('two invoices saved in quick succession get consecutive numbers', () async {
      final sales = SalesService(db);
      final both = await Future.wait([sales.post(sale(), userId: admin.id), sales.post(sale(), userId: admin.id)]);
      expect(both.map((i) => i.number).toSet(), {'S-000001', 'S-000002'});
    });

    test('zero quantity is refused; zero price is allowed; below cost needs a manager reason', () async {
      final sales = SalesService(db);
      await expectLater(sales.post(sale(qty: 0), userId: admin.id), throwsA(isA<ValidationException>()));
      expect((await sales.post(sale(price: 0), userId: admin.id)).total, 0);
      // Stock arrives at a cost of 500.00, ahead of anything else in FIFO order.
      await FifoService(db).addLayer(
        productId: productId,
        qty: 5000,
        unitCost: 50000,
        receivedAt: DateTime(2000),
      );
      await expectLater(sales.post(sale(price: 100), userId: admin.id), throwsA(isA<BelowCostException>()));
      expect(
        (await sales.post(sale(price: 100), userId: admin.id, belowCostReason: 'تصفية')).total,
        100,
      );
    });

    test('a very long Arabic product name still prints', () async {
      await (db.update(db.products)..where((t) => t.id.equals(productId))).write(ProductsCompanion(
            nameAr: Value('طقم حمام كامل ${'بالملحقات والتركيبات والخلاطات ' * 8}'),
          ));
      final inv = await SalesService(db).post(sale(), userId: admin.id);
      final fonts = PdfFonts.fromBytes(
        regular: ByteData.sublistView(File('assets/fonts/Cairo-Regular.ttf').readAsBytesSync()),
        bold: ByteData.sublistView(File('assets/fonts/Cairo-Bold.ttf').readAsBytesSync()),
      );
      final pdf = await salesInvoicePdf(await SalesService(db).detail(inv.id), const PrintCompany(name: 'x'), fonts);
      expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    });

    test('a sale dated earlier (clock set back) keeps numbering and balances right', () async {
      final sales = SalesService(db);
      await sales.post(sale(), userId: admin.id);
      final back = SaleInput(
        customerId: customerId,
        date: DateTime.now().subtract(const Duration(days: 30)),
        lines: [SaleLineInput(productId: productId, qty: 1000, unitPrice: 10000)],
      );
      expect((await sales.post(back, userId: admin.id)).number, 'S-000002');
      expect(await BalanceService(db).customerBalance(customerId), 20000);
      final statement = await StatementService(db).customer(customerId);
      expect(statement.entries.first.date.isBefore(statement.entries.last.date), isTrue); // sorted by date
      expect(statement.closingBalance, 20000);
    });
  });
}
