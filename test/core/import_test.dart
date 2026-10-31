import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/import_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';

import '../support/fixture.dart';

/// Builds an .xlsx the way a client's own sheet might look.
List<int> sheet(List<List<Object?>> rows) {
  final excel = Excel.createExcel();
  final s = excel[excel.getDefaultSheet()!];
  for (final r in rows) {
    s.appendRow([
      for (final v in r)
        switch (v) {
          null => null,
          int i => IntCellValue(i),
          double d => DoubleCellValue(d),
          _ => TextCellValue('$v'),
        },
    ]);
  }
  return excel.encode()!;
}

void main() {
  late Shop shop;
  late ImportService imports;

  setUp(() async {
    shop = await Shop.open();
    imports = ImportService(shop.db);
  });

  tearDown(() => shop.close());

  group('products', () {
    test('valid rows import with opening stock, new categories and brands', () async {
      final bytes = sheet([
        ['كود', 'اسم الصنف', 'التصنيف', 'الماركة', 'الوحدة', 'سعر التكلفة', 'سعر القطاعي', 'حد الطلب', 'رصيد أول المدة'],
        ['G-100', 'خلاط حوض جروهي', 'خلاطات', 'Grohe', 'قطعة', 950, 1250.5, 2, 6],
        ['PPR-20', 'ماسورة ٢٠ مم', 'مواسير', null, 'متر', 18.75, 35.1, null, 120.5],
        [null, null, null, null, null, null, null, null, null], // blank line is skipped
        ['G-101', 'خلاط مطبخ', 'خلاطات', 'grohe', null, null, '1,100', null, null],
      ]);
      final preview = await imports.preview(ImportKind.products, bytes);
      expect(preview.missingColumns, isEmpty);
      expect(preview.rows, hasLength(3));
      expect(preview.errorCount, 0, reason: preview.rows.expand((r) => r.errors).join(' | '));

      expect(await imports.import(preview, user: shop.admin), 3);
      final rows = await ProductService(shop.db).watchList(search: 'G-100').first;
      expect(rows.single.product.priceRetail, 125050);
      expect(rows.single.product.costPrice, 95000);
      expect(rows.single.stock, qtyOf(6));
      expect(rows.single.categoryName, 'خلاطات');
      final pipe = (await ProductService(shop.db).watchList(search: 'PPR-20').first).single;
      expect(pipe.stock, 120500);
      expect(pipe.product.priceRetail, 3510);
      expect(pipe.unitName, 'متر');
      // Same category and brand (any letter case) were created once.
      expect(await shop.db.select(shop.db.categories).get(), hasLength(2));
      expect(await shop.db.select(shop.db.brands).get(), hasLength(1));
      final opening = (await shop.db.select(shop.db.stockMovements).get()).where((m) => m.type == StockMovementType.opening);
      expect(opening, hasLength(2));
    });

    test('problems are listed per row and only good rows import', () async {
      final bytes = sheet([
        ['الكود', 'الاسم', 'الوحدة', 'سعر القطاعي', 'رصيد أول المدة'],
        ['M1', 'موجود من قبل', null, 10, null], // M1 is the fixture's mixer
        ['A1', '', null, 10, null],
        ['A2', 'خلاط', 'كيلو', 10, null],
        ['A3', 'حوض', 'قطعة', 'abc', 1.5],
        ['A4', 'قاعدة', null, 10, null],
        ['A4', 'قاعدة مكررة', null, 10, null],
      ]);
      final preview = await imports.preview(ImportKind.products, bytes);
      final errors = {for (final r in preview.rows) r.rowNumber: r.errors.join(' | ')};
      expect(errors[2], contains('موجود'));
      expect(errors[3], contains('الاسم فارغ'));
      expect(errors[4], contains('الوحدة'));
      expect(errors[5], allOf(contains('سعر القطاعي'), contains('رصيد أول المدة')));
      expect(errors[6], isEmpty);
      expect(errors[7], contains('مكرر'));
      expect(preview.okCount, 1);
      expect(await imports.import(preview, user: shop.admin), 1);
    });

    test('a sheet without the code column cannot be imported', () async {
      final preview = await imports.preview(ImportKind.products, sheet([['الاسم', 'السعر'], ['خلاط', 10]]));
      expect(preview.missingColumns, ['الكود']);
      expect(preview.canImport, isFalse);
      await expectLater(imports.import(preview, user: shop.admin), throwsA(isA<ValidationException>()));
    });
  });

  test('customers: price levels, phones without the leading zero, duplicates', () async {
    final bytes = sheet([
      ['اسم العميل', 'التليفون', 'العنوان', 'رصيد أول المدة', 'حد الائتمان', 'فئة السعر'],
      ['شركة الأمل للمقاولات', 1001234567, 'المنصورة', 2500, 10000, 'مقاولين'],
      ['أحمد علي', '0111222333', null, -150, null, 'جملة'],
      ['عميل', null, null, null, null, null], // the fixture already has "عميل"
      ['محمود', null, null, null, null, 'vip'],
    ]);
    final preview = await imports.preview(ImportKind.customers, bytes);
    expect(preview.okCount, 2);
    expect(preview.rows[2].errors.single, contains('موجود'));
    expect(preview.rows[3].errors.single, contains('فئة السعر'));
    await imports.import(preview, user: shop.admin);
    final all = await shop.db.select(shop.db.customers).get();
    final amal = all.firstWhere((c) => c.name.startsWith('شركة'));
    expect(amal.phone, '01001234567');
    expect(amal.priceLevel, PriceLevel.contractor);
    expect(amal.openingBalance, 250000);
    expect(amal.creditLimit, 1000000);
    expect(all.firstWhere((c) => c.name == 'أحمد علي').openingBalance, -15000);
  });

  test('suppliers', () async {
    final preview = await imports.preview(
      ImportKind.suppliers,
      sheet([
        ['اسم المورد', 'التليفون', 'رصيد أول المدة'],
        ['ايديال ستاندرد', '0225551234', 50000],
      ]),
    );
    expect(await imports.import(preview, user: shop.admin), 1);
    expect((await shop.db.select(shop.db.suppliers).get()).last.openingBalance, 5000000);
  });

  test('the template has the expected headers and reads back cleanly', () async {
    for (final kind in ImportKind.values) {
      final preview = await imports.preview(kind, imports.template(kind));
      expect(preview.missingColumns, isEmpty, reason: kind.title);
      expect(preview.rows, isEmpty);
    }
  });

  test('cashier cannot import; a broken file is refused', () async {
    final preview = await imports.preview(ImportKind.suppliers, sheet([['اسم المورد'], ['x']]));
    await expectLater(imports.import(preview, user: shop.cashier), throwsA(isA<ValidationException>()));
    await expectLater(imports.preview(ImportKind.suppliers, [1, 2, 3]), throwsA(isA<ValidationException>()));
  });
}
