@Timeout(Duration(seconds: 90))
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/app.dart';
import 'package:sanitaryware_erp/core/auth/auth_service.dart';
import 'package:sanitaryware_erp/core/auth/password_hasher.dart';
import 'package:sanitaryware_erp/core/auth/session.dart';
import 'package:sanitaryware_erp/core/backup/backup_service.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/l10n/strings.dart';
import 'package:sanitaryware_erp/core/providers.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/catalog_service.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/settings_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';

void main() {
  late AppDatabase db;
  late User admin;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  /// Alternates real time (for drift's queries) with frames. pumpAndSettle
  /// would wait forever while a loading spinner is on screen.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.runAsync(() async {
      admin = await AuthService(db, hasher: const PasswordHasher(iterations: 1)).firstRunSetup(
        company: const CompanyInfo(name: 'معرض'),
        fullName: 'المدير',
        username: 'admin',
        password: '1234',
      );
      final pieceId = (await db.select(db.units).get()).first.id;
      final brand = await CatalogService(db).saveBrand(name: 'ماركة');
      final mixer = await ProductService(db).create(
        ProductInput(
          code: 'M1',
          manufacturerCode: 'M1',
          nameAr: 'خلاط حوض',
          brandId: brand,
          unitId: pieceId,
        ),
        openingQty: qtyOf(5),
        openingCost: 40000,
      );
      await PriceListService(db).createVersion(
        PriceListHeader(name: 'قائمة', brandId: brand, listType: 'عام', effectiveFrom: DateTime(2020)),
        rows: [PriceRowInput(name: 'خلاط حوض', price: 50000, productId: mixer.id)],
        user: admin,
      );
    });
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          databaseFileProvider.overrideWithValue(File('unused.sqlite')),
          backupServiceProvider.overrideWithValue(BackupService(dir: Directory('unused'))),
          setupNeededProvider.overrideWith((ref) => false),
          currentUserProvider.overrideWith((ref) => admin),
        ],
        child: const App(),
      ),
    );
    await settle(tester);
  }

  testWidgets('products screen lists stock', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text(Strings.products));
    await settle(tester);
    expect(find.text('خلاط حوض'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^5( |$)')), findsOneWidget);
    // Unmount so drift's stream queries close before the database does.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero); // drift closes its streams on a zero timer
  });

  testWidgets('the inventory shows what is held, not the whole catalogue', (tester) async {
    await pumpApp(tester);
    // A product loaded from a price list and never bought.
    await tester.runAsync(() async {
      await ProductService(db).create(const ProductInput(code: 'B9', manufacturerCode: 'B9', nameAr: 'حوض غير مشترى'));
    });
    tester.view.physicalSize = const Size(1100, 700); // the smallest window
    await tester.tap(find.text(Strings.inventory));
    await settle(tester);
    expect(find.text('خلاط حوض'), findsOneWidget);
    expect(find.text('حوض غير مشترى'), findsNothing);
    expect(find.text('أصناف في المخزون'), findsOneWidget);
    // The catalogue still lists both.
    await tester.tap(find.text(Strings.products));
    await settle(tester);
    expect(find.text('خلاط حوض'), findsOneWidget);
    expect(find.text('حوض غير مشترى'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero);
  });

  testWidgets('a cash sale entered on screen is saved and reduces stock', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text(Strings.sales));
    await settle(tester);
    await tester.tap(find.text(Strings.newInvoice));
    await settle(tester);

    // Type the code and press Enter to add the line.
    await tester.enterText(find.byType(TextField).at(1), 'M1');
    await settle(tester);
    expect(find.textContaining('M1 — خلاط حوض'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);

    // Quantity 2 (the field is focused and selected after adding).
    await tester.enterText(find.widgetWithText(TextFormField, '1'), '2');
    await settle(tester);
    expect(find.text('1,000.00'), findsWidgets); // line total and invoice total

    await tester.tap(find.text('${Strings.save} (Ctrl+S)'));
    await settle(tester);
    // Everything is shown before approval; then it saves.
    expect(find.text('سعر القائمة'), findsWidgets);
    expect(find.text('تكلفة FIFO المتوقعة'), findsOneWidget);
    await tester.tap(find.text('اعتماد وحفظ'));
    await settle(tester);

    expect(find.textContaining('S-000001'), findsWidgets);
    final invoice = await tester.runAsync(() => db.select(db.salesInvoices).getSingle());
    expect(invoice!.total, 100000);
    expect(invoice.paidAmount, 100000);
    final stock = await tester.runAsync(() => StockService(db).currentStock(1));
    expect(stock, qtyOf(3));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(Duration.zero); // drift closes its streams on a zero timer
  });
}
