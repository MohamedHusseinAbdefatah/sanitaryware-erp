import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/services/catalog_service.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/price_list_import_service.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';

import '../support/fixture.dart';

List<int> _sheet(List<List<Object?>> rows) {
  final excel = Excel.createExcel();
  final sheet = excel[excel.getDefaultSheet()!];
  for (final r in rows) {
    sheet.appendRow([
      for (final c in r)
        switch (c) {
          null => null,
          int v => IntCellValue(v),
          double v => DoubleCellValue(v),
          _ => TextCellValue('$c'),
        },
    ]);
  }
  return excel.encode()!;
}

/// Blueprint 3.2: the two ways in, full list and single or small group.
void main() {
  late Shop shop;
  late PriceListImportService imports;
  late PriceListService lists;
  late ProductService products;
  late int brand;

  setUp(() async {
    shop = await Shop.open();
    imports = PriceListImportService(shop.db);
    lists = PriceListService(shop.db);
    products = ProductService(shop.db);
    brand = await CatalogService(shop.db).saveBrand(name: 'Ideal Standard');
  });
  tearDown(() => shop.close());

  PriceListHeader header({DateTime? from}) => PriceListHeader(
        name: 'قائمة يوليو',
        brandId: brand,
        listType: 'سيراميك',
        effectiveFrom: from ?? DateTime(2026, 7, 1),
        sourceFile: 'july.xlsx',
      );

  group('full list import', () {
    test('known codes get a price, new codes get a Product ID, a new version is made', () async {
      final known = await products.create(ProductInput(nameAr: 'حوض', manufacturerCode: '00123-A', brandId: brand));
      final preview = await imports.preview(
        _sheet([
          ['كود الشركة', 'الاسم', 'السعر', 'المقاسات', 'السلسلة'],
          ['00123-A', 'حوض', '1500', null, null],
          ['00777', 'مرحاض جديد', '3000', '60x40', 'Connect'],
        ]),
        brandId: brand,
      );
      expect(preview.knownCount, 1);
      expect(preview.createCount, 1);
      expect(preview.reviewCount, 0);

      final result = await imports.import(preview, header: header(), user: shop.admin);
      expect(result.matched, 1);
      expect(result.created, 1);
      expect(result.review, 0);

      final fresh = (await products.withMatchKey('00777', brand)).single;
      expect(fresh.manufacturerCode, '00777', reason: 'leading zeros kept');
      expect(fresh.dimensions, '60x40');
      expect(fresh.series, 'Connect');
      expect(fresh.code, isNot('00777'), reason: 'the Product ID is its own number');

      final quotes = await lists.quotesFor(known.id, asOf: DateTime(2026, 8, 1));
      expect(quotes.single.price, 150000);
      expect(quotes.single.priceListId, result.id);
      final saved = await (shop.db.select(shop.db.priceLists)..where((l) => l.id.equals(result.id))).getSingle();
      expect(saved.rowCount, 2);
      expect(saved.sourceFile, 'july.xlsx');
    });

    test('a duplicate row stops for review; nothing is guessed', () async {
      final preview = await imports.preview(
        _sheet([
          ['كود الشركة', 'الاسم', 'السعر'],
          ['A-1', 'حوض', '100'],
          ['a-1 ', 'حوض آخر', '200'],
          ['B-2', 'مرحاض', '300'],
        ]),
        brandId: brand,
      );
      expect(preview.reviewCount, 2);
      expect(preview.createCount, 1);
      final result = await imports.import(preview, header: header(), user: shop.admin);
      expect(result.review, 2);
      expect(await products.withMatchKey('A-1', brand), isEmpty, reason: 'no product made from a stopped row');
      final queue = await lists.reviewQueue(listId: result.id);
      expect(queue, hasLength(2));
      expect(queue.first.reviewReason, contains('مكرر'));
    });

    test('an ambiguous code stops: it exists under another colour', () async {
      await products.create(ProductInput(nameAr: 'حوض', manufacturerCode: 'C-3', brandId: brand));
      final preview = await imports.preview(
        _sheet([
          ['كود الشركة', 'الاسم', 'اللون', 'السعر'],
          ['C-3', 'حوض', 'أبيض', '100'],
        ]),
        brandId: brand,
      );
      expect(preview.reviewCount, 1);
    });

    test('a known code in a new colour is a new product; the same colour is the known one', () async {
      final white = await products.create(
          ProductInput(nameAr: 'حوض أبيض', manufacturerCode: 'C-3', variant: 'أبيض', brandId: brand));
      final preview = await imports.preview(
        _sheet([
          ['كود الشركة', 'الاسم', 'سعر أبيض', 'سعر برجامون'],
          ['C-3', 'حوض', '100', '120'],
        ]),
        brandId: brand,
      );
      final byVariant = {for (final r in preview.rows) r.variant: r};
      expect(byVariant['أبيض']!.action, PriceRowAction.known);
      expect(byVariant['أبيض']!.productId, white.id);
      expect(byVariant['برجامون']!.action, PriceRowAction.create);
    });

    test('a missing or unreadable price stops the row; no price is invented', () async {
      final preview = await imports.preview(
        _sheet([
          ['كود الشركة', 'الاسم', 'السعر'],
          ['D-4', 'حوض', ''],
          ['E-5', 'مرحاض', 'abc'],
        ]),
        brandId: brand,
      );
      expect(preview.reviewCount, 2);
      final result = await imports.import(preview, header: header(), user: shop.admin);
      final queue = await lists.reviewQueue(listId: result.id);
      expect(queue.map((i) => i.price), [null, null]);
    });

    test('a code Excel holds as a number with no match stops: its zeros may be lost', () async {
      final preview = await imports.preview(
        _sheet([
          ['كود الشركة', 'الاسم', 'السعر'],
          [123, 'حوض', '100'],
        ]),
        brandId: brand,
      );
      expect(preview.reviewCount, 1);
      expect(preview.rows.single.reviewReason, contains('أصفار'));
    });

    test('codes match inside the brand: the same code under another brand is another product', () async {
      await products.create(ProductInput(nameAr: 'آخر', manufacturerCode: 'F-6', brandId: shop.brandId));
      final preview = await imports.preview(
        _sheet([
          ['كود الشركة', 'الاسم', 'السعر'],
          ['F-6', 'حوض', '100'],
        ]),
        brandId: brand,
      );
      expect(preview.createCount, 1);
    });

    test('importing twice makes a second version and no duplicate products', () async {
      final bytes = _sheet([
        ['كود الشركة', 'الاسم', 'السعر'],
        ['G-7', 'حوض', '100'],
      ]);
      await imports.import(await imports.preview(bytes, brandId: brand), header: header(), user: shop.admin);
      final second = await imports.preview(bytes, brandId: brand);
      expect(second.knownCount, 1);
      await imports.import(second, header: header(from: DateTime(2026, 8, 1)), user: shop.admin);
      expect(await products.withMatchKey('G-7', brand), hasLength(1));
    });

    test('missing columns are reported; a bad file is refused; cashier cannot import', () async {
      final preview = await imports.preview(
        _sheet([
          ['الاسم', 'السعر'],
          ['حوض', '100'],
        ]),
        brandId: brand,
      );
      expect(preview.missingColumns, ['كود الشركة']);
      expect(preview.canImport, isFalse);
      await expectLater(imports.preview([1, 2, 3], brandId: brand), throwsA(isA<ValidationException>()));
      final ok = await imports.preview(
        _sheet([
          ['كود الشركة', 'الاسم', 'السعر'],
          ['H-8', 'حوض', '100'],
        ]),
        brandId: brand,
      );
      await expectLater(imports.import(ok, header: header(), user: shop.cashier), throwsA(isA<ValidationException>()));
    });
  });

  group('review queue', () {
    Future<PriceListItem> stoppedRow(String price) async {
      final preview = await imports.preview(
        _sheet([
          ['كود الشركة', 'الاسم', 'السعر'],
          ['R-1', 'حوض', price],
          ['R-1', 'حوض', price],
        ]),
        brandId: brand,
      );
      final result = await imports.import(preview, header: header(), user: shop.admin);
      return (await lists.reviewQueue(listId: result.id)).first;
    }

    test('stopped rows price nothing until resolved by matching', () async {
      final row = await stoppedRow('100');
      final p = await products.create(ProductInput(nameAr: 'حوض', manufacturerCode: 'R-2', brandId: brand));
      expect(await lists.quotesFor(p.id, asOf: DateTime(2026, 8, 1)), isEmpty);
      await lists.resolveMatch(row.id, p.id, user: shop.admin);
      expect((await lists.quotesFor(p.id, asOf: DateTime(2026, 8, 1))).single.price, 10000);
    });

    test('a row can be resolved by a new product, or skipped with a reason', () async {
      final row = await stoppedRow('100');
      final queue = await lists.reviewQueue(listId: row.priceListId);
      final id = await lists.resolveCreate(queue[0].id, user: shop.admin);
      expect((await lists.quotesFor(id, asOf: DateTime(2026, 8, 1))).single.price, 10000);

      await expectLater(lists.resolveSkip(queue[1].id, reason: ' ', user: shop.admin), throwsA(isA<ValidationException>()));
      await lists.resolveSkip(queue[1].id, reason: 'مكرر فعلاً', user: shop.admin);
      expect(await lists.reviewQueue(listId: row.priceListId), isEmpty);
    });

    test('a row with no price cannot be resolved without one', () async {
      final preview = await imports.preview(
        _sheet([
          ['كود الشركة', 'الاسم', 'السعر'],
          ['S-1', 'حوض', ''],
        ]),
        brandId: brand,
      );
      final result = await imports.import(preview, header: header(), user: shop.admin);
      final row = (await lists.reviewQueue(listId: result.id)).single;
      await expectLater(lists.resolveCreate(row.id, user: shop.admin), throwsA(isA<ValidationException>()));
      final id = await lists.resolveCreate(row.id, price: 7700, user: shop.admin);
      expect((await lists.quotesFor(id, asOf: DateTime(2026, 8, 1))).single.price, 7700);
    });
  });

  group('single or small-group entry', () {
    test('adds to a version with no file: known code, new code, Variant', () async {
      final known = await products.create(ProductInput(nameAr: 'حوض', manufacturerCode: 'K-1', brandId: brand));
      final v = await lists.createVersion(header(), rows: const [], user: shop.admin);
      final result = await imports.enterRows(
        const [
          PriceEntry(code: 'K-1', price: 10000),
          PriceEntry(code: 'N-1', price: 20000, name: 'مرحاض', variant: 'أبيض', dimensions: '60x40'),
        ],
        brandId: brand,
        listId: v.id,
        user: shop.admin,
      );
      expect(result.created, 1);
      expect((await lists.quotesFor(known.id, asOf: DateTime(2026, 8, 1))).single.price, 10000);
      final fresh = (await products.withMatchKey('N-1', brand)).single;
      expect(fresh.variant, 'أبيض');
      expect(fresh.dimensions, '60x40');
    });

    test('a new dated version for one product leaves the earlier list open', () async {
      final p = await products.create(ProductInput(nameAr: 'حوض', manufacturerCode: 'K-1', brandId: brand));
      final q = await products.create(ProductInput(nameAr: 'مرحاض', manufacturerCode: 'K-2', brandId: brand));
      final v1 = await lists.createVersion(
        header(),
        rows: [
          PriceRowInput(name: 'حوض', price: 10000, productId: p.id),
          PriceRowInput(name: 'مرحاض', price: 20000, productId: q.id),
        ],
        user: shop.admin,
      );
      final v2 = await imports.enterRows(
        const [PriceEntry(code: 'K-1', price: 12000)],
        brandId: brand,
        newVersion: header(from: DateTime(2026, 9, 1)),
        user: shop.admin,
      );
      final day = DateTime(2026, 10, 1);
      expect((await lists.quotesFor(p.id, asOf: day)).single.priceListId, v2.id);
      expect((await lists.quotesFor(q.id, asOf: day)).single.priceListId, v1.id);
    });

    test('a new code without a name, or a duplicate, is refused on the spot', () async {
      final v = await lists.createVersion(header(), rows: const [], user: shop.admin);
      await expectLater(
        imports.enterRows(const [PriceEntry(code: 'Z-1', price: 1)], brandId: brand, listId: v.id, user: shop.admin),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        imports.enterRows(
          const [PriceEntry(code: 'Z-2', price: 1, name: 'x'), PriceEntry(code: 'z-2', price: 2, name: 'y')],
          brandId: brand,
          listId: v.id,
          user: shop.admin,
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(await products.withMatchKey('Z-2', brand), isEmpty);
    });
  });
}
