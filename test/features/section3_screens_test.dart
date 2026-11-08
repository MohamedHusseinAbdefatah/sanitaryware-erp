@Timeout(Duration(seconds: 120))
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/auth/session.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/providers.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/sale_preview_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/features/price_lists/price_lists_screen.dart';
import 'package:sanitaryware_erp/features/products/product_form_dialog.dart';
import 'package:sanitaryware_erp/features/sales/sale_preview_dialog.dart';

import '../support/fixture.dart';

/// The Section 3 screens open and lay out at the smallest window, with no
/// overflow, and show what the blueprint asks for.
void main() {
  late Shop shop;

  setUp(() async => shop = await Shop.open());
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

  testWidgets('price lists: versions, review, buying and selling tabs, and their dialogs', (tester) async {
    await pump(tester, const PriceListsScreen(), user: shop.admin);
    expect(find.textContaining('PL-${shop.priceListId}'), findsOneWidget);
    expect(find.textContaining('الضريبة غير متحقق منها'), findsOneWidget);

    await tester.tap(find.text('استيراد قائمة كاملة'));
    await settle(tester);
    expect(find.text('استيراد قائمة كاملة (إصدار جديد)'), findsOneWidget);
    expect(find.text('حفظ الإصدار'), findsOneWidget);
    await tester.tap(find.text('إلغاء'));
    await settle(tester);

    await tester.tap(find.text('استيراد من PDF'));
    await settle(tester);
    expect(find.text('استيراد قائمة من ملف PDF (إصدار جديد)'), findsOneWidget);
    expect(find.text('اختر ملف PDF'), findsOneWidget);
    await tester.tap(find.text('إلغاء'));
    await settle(tester);

    await tester.tap(find.text('إدخال صنف أو مجموعة أصناف'));
    await settle(tester);
    expect(find.text('سعر القائمة'), findsOneWidget);
    await tester.tap(find.text('إلغاء'));
    await settle(tester);

    await tester.tap(find.text('قيد المراجعة'));
    await settle(tester);
    expect(find.text('لا توجد صفوف متوقفة للمراجعة'), findsOneWidget);

    await tester.tap(find.text('سياسات الشراء'));
    await settle(tester);
    await tester.tap(find.text('سياسة شراء'));
    await settle(tester);
    expect(find.text('الخصم الأساسي %'), findsOneWidget);
    await tester.tap(find.text('إلغاء'));
    await settle(tester);

    await tester.tap(find.text('سياسات البيع'));
    await settle(tester);
    await tester.tap(find.text('سياسة بيع'));
    await settle(tester);
    expect(find.text('أقصى خصم بدون موافقة % (اختياري)'), findsOneWidget);
    await tester.tap(find.text('إلغاء'));
    await settle(tester);
    await unmount(tester);
  });

  testWidgets('the product form has every master field and no price', (tester) async {
    await pump(tester, const ProductFormDialog(), user: shop.admin);
    for (final label in [
      'رقم الصنف (Product ID)',
      'كود الشركة (Manufacturer Code)',
      'الوصف',
      'التصنيف الفرعي',
      'السلسلة (Series)',
      'اللون / Variant',
      'التشطيب (Finish)',
      'المقاسات',
      'الباركود',
      'المواصفات الفنية',
      'أساس الضريبة (بعد التحقق)',
      'التكلفة الفعلية للوحدة',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('قطاعي'), findsNothing);
    await unmount(tester);
  });

  Future<SalePreview> previewOfSale() async {
    await PurchaseService(shop.db).post(
      PurchaseInput(
        supplierId: shop.supplierId,
        lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(3), unitCost: 30000)],
      ),
      user: shop.admin,
    );
    return SalePreviewService(shop.db).preview(SaleInput(
      lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000, priceListId: shop.priceListId)],
      paidAmount: 50000,
    ));
  }

  testWidgets('before approval the admin sees cost and profit; the cashier does not', (tester) async {
    late SalePreview preview;
    await tester.runAsync(() async => preview = await previewOfSale());

    Future<void> open(User user) async {
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showSalePreview(context, preview, isAdmin: user.role == 'admin'),
            child: const Text('open'),
          ),
        ),
        user: user,
      );
      await tester.tap(find.text('open'));
      await settle(tester);
    }

    await open(shop.admin);
    expect(find.text('تكلفة FIFO المتوقعة'), findsOneWidget);
    expect(find.text('مجمل الربح'), findsOneWidget);
    expect(find.text('الهامش (من البيع)'), findsOneWidget);
    expect(find.text('Markup (من التكلفة)'), findsOneWidget);
    expect(find.text('السعر النهائي للوحدة'), findsOneWidget);
    expect(find.text('الضريبة'), findsOneWidget);
    await unmount(tester);

    await open(shop.cashier);
    expect(find.text('سعر القائمة'), findsOneWidget);
    expect(find.text('تكلفة FIFO المتوقعة'), findsNothing);
    expect(find.text('مجمل الربح'), findsNothing);
    await unmount(tester);
  });
}
