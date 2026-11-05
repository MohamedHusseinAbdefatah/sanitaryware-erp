import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/services/discount_service.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';

void main() {
  late AppDatabase db;
  late PriceListService lists;
  late DiscountService discounts;
  late int supplier;
  late int brand;
  late int category;
  late int mixer;
  late int basin;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    lists = PriceListService(db);
    discounts = DiscountService(db);
    supplier = await db.into(db.suppliers).insert(SuppliersCompanion.insert(name: 'مورد'));
    brand = await db.into(db.brands).insert(BrandsCompanion.insert(name: 'ديورافيت'));
    category = await db.into(db.categories).insert(CategoriesCompanion.insert(nameAr: 'أحواض'));
    mixer = await db.into(db.products).insert(
        ProductsCompanion.insert(code: 'M1', nameAr: 'خلاط', brandId: Value(brand)));
    basin = await db.into(db.products).insert(ProductsCompanion.insert(
        code: 'B1', nameAr: 'حوض', brandId: Value(brand), categoryId: Value(category)));
  });
  tearDown(() => db.close());

  final jan = DateTime(2026, 1, 1);
  final jul = DateTime(2026, 7, 1);

  test('a list is saved and its lines matched to products by code', () async {
    final r = await lists.create(
      supplierId: supplier,
      name: 'يناير',
      effectiveDate: jan,
      rows: const [
        PriceRowInput(name: 'خلاط', price: 100000, supplierCode: 'm1'),
        PriceRowInput(name: 'غير معروف', price: 5000, supplierCode: 'ZZ'),
        PriceRowInput(name: 'بدون كود', price: 5000),
      ],
    );
    expect(r.rows, 3);
    expect(r.matched, 1);
  });

  test('the newest list in force on the date gives the price', () async {
    Future<void> make(DateTime d, int price) => lists.create(
        supplierId: supplier,
        name: 'قائمة',
        effectiveDate: d,
        rows: [PriceRowInput(name: 'خلاط', price: price, supplierCode: 'M1')]);
    await make(jan, 100000);
    await make(jul, 120000);
    expect((await lists.priceFor(mixer, asOf: DateTime(2026, 3, 1)))!.price, 100000);
    expect((await lists.priceFor(mixer, asOf: DateTime(2026, 8, 1)))!.price, 120000);
    expect(await lists.priceFor(mixer, asOf: DateTime(2025, 12, 1)), isNull);
  });

  test('a switched-off list is ignored', () async {
    final a = await lists.create(
        supplierId: supplier,
        name: 'قديمة',
        effectiveDate: jan,
        rows: const [PriceRowInput(name: 'خلاط', price: 100000, supplierCode: 'M1')]);
    final b = await lists.create(
        supplierId: supplier,
        name: 'جديدة',
        effectiveDate: jul,
        rows: const [PriceRowInput(name: 'خلاط', price: 120000, supplierCode: 'M1')]);
    await lists.setActive(b.id, false);
    expect((await lists.priceFor(mixer, asOf: DateTime(2026, 8, 1)))!.priceListId, a.id);
  });

  test('empty list, negative price and unknown supplier are refused', () async {
    await expectLater(
        lists.create(supplierId: supplier, name: 'x', effectiveDate: jan, rows: const []),
        throwsA(isA<ValidationException>()));
    await expectLater(
        lists.create(
            supplierId: supplier,
            name: 'x',
            effectiveDate: jan,
            rows: const [PriceRowInput(name: 'a', price: -1)]),
        throwsA(isA<ValidationException>()));
    await expectLater(
        lists.create(
            supplierId: 999,
            name: 'x',
            effectiveDate: jan,
            rows: const [PriceRowInput(name: 'a', price: 1)]),
        throwsA(isA<ValidationException>()));
  });

  test('no discount rule means no discount', () async {
    expect(await discounts.percentFor(supplierId: supplier, productId: mixer), 0);
    expect(applyDiscount(100000, 0), 100000);
  });

  test('the most specific discount wins', () async {
    await discounts.addRule(supplierId: supplier, scope: DiscountScope.supplier, percentBp: 1000);
    expect(await discounts.percentFor(supplierId: supplier, productId: mixer), 1000);
    await discounts.addRule(
        supplierId: supplier, scope: DiscountScope.brand, brandId: brand, percentBp: 2100);
    expect(await discounts.percentFor(supplierId: supplier, productId: mixer), 2100);
    await discounts.addRule(
        supplierId: supplier, scope: DiscountScope.category, categoryId: category, percentBp: 2500);
    expect(await discounts.percentFor(supplierId: supplier, productId: basin), 2500);
    expect(await discounts.percentFor(supplierId: supplier, productId: mixer), 2100);
    await discounts.addRule(
        supplierId: supplier, scope: DiscountScope.product, productId: basin, percentBp: 3000);
    expect(await discounts.percentFor(supplierId: supplier, productId: basin), 3000);
  });

  test('a discount only counts inside its dates and while on', () async {
    final id = await discounts.addRule(
        supplierId: supplier,
        scope: DiscountScope.supplier,
        percentBp: 1500,
        validFrom: jan,
        validTo: DateTime(2026, 3, 31));
    expect(await discounts.percentFor(supplierId: supplier, productId: mixer, asOf: DateTime(2026, 2, 1)), 1500);
    expect(await discounts.percentFor(supplierId: supplier, productId: mixer, asOf: DateTime(2026, 5, 1)), 0);
    await discounts.setActive(id, false);
    expect(await discounts.percentFor(supplierId: supplier, productId: mixer, asOf: DateTime(2026, 2, 1)), 0);
  });

  test('a bad discount is refused', () async {
    await expectLater(
        discounts.addRule(supplierId: supplier, scope: DiscountScope.supplier, percentBp: 10001),
        throwsA(isA<ValidationException>()));
    await expectLater(
        discounts.addRule(supplierId: supplier, scope: DiscountScope.brand, percentBp: 100),
        throwsA(isA<ValidationException>()));
  });

  test('net cost is the list price less the discount, rounded to the piastre', () async {
    await lists.create(
        supplierId: supplier,
        name: 'قائمة',
        effectiveDate: jan,
        rows: const [PriceRowInput(name: 'خلاط', price: 100000, supplierCode: 'M1')]);
    expect(await lists.netCostFor(mixer, asOf: jul), 100000);
    await discounts.addRule(
        supplierId: supplier, scope: DiscountScope.brand, brandId: brand, percentBp: 2100);
    expect(await lists.netCostFor(mixer, asOf: jul), 79000);
    expect(applyDiscount(333, 2100), 263); // 333 - 69.93 -> 333 - 70
  });
}
