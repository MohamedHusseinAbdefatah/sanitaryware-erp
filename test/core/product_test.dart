import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
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
    test('opening stock becomes a movement', () async {
      final p = await products.create(
        ProductInput(code: 'A1', nameAr: 'خلاط', unitId: pieceId, costPrice: 50000),
        openingQty: qtyOf(4),
      );
      expect(await StockService(db).currentStock(p.id), qtyOf(4));
      final m = await db.select(db.stockMovements).getSingle();
      expect(m.type, StockMovementType.opening);
      expect(m.unitCost, 50000);
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
        products.create(ProductInput(code: 'A1', nameAr: 'خلاط', unitId: pieceId), openingQty: 1500),
        throwsA(isA<ValidationException>()),
      );
      expect(await db.select(db.products).get(), isEmpty);
      final pipe = await products.create(
        ProductInput(code: 'P1', nameAr: 'ماسورة', unitId: meterId),
        openingQty: 12500,
      );
      expect(await StockService(db).currentStock(pipe.id), 12500);
    });

    test('negative prices are rejected', () async {
      await expectLater(
        products.create(const ProductInput(code: 'A1', nameAr: 'خلاط', priceRetail: -1)),
        throwsA(isA<ValidationException>()),
      );
    });

    test('list shows stock, names and low-stock flag', () async {
      final cat = await catalog.saveCategory(name: 'خلاطات');
      await products.create(
        ProductInput(code: 'A1', nameAr: 'خلاط حوض', categoryId: cat, unitId: pieceId, minStock: qtyOf(5)),
        openingQty: qtyOf(3),
      );
      await products.create(
        ProductInput(code: 'B1', nameAr: 'حوض', unitId: pieceId, minStock: qtyOf(1)),
        openingQty: qtyOf(10),
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

    test('price changes are audited', () async {
      final p = await products.create(const ProductInput(code: 'A1', nameAr: 'خلاط', priceRetail: 10000));
      await products.update(p.id, const ProductInput(code: 'A1', nameAr: 'خلاط', priceRetail: 12000));
      final log = (await db.select(db.auditLogs).get()).last;
      expect(log.details, contains('120.00'));
    });

    test('customer price level picks the right price', () async {
      final p = await products.create(const ProductInput(
        code: 'A1',
        nameAr: 'خلاط',
        priceRetail: 300,
        priceWholesale: 200,
        priceContractor: 100,
      ));
      expect(p.priceFor(PriceLevel.retail), 300);
      expect(p.priceFor(PriceLevel.wholesale), 200);
      expect(p.priceFor(PriceLevel.contractor), 100);
    });
  });

  group('stock adjustment', () {
    test('needs a reason and cannot go below zero', () async {
      final p = await products.create(
        ProductInput(code: 'A1', nameAr: 'خلاط', unitId: pieceId),
        openingQty: qtyOf(2),
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
