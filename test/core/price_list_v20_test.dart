import 'dart:convert';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/services/audit_service.dart';
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
    sheet.appendRow([for (final c in r) c == null ? null : TextCellValue('$c')]);
  }
  return excel.encode()!;
}

/// Version 2.4: model numbers, historical lists, switching lists off and on.
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
    brand = await CatalogService(shop.db).saveBrand(name: 'Duravit');
  });
  tearDown(() => shop.close());

  PriceListHeader header({DateTime? from, String type = 'سيراميك'}) => PriceListHeader(
        name: 'Duravit ${(from ?? DateTime(2026, 7, 1)).year}',
        brandId: brand,
        listType: type,
        effectiveFrom: from ?? DateTime(2026, 7, 1),
      );

  group('model numbers', () {
    test('a model column is kept apart from the code, on the list row and on the product', () async {
      final known = await products.create(ProductInput(nameAr: 'حوض', manufacturerCode: '044546 0000', brandId: brand));
      final preview = await imports.preview(
        _sheet([
          ['كود الشركة', 'Model No.', 'الاسم', 'السعر'],
          ['044546 0000', 'ME-460', 'حوض', '1500'],
          ['023309 00 64', 'D-CODE 2', 'مرحاض', '3000'],
        ]),
        brandId: brand,
      );
      expect(preview.missingColumns, isEmpty);
      expect(preview.withModel, 2);
      expect(preview.modelCount, 1, reason: 'the known product has no model yet');

      final result = await imports.import(preview, header: header(), user: shop.admin);
      final items = await lists.items(result.id);
      expect(items.map((i) => i.manufacturerCode), ['044546 0000', '023309 00 64'], reason: 'the code stays the code');
      expect(items.map((i) => i.modelNo), ['ME-460', 'D-CODE 2']);

      final basin = await (shop.db.select(shop.db.products)..where((p) => p.id.equals(known.id))).getSingle();
      expect(basin.modelNo, 'ME-460');
      expect(basin.nameAr, 'حوض', reason: 'the model is never put into the name');
      final wc = (await products.withMatchKey('023309 00 64', brand)).single;
      expect(wc.modelNo, 'D-CODE 2');

      final hits = await products.search('D-CODE 2');
      expect(hits.first.product.id, wc.id, reason: 'a model number finds its product');
    });

    test('a model already on a product is never changed by a list', () async {
      final p = await products.create(
          ProductInput(nameAr: 'حوض', manufacturerCode: 'A-1', brandId: brand, modelNo: 'OLD-1'));
      final preview = await imports.preview(
        _sheet([
          ['الكود', 'الموديل', 'الاسم', 'السعر'],
          ['A-1', 'NEW-1', 'حوض', '100'],
        ]),
        brandId: brand,
      );
      expect(preview.modelCount, 0);
      await imports.import(preview, header: header(), user: shop.admin);
      final after = await (shop.db.select(shop.db.products)..where((t) => t.id.equals(p.id))).getSingle();
      expect(after.modelNo, 'OLD-1');
    });

    test('headings are found under a title, in any case and punctuation', () async {
      final preview = await imports.preview(
        _sheet([
          ['DURAVIT PRICE LIST 2026', null, null, null],
          [null, null, null, null],
          ['ARTICLE NO.', 'MODEL-NO', 'Product Name', 'List Price'],
          ['X1', 'M-77', 'Basin', '250'],
        ]),
        brandId: brand,
      );
      expect(preview.missingColumns, isEmpty);
      expect(preview.rows.single.code, 'X1');
      expect(preview.rows.single.modelNo, 'M-77');
      expect(preview.rows.single.price, 25000);
    });

    test('with only a model column, the model also stands as the code (as before)', () async {
      final preview = await imports.preview(
        _sheet([
          ['model', 'name', 'price'],
          ['M-9', 'Basin', '90'],
        ]),
        brandId: brand,
      );
      expect(preview.rows.single.code, 'M-9');
      expect(preview.rows.single.modelNo, 'M-9');
    });

    test('a CSV file is read like a sheet and keeps leading zeros', () async {
      final csv = utf8.encode('﻿كود الشركة;رقم الموديل;الاسم;السعر\n'
          '"00123";"M 1";"حوض ""كبير""";"1500"\n'
          '00777;M2;مرحاض;3000\n');
      final preview = await imports.previewCsv(csv, brandId: brand);
      expect(preview.missingColumns, isEmpty);
      expect(preview.rows.map((r) => r.code), ['00123', '00777']);
      expect(preview.rows.first.name, 'حوض "كبير"');
      expect(preview.rows.map((r) => r.modelNo), ['M 1', 'M2']);
      expect(preview.rows.first.codeWasNumber, isFalse);
    });
  });

  group('historical lists', () {
    test('a 2024 list uploaded in 2026 is saved with its own dates and leaves 2026 prices alone', () async {
      final basin = await products.create(ProductInput(nameAr: 'حوض', manufacturerCode: 'B-1', brandId: brand));
      Future<int> upload(DateTime from, String price) async {
        final p = await imports.preview(
          _sheet([
            ['كود الشركة', 'الاسم', 'السعر'],
            ['B-1', 'حوض', price],
          ]),
          brandId: brand,
        );
        return (await imports.import(p, header: header(from: from), user: shop.admin)).id;
      }

      final v2026 = await upload(DateTime(2026, 1, 1), '2000');
      final v2024 = await upload(DateTime(2024, 3, 1), '1200');
      final v2025 = await upload(DateTime(2025, 2, 1), '1600');

      final all = {for (final l in await shop.db.select(shop.db.priceLists).get()) l.id: l};
      expect(all[v2024]!.effectiveTo, DateTime(2025, 1, 31));
      expect(all[v2025]!.effectiveTo, DateTime(2025, 12, 31));
      expect(all[v2026]!.effectiveTo, isNull);
      expect(all[v2024]!.importDate.year, DateTime.now().year, reason: 'registered today, effective in 2024');

      Future<int> price(DateTime d) async => (await lists.quotesFor(basin.id, asOf: d)).single.price;
      expect(await price(DateTime(2024, 6, 1)), 120000);
      expect(await price(DateTime(2025, 6, 1)), 160000);
      expect(await price(DateTime(2026, 6, 1)), 200000);
      expect((await lists.history(basin.id)).length, 3, reason: 'every price is kept');
    });
  });

  group('switching a list off and on', () {
    test('an inactive list prices nothing new, stays on record, and can be switched on again', () async {
      final day = DateTime(2020, 6, 1);
      expect((await lists.quotesFor(shop.mixer.id, asOf: day)).single.priceListId, shop.priceListId);

      await lists.setActive(shop.priceListId, false, reason: 'أسعار خاطئة', user: shop.admin);
      expect(await lists.quotesFor(shop.mixer.id, asOf: day), isEmpty);
      final kept = await (shop.db.select(shop.db.priceLists)..where((l) => l.id.equals(shop.priceListId))).getSingle();
      expect(kept.status, PriceListStatus.inactive);
      expect(await lists.items(shop.priceListId), hasLength(2), reason: 'nothing is deleted');
      expect(await lists.quoteIn(shop.priceListId, shop.mixer.id), isNotNull,
          reason: 'old documents can still read their list');

      final log = (await shop.db.select(shop.db.auditLogs).get()).last;
      expect(log.action, AuditAction.deactivate);
      expect(log.oldValue, 'مفعلة');
      expect(log.newValue, 'موقوفة');
      expect(log.reason, 'أسعار خاطئة');
      expect(log.userId, shop.admin.id);

      await lists.setActive(shop.priceListId, true, reason: 'تم التصحيح', user: shop.admin);
      expect((await lists.quotesFor(shop.mixer.id, asOf: day)).single.priceListId, shop.priceListId);
    });

    test('only the owner switches lists; a withdrawn list cannot come back', () async {
      await expectLater(lists.setActive(shop.priceListId, false, reason: 'x', user: shop.cashier),
          throwsA(isA<ValidationException>()));
      await expectLater(lists.setActive(shop.priceListId, false, reason: ' ', user: shop.admin),
          throwsA(isA<ValidationException>()));
      await lists.withdraw(shop.priceListId, reason: 'خطأ', user: shop.admin);
      await expectLater(lists.setActive(shop.priceListId, true, reason: 'x', user: shop.admin),
          throwsA(isA<ValidationException>()));
    });
  });
}
