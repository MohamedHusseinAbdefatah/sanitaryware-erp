@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sanitaryware_erp/core/auth/auth_service.dart';
import 'package:sanitaryware_erp/core/auth/password_hasher.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/reports/report_service.dart';
import 'package:sanitaryware_erp/core/services/balance_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/settings_service.dart';
import 'package:sanitaryware_erp/core/services/statement_service.dart';

/// A busy year in a real database file, then the things people wait for,
/// each with a time limit. If the shop grows, this is where it would get
/// slow first.
void main() {
  late Directory dir;
  late AppDatabase db;
  late User admin;
  const products = 2000, customers = 500, invoices = 15000, payments = 8000;
  final yearStart = DateTime(2026, 1, 1);

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('erp_perf');
    db = AppDatabase(NativeDatabase(File(p.join(dir.path, 'erp.sqlite'))));
    admin = await AuthService(db, hasher: const PasswordHasher(iterations: 1)).firstRunSetup(
      company: const CompanyInfo(name: 'x'),
      fullName: 'Ø§Ù„Ù…Ø¯ÙŠØ±',
      username: 'admin',
      password: '1234',
    );
    final rnd = Random(7);
    final unit = (await db.select(db.units).get()).first.id;
    await db.batch((b) {
      b.insertAll(db.products, [
        for (var i = 1; i <= products; i++)
          ProductsCompanion.insert(
            code: 'P$i',
            nameAr: 'ØµÙ†Ù Ø±Ù‚Ù… $i Ø®Ù„Ø§Ø· Ø­ÙˆØ¶',
            unitId: Value(unit),
            costPrice: Value(1000 + i),
            priceRetail: Value(1500 + i),
            minStock: Value(i % 7 == 0 ? 50000 : 0),
          ),
      ]);
      b.insertAll(db.stockMovements, [
        for (var i = 1; i <= products; i++)
          StockMovementsCompanion.insert(productId: i, type: 'opening', qty: 1000000, unitCost: Value(1000 + i)),
      ]);
      b.insertAll(db.customers, [
        for (var i = 1; i <= customers; i++) CustomersCompanion.insert(name: 'Ø¹Ù…ÙŠÙ„ Ø±Ù‚Ù… $i', phone: Value('0100$i')),
      ]);
    });
    // Invoices with two lines each and their stock movements.
    for (var start = 0; start < invoices; start += 1000) {
      await db.batch((b) {
        for (var n = start + 1; n <= start + 1000; n++) {
          final date = yearStart.add(Duration(minutes: n * 30));
          final customer = rnd.nextInt(5) == 0 ? null : 1 + rnd.nextInt(customers);
          b.insert(
            db.salesInvoices,
            SalesInvoicesCompanion.insert(
              id: Value(n),
              number: 'S-${n.toString().padLeft(6, '0')}',
              date: date,
              customerId: Value(customer),
              subtotal: 30000,
              total: 30000,
              paidAmount: Value(customer == null ? 30000 : 10000),
            ),
          );
          for (var l = 0; l < 2; l++) {
            final product = 1 + rnd.nextInt(products);
            b.insert(db.salesInvoiceItems, SalesInvoiceItemsCompanion.insert(
              invoiceId: n, productId: product, qty: 1000, unitPrice: 15000, unitCost: const Value(10000), lineTotal: 15000));
            b.insert(db.stockMovements, StockMovementsCompanion.insert(
              productId: product, type: 'sale', qty: -1000, refType: const Value(RefType.salesInvoice), refId: Value(n), date: Value(date)));
          }
        }
      });
    }
    await db.batch((b) {
      b.insertAll(db.payments, [
        for (var i = 1; i <= payments; i++)
          PaymentsCompanion.insert(
            number: 'R-$i',
            date: yearStart.add(Duration(hours: i)),
            direction: PaymentDirection.inbound,
            partyType: PartyType.customer,
            partyId: 1 + rnd.nextInt(customers),
            amount: 10000,
            method: PaymentMethod.cash,
            invoiceRefType: const Value(RefType.salesInvoice),
            invoiceRefId: Value(1 + rnd.nextInt(invoices)),
          ),
      ]);
    });
    await db.customStatement("INSERT INTO app_settings (key_name, val) VALUES ('next_sales_no', '${invoices + 1}')");
  });

  tearDownAll(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  /// Runs [action] and checks it took less than [limitMs].
  Future<T> timed<T>(String what, int limitMs, Future<T> Function() action) async {
    final watch = Stopwatch()..start();
    final result = await action();
    watch.stop();
    // ignore: avoid_print
    print('PERF ${what.padRight(34)} ${watch.elapsedMilliseconds.toString().padLeft(6)} ms (limit $limitMs)');
    expect(watch.elapsedMilliseconds, lessThan(limitMs), reason: what);
    return result;
  }

  test('a busy year stays fast', () async {
    final june = DateTime(2026, 6, 1), juneEnd = DateTime(2026, 6, 30);
    final productsService = ProductService(db);
    final reports = ReportService(db);
    final sales = SalesService(db);

    // At the counter: these must feel instant.
    await timed('product search', 500, () => productsService.search('Ø®Ù„Ø§Ø· 1234'));
    await timed('one customer balance', 300, () => BalanceService(db).customerBalance(42));
    final sale = await timed('save a credit sale', 1000, () => sales.post(
          SaleInput(customerId: 42, lines: [SaleLineInput(productId: 5, qty: 1000, unitPrice: 1500)]),
          userId: admin.id,
        ));
    expect(sale.number, 'S-${(invoices + 1).toString().padLeft(6, '0')}');
    await timed('open one invoice', 300, () => sales.detail(sale.id));

    // Lists and screens.
    await timed('products list with stock', 2000, () => productsService.watchList().first);
    await timed('all customer balances', 2000, () => BalanceService(db).watchCustomerBalances().first);
    await timed('sales list, one month', 1500, () => sales.watchList(from: june, to: juneEnd).first);
    await timed('dashboard', 2000, () => reports.dashboard(now: june));
    await timed('customer statement, whole year', 1500, () => StatementService(db).customer(42));

    // Reports may take a moment, but not long.
    await timed('report: daily sales, year', 3000, () => reports.dailySales(from: yearStart, to: DateTime(2026, 12, 31)));
    await timed('report: sales by product, year', 3000, () => reports.salesByProduct(from: yearStart, to: DateTime(2026, 12, 31)));
    await timed('report: profit, year', 3000, () => reports.profit(from: yearStart, to: DateTime(2026, 12, 31)));
    await timed('report: stock valuation', 3000, () => reports.stockValuation());
    await timed('report: customers owing', 3000, () => reports.customersOwing());
  });
}
