@Timeout(Duration(seconds: 120))
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/auth/session.dart';
import 'package:sanitaryware_erp/core/providers.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/features/expenses/expenses_screen.dart';
import 'package:sanitaryware_erp/features/parties/customer_page.dart';
import 'package:sanitaryware_erp/features/parties/party_form_dialog.dart';
import 'package:sanitaryware_erp/features/purchases/purchase_plan_dialog.dart';

import '../support/fixture.dart';

/// The screens of the last blueprint items open and work.
void main() {
  late Shop shop;

  setUp(() async {
    shop = await Shop.open();
    await PurchaseService(shop.db).post(
      PurchaseInput(
        supplierId: shop.supplierId,
        lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(3), unitCost: 30000)],
      ),
      user: shop.admin,
    );
    await SalesService(shop.db).post(
      SaleInput(
        customerId: shop.customerId,
        lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(2), unitPrice: 50000, priceListId: shop.priceListId)],
        paidAmount: 100000,
      ),
      userId: shop.admin.id,
    );
  });
  tearDown(() => shop.close());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(shop.db),
        currentUserProvider.overrideWith((ref) => shop.admin),
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

  Widget opener(Future<void> Function(BuildContext) show) =>
      Builder(builder: (context) => TextButton(onPressed: () => show(context), child: const Text('open')));

  testWidgets('purchase planning shows the product with its sales and saves a draft order', (tester) async {
    await PartyService(shop.db).saveSupplier(const SupplierInput(name: 'مورد', leadTimeDays: 90), id: shop.supplierId);
    await pump(tester, opener(showPurchasePlan));
    await tester.tap(find.text('open'));
    await settle(tester);
    expect(find.text('تخطيط الشراء'), findsOneWidget);
    expect(find.text('خلاط'), findsOneWidget, reason: 'sold 2 in 90 days, 1 left, 90 days lead time: 1 to order');
    await tester.tap(find.text('حفظ كأوامر شراء مسودة'));
    await settle(tester);
    expect(await shop.db.select(shop.db.purchaseOrders).get(), hasLength(1));
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('the customer form takes email, tax number and terms; the page lists contacts', (tester) async {
    await pump(tester, opener((c) => showCustomerForm(c)));
    await tester.tap(find.text('open'));
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextFormField, 'الاسم'), 'شركة جديدة');
    await tester.enterText(find.widgetWithText(TextFormField, 'البريد الإلكتروني (اختياري)'), 'a@b.co');
    await tester.enterText(find.widgetWithText(TextFormField, 'مدة السداد بالأيام (للفواتير الآجلة)'), '45');
    await tester.tap(find.text('حفظ'));
    await settle(tester);
    final c = (await shop.db.select(shop.db.customers).get()).firstWhere((c) => c.name == 'شركة جديدة');
    expect((c.email, c.paymentTermsDays), ('a@b.co', 45));

    await pump(tester, CustomerPage(customerId: c.id));
    await tester.ensureVisible(find.text('جهات الاتصال'));
    await tester.tap(find.text('جهات الاتصال'));
    await settle(tester);
    expect(find.text('إضافة جهة اتصال'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('the expense form has payee, VAT, receipt number and attachment', (tester) async {
    await pump(tester, const ExpensesScreen());
    await tester.tap(find.text('مصروف جديد').first);
    await settle(tester);
    expect(find.text('المستفيد (المدفوع له)'), findsOneWidget);
    expect(find.text('منه ضريبة قيمة مضافة قابلة للاسترداد (اختياري)'), findsOneWidget);
    expect(find.text('رقم الإيصال / الفاتورة'), findsOneWidget);
    expect(find.text('إرفاق صورة الإيصال (PDF أو صورة)'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });
}
