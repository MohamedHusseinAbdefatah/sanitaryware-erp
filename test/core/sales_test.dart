import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/auth/auth_service.dart';
import 'package:sanitaryware_erp/core/auth/password_hasher.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/catalog_service.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/settings_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';

void main() {
  late AppDatabase db;
  late SalesService sales;
  late StockService stock;
  late User admin;
  late User cashier;
  late Product mixer; // piece, cost 400.00, 10 in stock
  late Product pipe; // meter, cost 20.00, 100 m in stock
  late int customerId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    sales = SalesService(db);
    stock = StockService(db);
    final auth = AuthService(db, hasher: const PasswordHasher(iterations: 1));
    admin = await auth.firstRunSetup(
      company: const CompanyInfo(name: 'X'),
      fullName: 'المدير',
      username: 'admin',
      password: '1234',
    );
    cashier = await auth.createUser(
      fullName: 'الكاشير',
      username: 'cashier',
      password: '1234',
      role: UserRole.cashier,
    );
    await CatalogService(db).seedDefaultUnits();
    final units = await db.select(db.units).get();
    final products = ProductService(db);
    mixer = await products.create(
      ProductInput(
        code: 'M1',
        nameAr: 'خلاط',
        unitId: units.firstWhere((u) => !u.allowDecimal).id,
        costPrice: 40000,
        priceRetail: 50000,
      ),
      openingQty: qtyOf(10),
    );
    pipe = await products.create(
      ProductInput(
        code: 'P1',
        nameAr: 'ماسورة',
        unitId: units.firstWhere((u) => u.allowDecimal).id,
        costPrice: 2000,
        priceRetail: 3500,
      ),
      openingQty: qtyOf(100),
    );
    customerId = await PartyService(db).saveCustomer(const CustomerInput(name: 'عميل'));
  });

  tearDown(() => db.close());

  Future<List<Payment>> payments() => db.select(db.payments).get();

  group('totals', () {
    test('line and invoice discounts, fractional meters, rounding once per line', () {
      const input = SaleInput(
        lines: [
          SaleLineInput(productId: 1, qty: 2000, unitPrice: 50000, discount: 1000), // 990.00
          SaleLineInput(productId: 2, qty: 333, unitPrice: 1000), // 0.333 m x 10.00 = 3.33
        ],
        discount: 333,
      );
      expect(input.subtotal, 99000 + 333);
      expect(input.total, 99000);
    });
  });

  group('posting', () {
    test('a cash sale reduces stock, copies cost and records the payment', () async {
      final invoice = await sales.post(
        SaleInput(
          lines: [
            SaleLineInput(productId: mixer.id, qty: qtyOf(2), unitPrice: 50000),
            SaleLineInput(productId: pipe.id, qty: 12500, unitPrice: 3500),
          ],
          paidAmount: 100000 + 43750,
        ),
        userId: cashier.id,
      );
      expect(invoice.number, 'S-000001');
      expect(invoice.total, 143750);
      expect(invoice.customerId, isNull);
      expect(await stock.currentStock(mixer.id), qtyOf(8));
      expect(await stock.currentStock(pipe.id), 87500);

      final items = await db.select(db.salesInvoiceItems).get();
      expect(items.map((i) => i.unitCost), [40000, 2000]);

      final paid = (await payments()).single;
      expect(paid.amount, 143750);
      expect(paid.partyId, walkInCustomerId);
      expect(paid.invoiceRefId, invoice.id);
      expect(paid.number, 'R-000001');
    });

    test('a credit sale saves no payment; a partial one saves the part paid', () async {
      await sales.post(SaleInput(
        customerId: customerId,
        lines: [SaleLineInput(productId: mixer.id, qty: qtyOf(1), unitPrice: 50000)],
      ));
      expect(await payments(), isEmpty);

      final partial = await sales.post(SaleInput(
        customerId: customerId,
        lines: [SaleLineInput(productId: mixer.id, qty: qtyOf(1), unitPrice: 50000)],
        paidAmount: 20000,
      ));
      expect(partial.paidAmount, 20000);
      expect((await payments()).single.partyId, customerId);
    });

    test('numbers are sequential', () async {
      for (final expected in ['S-000001', 'S-000002']) {
        final inv = await sales.post(SaleInput(
          customerId: customerId,
          lines: [SaleLineInput(productId: mixer.id, qty: qtyOf(1), unitPrice: 50000)],
        ));
        expect(inv.number, expected);
      }
    });

    test('not enough stock blocks the sale and saves nothing', () async {
      await expectLater(
        sales.post(SaleInput(
          customerId: customerId,
          lines: [
            SaleLineInput(productId: pipe.id, qty: qtyOf(1), unitPrice: 3500),
            // Same product on two lines: 6 + 5 = 11 > 10 in stock.
            SaleLineInput(productId: mixer.id, qty: qtyOf(6), unitPrice: 50000),
            SaleLineInput(productId: mixer.id, qty: qtyOf(5), unitPrice: 50000),
          ],
        )),
        throwsA(isA<InsufficientStockException>()
            .having((e) => e.shortages.single.needed, 'needed', qtyOf(11))),
      );
      expect(await db.select(db.salesInvoices).get(), isEmpty);
      expect(await stock.currentStock(pipe.id), qtyOf(100));
      // The failed save did not use up a number.
      final next = await sales.post(SaleInput(
        customerId: customerId,
        lines: [SaleLineInput(productId: mixer.id, qty: qtyOf(1), unitPrice: 50000)],
      ));
      expect(next.number, 'S-000001');
    });

    test('the negative-stock setting lets the sale through', () async {
      await SettingsService(db).setBool(SettingKey.allowNegativeStock, true);
      await sales.post(SaleInput(
        customerId: customerId,
        lines: [SaleLineInput(productId: mixer.id, qty: qtyOf(12), unitPrice: 50000)],
      ));
      expect(await stock.currentStock(mixer.id), -qtyOf(2));
    });

    test('invalid invoices are rejected', () async {
      Future<void> rejects(SaleInput input) =>
          expectLater(sales.post(input), throwsA(isA<ValidationException>()));
      SaleLineInput line({int? qty, int price = 50000, int discount = 0, int? product}) =>
          SaleLineInput(
            productId: product ?? mixer.id,
            qty: qty ?? qtyOf(1),
            unitPrice: price,
            discount: discount,
          );

      await rejects(SaleInput(customerId: customerId, lines: const []));
      await rejects(SaleInput(customerId: customerId, lines: [line(qty: 0)]));
      await rejects(SaleInput(customerId: customerId, lines: [line(qty: 1500)])); // 1.5 pieces
      await rejects(SaleInput(customerId: customerId, lines: [line(price: -1)]));
      await rejects(SaleInput(customerId: customerId, lines: [line(discount: 50001)]));
      await rejects(SaleInput(customerId: customerId, lines: [line()], discount: 50001));
      await rejects(SaleInput(customerId: customerId, lines: [line()], paidAmount: 50001));
      // A cash sale with no customer must be paid in full.
      await rejects(SaleInput(lines: [line()], paidAmount: 10000));
      expect(await db.select(db.salesInvoices).get(), isEmpty);
    });

    test('a zero-price line is allowed (free item)', () async {
      final inv = await sales.post(SaleInput(
        customerId: customerId,
        lines: [SaleLineInput(productId: mixer.id, qty: qtyOf(1), unitPrice: 0)],
      ));
      expect(inv.total, 0);
    });
  });

  group('cancelling', () {
    late SalesInvoice invoice;

    setUp(() async {
      invoice = await sales.post(SaleInput(
        customerId: customerId,
        lines: [SaleLineInput(productId: mixer.id, qty: qtyOf(3), unitPrice: 50000)],
        paidAmount: 50000,
      ));
    });

    test('restores stock, cancels the payment and keeps the invoice', () async {
      await sales.cancel(invoice.id, reason: 'خطأ في الكمية', user: admin);
      expect(await stock.currentStock(mixer.id), qtyOf(10));
      final saved = await db.select(db.salesInvoices).getSingle();
      expect(saved.status, DocStatus.cancelled);
      expect(saved.notes, contains('خطأ في الكمية'));
      expect((await payments()).single.status, DocStatus.cancelled);
    });

    test('cashier cannot cancel, a reason is required, and only once', () async {
      await expectLater(
        sales.cancel(invoice.id, reason: 'x', user: cashier),
        throwsA(isA<ValidationException>()),
      );
      await expectLater(
        sales.cancel(invoice.id, reason: ' ', user: admin),
        throwsA(isA<ValidationException>()),
      );
      await sales.cancel(invoice.id, reason: 'x', user: admin);
      await expectLater(
        sales.cancel(invoice.id, reason: 'x', user: admin),
        throwsA(isA<ValidationException>()),
      );
      expect(await stock.currentStock(mixer.id), qtyOf(10));
    });
  });

  group('queries', () {
    test('list and detail show customer, lines and units', () async {
      final inv = await sales.post(SaleInput(
        customerId: customerId,
        lines: [
          SaleLineInput(productId: pipe.id, qty: 2500, unitPrice: 3500),
          SaleLineInput(productId: mixer.id, qty: qtyOf(1), unitPrice: 50000),
        ],
      ), userId: admin.id);
      await sales.post(SaleInput(
        lines: [SaleLineInput(productId: mixer.id, qty: qtyOf(1), unitPrice: 50000)],
        paidAmount: 50000,
      ));

      final list = await sales.watchList().first;
      expect(list.map((r) => r.customerName), [null, 'عميل']);

      final detail = await sales.detail(inv.id);
      expect(detail.customer!.name, 'عميل');
      expect(detail.createdByName, 'المدير');
      expect(detail.lines.map((l) => l.unitName), ['متر', 'قطعة']);
      expect(detail.lines.first.item.lineTotal, 8750);
    });

    test('date range filter', () async {
      await sales.post(SaleInput(
        customerId: customerId,
        date: DateTime(2026, 1, 15, 18),
        lines: [SaleLineInput(productId: mixer.id, qty: qtyOf(1), unitPrice: 50000)],
      ));
      await sales.post(SaleInput(
        customerId: customerId,
        date: DateTime(2026, 2, 1, 9),
        lines: [SaleLineInput(productId: mixer.id, qty: qtyOf(1), unitPrice: 50000)],
      ));
      final jan = await sales
          .watchList(from: DateTime(2026, 1, 1), to: DateTime(2026, 1, 31))
          .first;
      expect(jan.single.invoice.number, 'S-000001');
      final day = await sales
          .watchList(from: DateTime(2026, 1, 15), to: DateTime(2026, 1, 15))
          .first;
      expect(day, hasLength(1));
    });
  });
}
