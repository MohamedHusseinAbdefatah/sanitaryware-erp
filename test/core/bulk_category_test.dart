import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// Many products get a category at once, and a price list with a category
/// column fills it for products that have none.
void main() {
  late Shop shop;

  setUp(() async => shop = await Shop.open());
  tearDown(() => shop.close());

  test('many products take one category and subcategory; each change is logged', () async {
    final catalog = CatalogService(shop.db);
    final basins = await catalog.saveCategory(name: 'أحواض');
    final wall = await catalog.saveCategory(name: 'معلقة', parentId: basins);
    final changed = await ProductService(shop.db)
        .setCategory([shop.mixer.id, shop.pipe.id], categoryId: basins, subcategoryId: wall, userId: shop.admin.id);
    expect(changed, 2);
    for (final p in await shop.db.select(shop.db.products).get()) {
      expect((p.categoryId, p.subcategoryId), (basins, wall));
    }
    final log = await (shop.db.select(shop.db.auditLogs)..where((l) => l.entity.equals('product'))).get();
    expect(log.where((l) => (l.details ?? '').contains('تعديل جماعي')), hasLength(2));
    // The same again changes nothing.
    expect(await ProductService(shop.db).setCategory([shop.mixer.id], categoryId: basins, subcategoryId: wall), 0);
  });

  test('a subcategory must sit under the chosen category', () async {
    final catalog = CatalogService(shop.db);
    final basins = await catalog.saveCategory(name: 'أحواض');
    final mixers = await catalog.saveCategory(name: 'خلاطات');
    final wall = await catalog.saveCategory(name: 'معلقة', parentId: basins);
    await expectLater(
      ProductService(shop.db).setCategory([shop.mixer.id], categoryId: mixers, subcategoryId: wall),
      throwsA(isA<ValidationException>()),
    );
  });

  test('a price list fills the category of known products with none, and leaves a chosen one', () async {
    final catalog = CatalogService(shop.db);
    final chosen = await catalog.saveCategory(name: 'سباكة');
    await ProductService(shop.db).setCategory([shop.pipe.id], categoryId: chosen);
    final imports = PriceListImportService(shop.db);
    final preview = await imports.preview(
      _sheet([
        ['كود الشركة', 'الاسم', 'السعر', 'التصنيف', 'التصنيف الفرعي'],
        ['M1', 'خلاط', '520', 'خلاطات', 'خلاطات حوض'],
        ['P1', 'ماسورة', '36', 'مواسير', ''],
      ]),
      brandId: shop.brandId,
    );
    expect(preview.categoryCount, 1, reason: 'only the mixer has no category');
    await imports.import(
      preview,
      header: PriceListHeader(
          name: 'قائمة', brandId: shop.brandId, listType: 'قائمة', effectiveFrom: DateTime.now(), sourceFile: 'x.xlsx'),
      user: shop.admin,
    );
    final cats = {for (final c in await shop.db.select(shop.db.categories).get()) c.id: c};
    final mixer = await (shop.db.select(shop.db.products)..where((p) => p.id.equals(shop.mixer.id))).getSingle();
    final pipe = await (shop.db.select(shop.db.products)..where((p) => p.id.equals(shop.pipe.id))).getSingle();
    expect((cats[mixer.categoryId]!.nameAr, cats[mixer.subcategoryId]!.nameAr), ('خلاطات', 'خلاطات حوض'));
    expect(pipe.categoryId, chosen, reason: 'a category already chosen is never changed');
  });
}
