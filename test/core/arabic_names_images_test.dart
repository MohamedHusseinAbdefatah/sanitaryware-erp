import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sanitaryware_erp/core/services/catalog_service.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/price_list_import_service.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';
import 'package:sanitaryware_erp/core/services/product_image_service.dart';
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

/// 1.10.0: Arabic names from the price list, and a photo per product.
void main() {
  late Shop shop;
  late PriceListImportService imports;
  late ProductService products;
  late int brand;

  setUp(() async {
    shop = await Shop.open();
    imports = PriceListImportService(shop.db);
    products = ProductService(shop.db);
    brand = await CatalogService(shop.db).saveBrand(name: 'Ideal Standard');
  });
  tearDown(() => shop.close());

  PriceListHeader header(String type) =>
      PriceListHeader(name: 'قائمة', brandId: brand, listType: type, effectiveFrom: DateTime(2026, 7, 1));

  group('Arabic names from the list', () {
    test('a list with English and Arabic names: new products are named in Arabic, the English kept', () async {
      final preview = await imports.preview(
        _sheet([
          ['كود الشركة', 'الاسم', 'الاسم بالعربي', 'السعر'],
          ['T3290', 'Wall hung WC', 'قاعدة معلقة', '5200'],
          ['T3291', 'Soft close seat', '', '1800'],
        ]),
        brandId: brand,
      );
      expect(preview.createCount, 2);
      await imports.import(preview, header: header('عام'), user: shop.admin);
      final all = await shop.db.select(shop.db.products).get();
      final wc = all.firstWhere((p) => p.manufacturerCode == 'T3290');
      expect(wc.nameAr, 'قاعدة معلقة');
      expect(wc.description, 'Wall hung WC');
      final seat = all.firstWhere((p) => p.manufacturerCode == 'T3291');
      expect(seat.nameAr, 'Soft close seat', reason: 'no Arabic name in the file: the list name');
    });

    test('a product named only in English gets the Arabic name; an Arabic name is never replaced', () async {
      final english = await products.create(ProductInput(nameAr: 'Basin 60', manufacturerCode: 'E-1', brandId: brand));
      final arabic = await products.create(ProductInput(nameAr: 'حوض قديم', manufacturerCode: 'A-1', brandId: brand));
      final preview = await imports.preview(
        _sheet([
          ['كود الشركة', 'الاسم', 'الاسم العربي', 'السعر'],
          ['E-1', 'Basin 60', 'حوض 60 سم', '1000'],
          ['A-1', 'Old basin', 'حوض جديد', '900'],
        ]),
        brandId: brand,
      );
      expect(preview.knownCount, 2);
      expect(preview.arabicNameCount, 1);
      await imports.import(preview, header: header('عام'), user: shop.admin);
      final e = await products.row(english.id);
      expect(e.product.nameAr, 'حوض 60 سم');
      expect(e.product.description, 'Basin 60', reason: 'the old English name is kept as the description');
      expect((await products.row(arabic.id)).product.nameAr, 'حوض قديم');
    });

    test('a list whose only name column is Arabic also fills English-only names', () async {
      final english = await products.create(ProductInput(nameAr: 'Mixer', manufacturerCode: 'M-9', brandId: brand));
      final preview = await imports.preview(
        _sheet([
          ['كود الشركة', 'الاسم', 'السعر'],
          ['M-9', 'خلاط حوض', '700'],
        ]),
        brandId: brand,
      );
      expect(preview.arabicNameCount, 1);
      await imports.import(preview, header: header('عام'), user: shop.admin);
      expect((await products.row(english.id)).product.nameAr, 'خلاط حوض');
    });

    test('a list with only an Arabic name column is accepted', () async {
      final preview = await imports.preview(
        _sheet([
          ['كود الشركة', 'Arabic name', 'السعر'],
          ['Z-1', 'مرحاض', '100'],
        ]),
        brandId: brand,
      );
      expect(preview.missingColumns, isEmpty);
      expect(preview.createCount, 1);
      expect(preview.rows.single.arabicName, 'مرحاض');
    });
  });

  group('product photos', () {
    late ProductImageService images;

    setUp(() => images = ProductImageService(shop.db));

    Uint8List picture(int w, int h) =>
        Uint8List.fromList(img.encodePng(img.Image(width: w, height: h)..clear(img.ColorRgb8(200, 30, 30))));

    test('a big photo is shrunk to a JPEG of at most 800 px with a small thumbnail', () async {
      await images.setImage(shop.mixer.id, picture(1600, 1200), user: shop.admin);
      final row = await shop.db.select(shop.db.productImages).getSingle();
      expect(row.width, 800);
      expect(row.height, 600);
      final thumb = img.decodeJpg(row.thumb)!;
      expect(thumb.width, productThumbSize);
      expect(img.decodeJpg(row.bytes), isNotNull);
      expect((await images.watchThumbs().first).keys, [shop.mixer.id]);
    });

    test('a new photo replaces the old one; it can be removed', () async {
      await images.setImage(shop.mixer.id, picture(300, 900), user: shop.admin);
      await images.setImage(shop.mixer.id, picture(100, 100), user: shop.admin);
      final row = await shop.db.select(shop.db.productImages).getSingle();
      expect(row.width, 100, reason: 'a small photo is not enlarged');
      await images.remove(shop.mixer.id, user: shop.admin);
      expect(await images.image(shop.mixer.id), isNull);
    });

    test('a file that is not a picture is refused, and only the admin adds photos', () async {
      await expectLater(images.setImage(shop.mixer.id, Uint8List.fromList([1, 2, 3, 4]), user: shop.admin),
          throwsA(isA<ValidationException>()));
      await expectLater(images.setImage(shop.mixer.id, picture(10, 10), user: shop.cashier),
          throwsA(isA<ValidationException>()));
    });
  });
}
