import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/reports/report_service.dart';
import 'package:sanitaryware_erp/core/services/approval_service.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/fifo_service.dart';
import 'package:sanitaryware_erp/core/services/location_service.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/return_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/stock_price_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';

import '../support/fixture.dart';

/// Stock by place, stock at the old and the new price, and the costing fixes.
void main() {
  late Shop shop;
  late AppDatabase db;
  late LocationService places;
  late StockService stock;
  late SalesService sales;

  setUp(() async {
    shop = await Shop.open();
    db = shop.db;
    places = LocationService(db);
    stock = StockService(db);
    sales = SalesService(db);
  });
  tearDown(() => shop.close());

  Future<PurchaseInvoice> buy(int count, int cost, {int discount = 0, int location = mainLocationId}) =>
      PurchaseService(db).post(
        PurchaseInput(
          supplierId: shop.supplierId,
          lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(count), unitCost: cost)],
          discount: discount,
          locationId: location,
        ),
        user: shop.admin,
      );

  SaleInput sale(int count, {int? location}) => SaleInput(
        lines: [
          SaleLineInput(
            productId: shop.mixer.id,
            qty: qtyOf(count),
            unitPrice: 50000,
            priceListId: shop.priceListId,
            locationId: location,
          ),
        ],
        paidAmount: 50000 * count,
      );

  Future<int> at(int location) => stock.currentStock(shop.mixer.id, locationId: location);

  group('selling by place', () {
    test('stock moved to a sellable showroom sells from there, cost and all', () async {
      final showroom = await places.create(name: 'مخزن المعرض', kind: 'showroom_storage');
      await buy(1, 30000);
      await places.transfer(productId: shop.mixer.id, qty: qtyOf(1), fromLocationId: mainLocationId, toLocationId: showroom);

      await sales.post(sale(1), userId: shop.cashier.id);

      expect(await at(mainLocationId), 0);
      expect(await at(showroom), 0);
      expect(await FifoService(db).remaining(shop.mixer.id, locationId: showroom), 0);
      final item = await db.select(db.salesInvoiceItems).getSingle();
      expect(item.unitCost, 30000);
    });

    test('a display-only piece cannot be sold', () async {
      final display = await places.create(name: 'عرض', kind: 'showroom_display', isSellable: false);
      await buy(1, 30000);
      await places.transfer(productId: shop.mixer.id, qty: qtyOf(1), fromLocationId: mainLocationId, toLocationId: display);

      await expectLater(sales.post(sale(1), userId: shop.cashier.id), throwsA(isA<InsufficientStockException>()));
      await expectLater(
        sales.post(sale(1, location: display), userId: shop.admin.id),
        throwsA(isA<ValidationException>()),
      );
      expect(await at(display), qtyOf(1));
    });

    test('a line larger than one place splits; cancelling gives each place back its own', () async {
      final showroom = await places.create(name: 'مخزن المعرض', kind: 'showroom_storage');
      await buy(2, 30000);
      await buy(3, 40000, location: showroom);

      final inv = await sales.post(sale(4), userId: shop.cashier.id);
      expect(await at(mainLocationId), 0);
      expect(await at(showroom), qtyOf(1));
      final item = await db.select(db.salesInvoiceItems).getSingle();
      expect(item.costTotal, 2 * 30000 + 2 * 40000);

      await sales.cancel(inv.id, reason: 'خطأ', user: shop.admin);
      expect(await at(mainLocationId), qtyOf(2));
      expect(await at(showroom), qtyOf(3));
      expect(await FifoService(db).remaining(shop.mixer.id, locationId: showroom), qtyOf(3));
    });

    test('choosing a place takes from it, and refuses if it is short', () async {
      final showroom = await places.create(name: 'مخزن المعرض', kind: 'showroom_storage');
      await buy(2, 30000);
      await buy(1, 40000, location: showroom);
      await expectLater(
        sales.post(sale(2, location: showroom), userId: shop.cashier.id),
        throwsA(isA<InsufficientStockException>()),
      );
      await sales.post(sale(1, location: showroom), userId: shop.cashier.id);
      expect(await at(showroom), 0);
      expect(await at(mainLocationId), qtyOf(2));
      expect((await db.select(db.salesInvoiceItems).getSingle()).unitCost, 40000);
    });

    test('receiving into a place; a purchase return and cancel leave from where the goods are', () async {
      final showroom = await places.create(name: 'مخزن المعرض', kind: 'showroom_storage');
      final first = await buy(3, 30000, location: showroom);
      expect(await at(showroom), qtyOf(3));
      expect(await at(mainLocationId), 0);

      await ReturnService(db).postPurchaseReturn(
        ReturnInput(
          originalInvoiceId: first.id,
          lines: [ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 30000)],
        ),
        user: shop.admin,
      );
      expect(await at(showroom), qtyOf(2));

      final second = await buy(2, 35000, location: showroom);
      await PurchaseService(db).cancel(second.id, reason: 'خطأ', user: shop.admin);
      expect(await at(showroom), qtyOf(2));
      expect(await at(mainLocationId), 0);
    });

    test('a stock adjustment touches only its own place', () async {
      final showroom = await places.create(name: 'مخزن المعرض', kind: 'showroom_storage');
      await buy(2, 30000, location: showroom);
      await stock.adjust(productId: shop.mixer.id, delta: -qtyOf(1), reason: 'كسر', locationId: showroom);
      expect(await at(showroom), qtyOf(1));
      await expectLater(
        stock.adjust(productId: shop.mixer.id, delta: -qtyOf(1), reason: 'كسر'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a sale return goes to the place chosen', () async {
      final showroom = await places.create(name: 'مخزن المعرض', kind: 'showroom_storage');
      await buy(1, 30000);
      final inv = await sales.post(sale(1), userId: shop.cashier.id);
      await ReturnService(db).postSaleReturn(
        ReturnInput(
          originalInvoiceId: inv.id,
          locationId: showroom,
          refundAmount: 50000,
          lines: [ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000)],
        ),
        user: shop.cashier,
      );
      expect(await at(showroom), qtyOf(1));
      expect(await at(mainLocationId), 0);
    });

    test('the stock-by-place report lists each place and marks display only', () async {
      final display = await places.create(name: 'عرض', kind: 'showroom_display', isSellable: false);
      await buy(3, 30000);
      await places.transfer(productId: shop.mixer.id, qty: qtyOf(1), fromLocationId: mainLocationId, toLocationId: display);
      final t = await ReportService(db).stockByPlace();
      expect(t.rows, hasLength(2));
      expect(t.rows.firstWhere((r) => r[2] == 'عرض')[3], 'للعرض فقط');
      expect(t.rows.firstWhere((r) => r[2] == 'عرض')[5], 30000);
    });
  });

  group('costing', () {
    test('an invoice discount on a purchase lowers the real cost of the goods', () async {
      await buy(10, 10000, discount: 10000); // 1,000.00 off 10,000.00
      final layer = await db.select(db.costLayers).getSingle();
      expect(layer.unitCost, 9000);
      final item = await db.select(db.purchaseInvoiceItems).getSingle();
      expect(item.invoiceDiscountShare, 10000);
      expect(item.netTotal, 90000);
      expect(item.unitCost, 10000, reason: 'the invoice keeps what was printed on it');
    });

    test('a purchase discount is split over the lines exactly', () async {
      final inv = await PurchaseService(db).post(
        PurchaseInput(
          supplierId: shop.supplierId,
          lines: [
            PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(3), unitCost: 33333),
            PurchaseLineInput(productId: shop.pipe.id, qty: qtyOf(7), unitCost: 1111),
          ],
          discount: 1001,
        ),
        user: shop.admin,
      );
      final items = await db.select(db.purchaseInvoiceItems).get();
      expect(items.fold<int>(0, (s, i) => s + i.invoiceDiscountShare), 1001);
      expect(items.fold<int>(0, (s, i) => s + i.netTotal), inv.total);
    });

    test('returning goods bought with a discount refunds what they really cost', () async {
      final inv = await buy(10, 10000, discount: 10000);
      final line = (await ReturnService(db).returnableForPurchase(inv.id)).single;
      expect(line.unitPrice, 9000);
    });

    test('the blueprint example: 5 at 700 and 2 at 760 cost exactly 5,020 in the profit report', () async {
      await buy(5, 70000);
      await buy(5, 76000);
      final inv = await sales.post(sale(7), userId: shop.admin.id, belowCostReason: 'مثال');
      final item = await db.select(db.salesInvoiceItems).getSingle();
      expect(item.costTotal, 502000);
      final t = await ReportService(db).profit(from: inv.date, to: inv.date);
      expect(t.rows.any((r) => r.contains(-502000)), isTrue, reason: '${t.rows}');
    });
  });

  group('logs', () {
    test('a credit limit override is written to the approval log', () async {
      final tight = await PartyService(db).saveCustomer(const CustomerInput(name: 'محدود', creditLimit: 10000));
      await buy(1, 30000);
      final inv = await sales.post(
        SaleInput(
          customerId: tight,
          lines: [
            SaleLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000, priceListId: shop.priceListId),
          ],
        ),
        userId: shop.admin.id,
        allowOverCreditLimit: true,
      );
      final log = await ApprovalService(db).forDocument('sales_invoice', inv.id);
      expect(log.single.kind, ApprovalKind.creditLimit);
      expect(log.single.reason, contains('حد الائتمان'));
    });

    test('editing a product or customer records before and after', () async {
      await ProductService(db).update(
        shop.mixer.id,
        ProductInput(code: 'M1', manufacturerCode: 'M1', nameAr: 'خلاط كروم', brandId: shop.brandId, unitId: shop.mixer.unitId),
      );
      var log = (await db.select(db.auditLogs).get()).last;
      expect(log.details, allOf(contains('خلاط'), contains('خلاط كروم'), contains('←')));

      await PartyService(db).saveCustomer(
        const CustomerInput(name: 'عميل', creditLimit: 5000),
        id: shop.customerId,
      );
      log = (await db.select(db.auditLogs).get()).last;
      expect(log.details, allOf(contains('creditLimit'), contains('5000')));
    });
  });

  group('stock at the old and new price', () {
    late StockPriceService prices;

    /// A new version of the fixture's list, from a date.
    Future<int> newVersion(int price, DateTime from) async => (await PriceListService(db).createVersion(
          PriceListHeader(name: 'جديدة', brandId: shop.brandId, listType: 'عام', effectiveFrom: from),
          rows: [PriceRowInput(name: 'خلاط', price: price, productId: shop.mixer.id)],
          user: shop.admin,
        ))
            .id;

    setUp(() => prices = StockPriceService(db));

    test('stock bought before and after a new list shows as old and new', () async {
      await buy(60, 30000);
      await newVersion(60000, DateTime.now());
      await buy(40, 35000);

      final s = await prices.summaryOf(shop.mixer.id);
      expect(s.old, qtyOf(60));
      expect(s.current, qtyOf(40));
      expect(s.unknown, 0);

      final lines = await prices.breakdown(shop.mixer.id);
      expect(lines.map((l) => l.kind), [StockPriceKind.current, StockPriceKind.old]);
      expect(lines[0].listPrice, 60000);
      expect(lines[1].listPrice, 50000);
      expect(lines[1].currentPrice, 60000);
      expect(lines[1].value, 60 * 30000);
    });

    test('selling takes the old stock first', () async {
      await buy(5, 30000);
      await newVersion(60000, DateTime.now());
      await buy(5, 35000);
      await sales.post(
        SaleInput(
          lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(3), unitPrice: 60000, priceListId: shop.priceListId + 1)],
          paidAmount: 180000,
        ),
        userId: shop.cashier.id,
      );
      final s = await prices.summaryOf(shop.mixer.id);
      expect(s.old, qtyOf(2));
      expect(s.current, qtyOf(5));
    });

    test('a new version at the same price leaves the stock at the current price', () async {
      await buy(5, 30000);
      await newVersion(50000, DateTime.now());
      expect((await prices.summaryOf(shop.mixer.id)).current, qtyOf(5));
    });

    test('a transfer keeps the version', () async {
      final showroom = await places.create(name: 'مخزن المعرض', kind: 'showroom_storage');
      await buy(5, 30000);
      await places.transfer(productId: shop.mixer.id, qty: qtyOf(2), fromLocationId: mainLocationId, toLocationId: showroom);
      await newVersion(60000, DateTime.now());
      final lines = await prices.breakdown(shop.mixer.id);
      expect(lines.single.kind, StockPriceKind.old);
      expect(lines.single.places.values.toSet(), {qtyOf(3), qtyOf(2)});
    });

    test('a customer return keeps the version it left under', () async {
      await buy(1, 30000);
      final inv = await sales.post(sale(1), userId: shop.cashier.id);
      await newVersion(60000, DateTime.now());
      await ReturnService(db).postSaleReturn(
        ReturnInput(
          originalInvoiceId: inv.id,
          refundAmount: 50000,
          lines: [ReturnLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000)],
        ),
        user: shop.cashier,
      );
      expect((await prices.summaryOf(shop.mixer.id)).old, qtyOf(1));
    });

    test('stock from before any list stays unknown until a person says; nothing is guessed', () async {
      final loose = await ProductService(db).create(
        ProductInput(code: 'L1', manufacturerCode: 'L1', nameAr: 'بلا قائمة', brandId: shop.brandId, unitId: shop.mixer.unitId),
        openingQty: qtyOf(4),
        openingCost: 1000,
      );
      expect((await prices.summaryOf(loose.id)).unknown, qtyOf(4));

      final list = (await PriceListService(db).createVersion(
        PriceListHeader(name: 'ق', brandId: shop.brandId, listType: 'خاصة', effectiveFrom: DateTime.now().add(const Duration(days: 3))),
        rows: [PriceRowInput(name: 'بلا قائمة', price: 2000, productId: loose.id)],
        user: shop.admin,
      ))
          .id;
      expect((await prices.summaryOf(loose.id)).unknown, qtyOf(4), reason: 'the list starts after the stock came in');

      await expectLater(prices.assignUnknown(loose.id, list, user: shop.cashier), throwsA(isA<ValidationException>()));
      await prices.assignUnknown(loose.id, list, user: shop.admin);
      expect((await prices.summaryOf(loose.id)).unknown, 0);
    });

    test('at go-live a whole list can claim its unknown stock', () async {
      final a = await ProductService(db).create(
        ProductInput(code: 'A9', manufacturerCode: 'A9', nameAr: 'أ', brandId: shop.brandId, unitId: shop.mixer.unitId),
        openingQty: qtyOf(1),
        openingCost: 100,
      );
      final list = (await PriceListService(db).createVersion(
        PriceListHeader(name: 'ق', brandId: shop.brandId, listType: 'خاصة', effectiveFrom: DateTime.now().add(const Duration(days: 3))),
        rows: [PriceRowInput(name: 'أ', price: 200, productId: a.id)],
        user: shop.admin,
      ))
          .id;
      expect(await prices.assignAllUnknownFrom(list, user: shop.admin), 1);
      expect((await prices.summaryOf(a.id)).unknown, 0);
    });

    test('loading a list late stamps stock received inside its period', () async {
      final b = await ProductService(db).create(
        ProductInput(code: 'B9', manufacturerCode: 'B9', nameAr: 'ب', brandId: shop.brandId, unitId: shop.mixer.unitId),
        openingQty: qtyOf(2),
        openingCost: 100,
      );
      expect((await prices.summaryOf(b.id)).unknown, qtyOf(2));
      await PriceListService(db).createVersion(
        PriceListHeader(name: 'ق', brandId: shop.brandId, listType: 'خاصة', effectiveFrom: DateTime(2024)),
        rows: [PriceRowInput(name: 'ب', price: 200, productId: b.id)],
        user: shop.admin,
      );
      expect((await prices.summaryOf(b.id)).current, qtyOf(2));
    });

    test('the report lists old and new per product', () async {
      await buy(6, 30000);
      await newVersion(60000, DateTime.now());
      await buy(4, 35000);
      final t = await ReportService(db).stockByPrice();
      expect(t.rows.map((r) => r[2]), ['بالسعر الجديد', 'بالسعر القديم']);
      expect(t.rows.map((r) => r[6]), [qtyOf(4), qtyOf(6)]);
      expect(t.total('التكلفة الفعلية'), 6 * 30000 + 4 * 35000);
    });
  });
}
