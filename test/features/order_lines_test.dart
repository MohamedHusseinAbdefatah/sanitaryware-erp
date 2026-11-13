@Timeout(Duration(seconds: 120))
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/auth/session.dart';
import 'package:sanitaryware_erp/core/providers.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/features/purchases/purchase_orders_dialog.dart';
import 'package:sanitaryware_erp/features/sales/sales_orders_dialog.dart';

import '../support/fixture.dart';

/// New quotations, sales orders and purchase orders take any number of
/// products, as the invoice does: the search clears after each pick, and
/// picking a product again adds one more of it.
void main() {
  late Shop shop;

  setUp(() async => shop = await Shop.open());
  tearDown(() => shop.close());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(WidgetTester tester, Future<void> Function(BuildContext) show) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(shop.db),
        currentUserProvider.overrideWith((ref) => shop.admin),
      ],
      child: MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: Builder(builder: (context) => TextButton(onPressed: () => show(context), child: const Text('open'))),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  /// Types into the product search and picks the first match.
  Future<void> pick(WidgetTester tester, String text, String option) async {
    final field = find.descendant(of: find.byType(Dialog).last, matching: find.byType(TextField)).first;
    await tester.enterText(field, text);
    await settle(tester);
    await tester.tap(find.textContaining(option).last);
    await settle(tester);
    // The search is empty again, ready for the next product.
    expect(tester.widget<TextField>(find.descendant(of: find.byType(Dialog).last, matching: find.byType(TextField)).first)
        .controller!.text, isEmpty);
  }

  Future<void> choose(WidgetTester tester, String label, String item) async {
    await tester.tap(find.widgetWithText(DropdownButtonFormField<int>, label));
    await settle(tester);
    await tester.tap(find.text(item).last);
    await settle(tester);
  }

  testWidgets('a quotation takes several products', (tester) async {
    await open(tester, (c) => showNewSalesOrder(c, quotation: true));
    expect(find.text('عرض سعر جديد'), findsOneWidget);
    await choose(tester, 'العميل', 'عميل');
    await pick(tester, 'خلاط', 'M1 — خلاط');
    await pick(tester, 'ماسورة', 'P1 — ماسورة');
    await pick(tester, 'M1', 'M1 — خلاط');
    expect(find.text('2 صنف'), findsOneWidget);
    await tester.tap(find.text('حفظ كمسودة'));
    await settle(tester);

    final orders = await shop.db.select(shop.db.salesOrders).get();
    expect(orders, hasLength(1));
    final lines = await shop.db.select(shop.db.salesOrderLines).get();
    expect({for (final l in lines) l.productId: l.qty}, {shop.mixer.id: qtyOf(2), shop.pipe.id: qtyOf(1)});
  });

  testWidgets('a purchase order takes several products', (tester) async {
    await open(tester, showNewPurchaseOrder);
    await choose(tester, 'المورد', 'مورد');
    await pick(tester, 'خلاط', 'M1 — خلاط');
    await pick(tester, 'ماسورة', 'P1 — ماسورة');
    expect(find.text('2 صنف'), findsOneWidget);
    await tester.tap(find.text('حفظ كمسودة'));
    await settle(tester);

    final lines = await shop.db.select(shop.db.purchaseOrderLines).get();
    expect({for (final l in lines) l.productId: l.qty}, {shop.mixer.id: qtyOf(1), shop.pipe.id: qtyOf(1)});
  });
}
