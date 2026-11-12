@Timeout(Duration(seconds: 120))
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/auth/session.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/providers.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/reports/report_service.dart';
import 'package:sanitaryware_erp/core/services/expense_service.dart';
import 'package:sanitaryware_erp/core/services/project_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/return_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/features/accounting/accounting_reports.dart';
import 'package:sanitaryware_erp/features/parties/parties_screen.dart';
import 'package:sanitaryware_erp/features/products/products_screen.dart';
import 'package:sanitaryware_erp/features/sales/sale_entry_screen.dart';

import '../support/fixture.dart';

/// The finishing round: the period-closing tab opens, every report builds,
/// the customer list filters, and the product browser adds to an invoice.
void main() {
  late Shop shop;

  setUp(() async {
    shop = await Shop.open();
    await PurchaseService(shop.db).post(
      PurchaseInput(
        supplierId: shop.supplierId,
        lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(10), unitCost: 30000)],
      ),
      user: shop.admin,
    );
    final sold = await SalesService(shop.db).post(
      SaleInput(
        customerId: shop.customerId,
        lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(3), unitPrice: 50000, priceListId: shop.priceListId)],
        paidAmount: 50000,
      ),
      userId: shop.cashier.id,
    );
    await ReturnService(shop.db).postSaleReturn(
      ReturnInput(
        originalInvoiceId: sold.id,
        lines: [ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000)],
      ),
      user: shop.admin,
    );
    final cat = (await shop.db.select(shop.db.expenseCategories).get()).first;
    await ExpenseService(shop.db).add(ExpenseInput(categoryId: cat.id, amount: 2000), user: shop.admin);
    await ProjectService(shop.db).save(ProjectInput(name: 'موقع', customerId: shop.customerId), user: shop.admin);
  });
  tearDown(() => shop.close());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pump(WidgetTester tester, Widget child, {User? user}) async {
    tester.view.physicalSize = const Size(1100, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(shop.db),
        currentUserProvider.overrideWith((ref) => user ?? shop.admin),
      ],
      child: MaterialApp(
        home: Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: child)),
      ),
    ));
    await settle(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  }

  test('every report builds, the new ones with the right totals', () async {
    final reports = ReportService(shop.db);
    for (final k in ReportKind.values) {
      final t = await reports.build(k, from: DateTime(2000), to: DateTime.now());
      expect(t.title, k.title, reason: k.name);
    }
    final monthly = await reports.monthlySales(from: DateTime(2000), to: DateTime.now());
    expect(monthly.total('الصافي'), 150000 - 50000);
    expect(monthly.total('مجمل الربح'), 100000 - 60000);
    final byProduct = await reports.profitByProduct(from: DateTime(2000), to: DateTime.now());
    expect(byProduct.total('الربح'), 40000);
    final bySupplier = await reports.purchasesBySupplier(from: DateTime(2000), to: DateTime.now());
    expect(bySupplier.total('المشتريات'), 300000);
    final byUser = await reports.salesByUser(from: DateTime(2000), to: DateTime.now());
    expect(byUser.rows.single.first, 'الكاشير');
  });

  testWidgets('period closing opens even when nothing is closed yet', (tester) async {
    await pump(tester, const ClosingTab());
    expect(find.text('لا توجد فترة مقفلة'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await unmount(tester);
  });

  testWidgets('customers list: figures, filters and cards', (tester) async {
    await pump(tester, const CustomersScreen());
    expect(find.text('عملاء نشطون'), findsOneWidget);
    expect(find.text('عميل'), findsWidgets);
    await tester.tap(find.textContaining('عليهم رصيد'));
    await settle(tester);
    expect(find.text('عميل'), findsWidgets);
    await tester.tap(find.byIcon(Icons.grid_view_outlined));
    await settle(tester);
    expect(find.text('آخر تعامل: اليوم'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('products page shows prices and stock states', (tester) async {
    await pump(tester, const ProductsScreen());
    expect(find.text('500.00'), findsOneWidget, reason: 'the mixer list price');
    expect(find.text('بدون سعر بيع ساري'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('the product browser adds a product, and a second tap adds one more', (tester) async {
    await pump(tester, const SaleEntryScreen());
    await tester.tap(find.text('تصفح الأصناف (F3)'));
    await settle(tester);
    expect(find.text('تصفح الأصناف'), findsOneWidget);
    await tester.tap(find.text('خلاط').last);
    await settle(tester);
    await tester.tap(find.text('خلاط').last);
    await settle(tester);
    expect(find.text('× 2'), findsOneWidget);
    await tester.tap(find.text('تم'));
    await settle(tester);
    expect(find.widgetWithText(TextField, '2'), findsOneWidget, reason: 'one line with quantity 2');
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });
}
