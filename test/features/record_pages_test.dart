@Timeout(Duration(seconds: 120))
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/auth/session.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/providers.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/payment_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/features/parties/customer_page.dart';
import 'package:sanitaryware_erp/features/parties/supplier_page.dart';
import 'package:sanitaryware_erp/features/products/product_page.dart';

import '../support/fixture.dart';

/// The record pages of a supplier, a customer and a product open at the
/// smallest window with no overflow and show their figures and history.
void main() {
  late Shop shop;

  setUp(() async {
    shop = await Shop.open();
    await PurchaseService(shop.db).post(
      PurchaseInput(
        supplierId: shop.supplierId,
        supplierInvoiceNo: 'INV-77',
        lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(10), unitCost: 30000)],
        paidAmount: 100000,
      ),
      user: shop.admin,
    );
    await SalesService(shop.db).post(
      SaleInput(
        customerId: shop.customerId,
        lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(2), unitPrice: 50000, priceListId: shop.priceListId)],
        paidAmount: 40000,
      ),
      userId: shop.admin.id,
    );
    await PaymentService(shop.db).receive(PaymentInput(partyId: shop.customerId, amount: 10000), userId: shop.admin.id);
  });
  tearDown(() => shop.close());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pump(WidgetTester tester, Widget child, {required User user}) async {
    tester.view.physicalSize = const Size(1100, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(shop.db),
        currentUserProvider.overrideWith((ref) => user),
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

  testWidgets('supplier page: balance, purchases and payments', (tester) async {
    await pump(tester, SupplierPage(supplierId: shop.supplierId), user: shop.admin);
    expect(find.text('مورد'), findsWidgets);
    expect(find.text('إجمالي المشتريات'), findsOneWidget);
    expect(find.text('3,000.00'), findsWidgets, reason: 'the purchase total');
    expect(find.text('INV-77'), findsOneWidget);
    expect(find.text('مدفوعة جزئياً'), findsOneWidget);
    await tester.tap(find.text('المدفوعات'));
    await settle(tester);
    expect(find.text('1,000.00'), findsWidgets);
    await unmount(tester);
  });

  testWidgets('customer page: balance, credit and invoices', (tester) async {
    await pump(tester, CustomerPage(customerId: shop.customerId), user: shop.admin);
    expect(find.text('حد الائتمان'), findsWidgets);
    expect(find.text('500.00'), findsWidgets, reason: 'balance: 1,000 - 400 - 100');
    expect(find.text('قطاعي'), findsWidgets);
    await tester.tap(find.text('المدفوعات'));
    await settle(tester);
    expect(find.text('تحت الحساب'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('product page: stock, places, purchases and sales', (tester) async {
    await pump(tester, ProductPage(productId: shop.mixer.id), user: shop.admin);
    expect(find.text('8 قطعة'), findsWidgets, reason: '10 bought, 2 sold');
    expect(find.text('المخزون حسب المكان'), findsOneWidget);
    await tester.tap(find.text('المبيعات'));
    await settle(tester);
    expect(find.text('عميل'), findsOneWidget);
    await tester.tap(find.text('حركة المخزون'));
    await settle(tester);
    expect(find.text('+10'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a cashier sees no purchases or costs on the product page', (tester) async {
    await pump(tester, ProductPage(productId: shop.mixer.id), user: shop.cashier);
    expect(find.text('آخر تكلفة شراء'), findsNothing);
    expect(find.text('المشتريات'), findsNothing);
    expect(find.text('تعديل والصورة'), findsNothing);
    await unmount(tester);
  });
}
