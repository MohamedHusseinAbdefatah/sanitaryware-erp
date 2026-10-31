@Timeout(Duration(seconds: 120))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/app.dart';
import 'package:sanitaryware_erp/core/auth/session.dart';
import 'package:sanitaryware_erp/core/backup/backup_service.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/l10n/strings.dart';
import 'package:sanitaryware_erp/core/providers.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/payment_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/features/shell/sections.dart';

import '../support/fixture.dart';

void main() {
  late Shop shop;

  setUp(() async {
    shop = await Shop.open();
  });

  tearDown(() => shop.close());

  /// Alternates real time (for drift's queries) with frames. pumpAndSettle
  /// would wait forever while a loading spinner is on screen.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The smallest window the app allows (see main.dart).
  Future<void> pumpApp(WidgetTester tester, User user) async {
    tester.view.physicalSize = const Size(1100, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(shop.db),
          databaseFileProvider.overrideWithValue(File('unused.sqlite')),
          backupServiceProvider.overrideWithValue(BackupService(dir: Directory('unused'))),
          setupNeededProvider.overrideWith((ref) => false),
          currentUserProvider.overrideWith((ref) => user),
        ],
        child: const App(),
      ),
    );
    await settle(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero); // drift closes its streams on a zero timer
  }

  /// Stock, a credit sale of 2 mixers (1,000.00) to the customer.
  Future<SalesInvoice> creditSale(WidgetTester tester) async {
    return (await tester.runAsync(() async {
      await PurchaseService(shop.db).post(
        PurchaseInput(
          supplierId: shop.supplierId,
          lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(10), unitCost: 40000)],
        ),
        user: shop.admin,
      );
      return SalesService(shop.db).post(
        SaleInput(
          customerId: shop.customerId,
          lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(2), unitPrice: 50000)],
        ),
        userId: shop.admin.id,
      );
    }))!;
  }

  for (final role in ['admin', 'cashier']) {
    testWidgets('every section opens without layout errors ($role)', (tester) async {
      await creditSale(tester);
      await pumpApp(tester, role == 'admin' ? shop.admin : shop.cashier);
      final sidebar = find.byType(SingleChildScrollView).first;
      for (final s in appSections) {
        final entry = find.descendant(of: sidebar, matching: find.text(s.title));
        // Every entry the role may use is on screen; the others are hidden.
        final visible = role == 'admin' || !s.adminOnly;
        expect(entry, visible ? findsOneWidget : findsNothing, reason: s.title);
        if (!visible) continue;
        await tester.ensureVisible(entry);
        await tester.tap(entry);
        await settle(tester);
        expect(tester.takeException(), isNull, reason: s.title);
      }
      await unmount(tester);
    });
  }

  testWidgets('a payment taken from the invoice view settles the balance', (tester) async {
    final invoice = await creditSale(tester);
    await pumpApp(tester, shop.cashier);
    await tester.tap(find.text(Strings.sales).first);
    await settle(tester);
    await tester.tap(find.text(Strings.all));
    await settle(tester);
    await tester.tap(find.text(invoice.number));
    await settle(tester);

    await tester.tap(find.text(Strings.receivePayment));
    await settle(tester);
    // The dialog links the invoice and fills in what is left.
    expect(find.widgetWithText(TextFormField, '1000.00'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, Strings.save));
    await settle(tester);

    expect(find.byType(AlertDialog), findsNothing);
    expect(await tester.runAsync(shop.customerBalance), 0);
    final remaining = await tester.runAsync(() => PaymentService(shop.db)
        .invoiceRemaining(RefType.salesInvoice, invoice.id, partyId: shop.customerId));
    expect(remaining, 0);
    // The view reloads: nothing left to pay, so the button is gone.
    expect(find.text(Strings.receivePayment), findsNothing);
    await unmount(tester);
  });

  testWidgets('a return made from the invoice view brings stock back', (tester) async {
    final invoice = await creditSale(tester);
    await pumpApp(tester, shop.cashier);
    await tester.tap(find.text(Strings.sales).first);
    await settle(tester);
    await tester.tap(find.text(Strings.all));
    await settle(tester);
    await tester.tap(find.text(invoice.number));
    await settle(tester);
    await tester.tap(find.text(Strings.saleReturn));
    await settle(tester);

    expect(find.textContaining('${Strings.canReturn}: 2'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextFormField, Strings.returnQty), '1');
    await settle(tester);
    await tester.tap(find.textContaining(Strings.save));
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(await tester.runAsync(() => shop.stockOf(shop.mixer)), qtyOf(9));
    expect(await tester.runAsync(shop.customerBalance), 50000);
    expect(find.text(Strings.returns), findsWidgets); // back on the returns list
    await unmount(tester);
  });
}
