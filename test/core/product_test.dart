import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/pricing_math.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/search_text.dart';
import 'package:sanitaryware_erp/core/services/catalog_service.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';

void main() {
  late AppDatabase db;
  late ProductService products;
  late CatalogService catalog;
  late int pieceId;
  late int meterId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    products = ProductService(db);
    catalog = CatalogService(db);
    await catalog.seedDefaultUnits();
    final units = await db.select(db.units).get();
    pieceId = units.firstWhere((u) => u.nameAr == 'قطعة').id;
    meterId = units.firstWhere((u) => u.nameAr == 'متر').id;
  });

  tearDown(() => db.close());

  group('search text', () {
    test('folds Arabic spelling variants and digits', () {
      expect(foldForSearch('أسطوانة'), foldForSearch('اسطوانه'));
      expect(foldForSearch('مُصْطفى'), foldForSearch('مصطفي'));
      expect(foldForSearch('٢٥'), '25');
      expect(matchesSearch('خلاط حوض', ['خلاط مطبخ وحوض جروهي']), isTrue);
      expect(matchesSearch('خلاط دش', ['خلاط حوض']), isFalse);
    });
  });

  group('catalog', () {
    test('default units: only meters allow fractions', () async {
      final units = await db.select(db.units).get();
      expect(units.map((u) => u.nameAr), ['قطعة', 'كرتونة', 'طقم', 'متر']);
      expect(units.where((u) => u.allowDecimal).single.nameAr, 'متر');
    });

    test('duplicate names are rejected, ignoring spelling variants', () async {
      await catalog.saveCategory(name: 'أحواض');
      await expectLater(
        catalog.saveCategory(name: ' احواض '),
        throwsA(isA<ValidationException>()),
      );
    });

    test('renaming keeps the same row', () async {
      final id = await catalog.saveBrand(name: 'Grohe');
      await catalog.saveBrand(id: id, name: 'GROHE');
      expect((await db.select(db.brands).get()).single.name, 'GROHE');
    });
  });

  group('products', () {
    test('opening stock becomes a movement and a FIFO layer at its actual cost', () async {
      final p = await products.create(
        ProductInput(code: 'A1', nameAr: 'خلاط', unitId: pieceId),
        openingQty: qtyOf(4),
        openingCost: 50000,
      );
      expect(await StockService(db).currentStock(p.id), qtyOf(4));
      final m = await db.select(db.stockMovements).getSingle();
      expect(m.type, StockMovementType.opening);
      expect(m.unitCost, 50000);
      final layer = await db.select(db.costLayers).getSingle();
      expect(layer.unitCost, 50000);
      expect(layer.qtyRemaining, qtyOf(4));
      expect(layer.sourceType, 'opening');
    });

    test('duplicate code is rejected with the other product named', () async {
      await products.create(const ProductInput(code: 'A1', nameAr: 'خلاط'));
      await expectLater(
        products.create(const ProductInput(code: 'A1', nameAr: 'حوض')),
        throwsA(isA<ValidationException>().having((e) => e.message, 'message', contains('خلاط'))),
      );
    });

    test('a fraction of a piece is rejected, a fraction of a meter is fine', () async {
      await expectLater(
        products.create(ProductInput(code: 'A1', nameAr: 'خلاط', unitId: pieceId), openingQty: 1500, openingCost: 1),
        throwsA(isA<ValidationException>()),
      );
      expect(await db.select(db.products).get(), isEmpty);
      final pipe = await products.create(
        ProductInput(code: 'P1', nameAr: 'ماسورة', unitId: meterId),
        openingQty: 12500,
        openingCost: 100,
      );
      expect(await StockService(db).currentStock(pipe.id), 12500);
    });

    test('opening stock needs its actual cost; no cost is made up', () async {
      await expectLater(
        products.create(ProductInput(code: 'A1', nameAr: 'خلاط', unitId: pieceId), openingQty: qtyOf(1)),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        products.create(ProductInput(code: 'A1', nameAr: 'خلاط', unitId: pieceId), openingQty: qtyOf(1), openingCost: -1),
        throwsA(isA<ValidationException>()),
      );
    });

    test('blank code: a Product ID is given; it never changes afterwards', () async {
      final a = await products.create(const ProductInput(nameAr: 'خلاط'));
      final b = await products.create(const ProductInput(nameAr: 'حوض'));
      expect(a.code, startsWith('P-'));
      expect(b.code, isNot(a.code));
      await expectLater(
        products.update(a.id, const ProductInput(code: 'NEW', nameAr: 'خلاط')),
        throwsA(isA<ValidationException>()),
      );
      await products.update(a.id, ProductInput(code: a.code, nameAr: 'خلاط كروم'));
      final after = await (db.select(db.products)..where((t) => t.id.equals(a.id))).getSingle();
      expect(after.code, a.code);
      expect(after.nameAr, 'خلاط كروم');
    });

    test('maker codes stay text: leading zeros, letters and hyphens are not lost', () async {
      for (final code in ['00123', '0-12-A', 'SP-0090X']) {
        final p = await products.create(ProductInput(nameAr: code, manufacturerCode: code));
        final back = await (db.select(db.products)..where((t) => t.id.equals(p.id))).getSingle();
        expect(back.manufacturerCode, code);
      }
    });

    test('the match key ignores spaces, case and Arabic digits but not zeros or hyphens', () {
      expect(matchKeyOf(' ab 12 '), 'AB12');
      expect(matchKeyOf('٠١٢'), '012');
      expect(matchKeyOf('012'), isNot(matchKeyOf('12')));
      expect(matchKeyOf('A-1'), isNot(matchKeyOf('A1')));
    });

    test('the same maker code under the same brand and variant is a duplicate', () async {
      final brand = await catalog.saveBrand(name: 'Ideal');
      final other = await catalog.saveBrand(name: 'SaniPure');
      await products.create(ProductInput(nameAr: 'خلاط', manufacturerCode: 'A-1', brandId: brand));
      await expectLater(
        products.create(ProductInput(nameAr: 'حوض', manufacturerCode: ' a-1', brandId: brand)),
        throwsA(isA<ValidationException>().having((e) => e.message, 'message', contains('خلاط'))),
      );
      // Another variant, or another brand, is another product.
      await products.create(ProductInput(nameAr: 'خلاط أسود', manufacturerCode: 'A-1', variant: 'أسود', brandId: brand));
      await products.create(ProductInput(nameAr: 'خلاط', manufacturerCode: 'A-1', brandId: other));
    });

    test('every master field is kept', () async {
      final brand = await catalog.saveBrand(name: 'Ideal');
      final cat = await catalog.saveCategory(name: 'أحواض');
      final sub = await catalog.saveCategory(name: 'معلقة', parentId: cat);
      final p = await products.create(ProductInput(
        nameAr: 'حوض',
        manufacturerCode: 'A-1',
        description: 'وصف',
        brandId: brand,
        categoryId: cat,
        subcategoryId: sub,
        series: 'Connect',
        dimensions: '60x40',
        variant: 'أبيض',
        finish: 'لامع',
        unitId: pieceId,
        barcode: '622000',
        technicalSpecs: 'مواصفات',
        vatBasis: VatStatus.inclusive,
        vatRateBp: 1400,
      ));
      expect(p.description, 'وصف');
      expect(p.subcategoryId, sub);
      expect(p.series, 'Connect');
      expect(p.dimensions, '60x40');
      expect(p.variant, 'أبيض');
      expect(p.finish, 'لامع');
      expect(p.barcode, '622000');
      expect(p.technicalSpecs, 'مواصفات');
      expect(p.vatBasis, VatStatus.inclusive);
      expect(p.vatRateBp, 1400);
      // Search finds it by maker code and by barcode.
      expect((await products.search('a-1')).single.product.id, p.id);
      expect((await products.search('622000')).single.product.id, p.id);
    });

    test('subcategories stay under their category and out of the main list', () async {
      final cat = await catalog.saveCategory(name: 'أحواض');
      await catalog.saveCategory(name: 'معلقة', parentId: cat);
      expect((await catalog.watchCategories().first).map((c) => c.nameAr), ['أحواض']);
      expect((await catalog.watchSubcategories().first).single.parentId, cat);
    });

    test('list shows stock, names and low-stock flag', () async {
      final cat = await catalog.saveCategory(name: 'خلاطات');
      await products.create(
        ProductInput(code: 'A1', nameAr: 'خلاط حوض', categoryId: cat, unitId: pieceId, minStock: qtyOf(5)),
        openingQty: qtyOf(3),
        openingCost: 100,
      );
      await products.create(
        ProductInput(code: 'B1', nameAr: 'حوض', unitId: pieceId, minStock: qtyOf(1)),
        openingQty: qtyOf(10),
        openingCost: 100,
      );
      final all = await products.watchList().first;
      expect(all.map((r) => r.product.code), ['B1', 'A1']); // ordered by name
      final mixer = all.firstWhere((r) => r.product.code == 'A1');
      expect(mixer.stock, qtyOf(3));
      expect(mixer.categoryName, 'خلاطات');
      expect(mixer.unitName, 'قطعة');
      expect(mixer.isLowStock, isTrue);

      expect((await products.watchList(lowStockOnly: true).first).single.product.code, 'A1');
      expect((await products.watchList(categoryId: cat).first).single.product.code, 'A1');
      expect((await products.watchList(search: 'خلاظ').first), isEmpty);
      expect((await products.watchList(search: 'b1').first).single.product.code, 'B1');
    });

    test('search puts an exact code first and skips inactive products', () async {
      await products.create(const ProductInput(code: 'X10', nameAr: 'محبس X1 كروم'));
      await products.create(const ProductInput(code: 'X1', nameAr: 'محبس'));
      await products.create(const ProductInput(code: 'X1-OLD', nameAr: 'محبس قديم', isActive: false));
      final hits = await products.search('x1');
      expect(hits.map((r) => r.product.code), ['X1', 'X10']);
    });

    test('a customer level maps to a pricing type', () {
      expect(PricingType.ofLevel(PriceLevel.retail), PricingType.b2c);
      expect(PricingType.ofLevel(PriceLevel.wholesale), PricingType.b2b);
      expect(PricingType.ofLevel(PriceLevel.contractor), PricingType.project);
      expect(PricingType.ofLevel(null), PricingType.b2c);
    });
  });

  group('stock adjustment', () {
    test('needs a reason and cannot go below zero', () async {
      final p = await products.create(
        ProductInput(code: 'A1', nameAr: 'خلاط', unitId: pieceId),
        openingQty: qtyOf(2),
        openingCost: 100,
      );
      final stock = StockService(db);
      await expectLater(
        stock.adjust(productId: p.id, delta: -qtyOf(1), reason: ' '),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        stock.adjust(productId: p.id, delta: -qtyOf(3), reason: 'كسر'),
        throwsA(isA<ValidationException>()),
      );
      await stock.adjust(productId: p.id, delta: -qtyOf(1), reason: 'كسر');
      expect(await stock.currentStock(p.id), qtyOf(1));
      final movements = await stock.watchMovements(p.id).first;
      expect(movements.first.note, 'كسر');
    });
  });

  group('parties', () {
    test('customers save, update and search', () async {
      final parties = PartyService(db);
      final id = await parties.saveCustomer(const CustomerInput(
        name: 'أحمد للمقاولات',
        phone: '0100',
        priceLevel: PriceLevel.contractor,
      ));
      await parties.saveCustomer(
        const CustomerInput(name: 'أحمد للمقاولات', phone: '0111', priceLevel: PriceLevel.contractor),
        id: id,
      );
      final found = await parties.watchCustomers(search: 'احمد').first;
      expect(found.single.phone, '0111');
      await expectLater(
        parties.saveCustomer(const CustomerInput(name: '  ')),
        throwsA(isA<ValidationException>()),
      );
    });

    test('suppliers save and search', () async {
      final parties = PartyService(db);
      await parties.saveSupplier(const SupplierInput(name: 'شركة الصفا', openingBalance: 100000));
      expect((await parties.watchSuppliers(search: 'صفا').first).single.openingBalance, 100000);
    });
  });
}
