import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/balance_service.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/ledger_service.dart';
import 'package:sanitaryware_erp/core/services/location_service.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/payment_service.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';
import 'package:sanitaryware_erp/core/services/supplier_advance_service.dart';

import '../support/fixture.dart';

/// The client's requests after 2.5.1: delete a price list for real and its
/// products with it, delete wrong products and parties, fix or delete a
/// wrong payment, no forced reasons, and goods received into several places.
void main() {
  late Shop shop;

  setUp(() async => shop = await Shop.open());
  tearDown(() => shop.close());

  Future<PurchaseInvoice> buy(int count, {int? locationId, List<PurchaseLineInput>? lines, int paid = 0}) =>
      PurchaseService(shop.db).post(
        PurchaseInput(
          supplierId: shop.supplierId,
          lines: lines ?? [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(count), unitCost: 30000)],
          paidAmount: paid,
        ),
        user: shop.admin,
      );

  Future<int> newList(String type, DateTime from, List<(String, int)> rows) async {
    final r = await PriceListService(shop.db).createVersion(
      PriceListHeader(name: type, brandId: shop.brandId, listType: type, effectiveFrom: from, sourceFile: 'x.xlsx'),
      rows: [
        for (final (code, price) in rows)
          PriceRowInput(name: 'صنف $code', price: price, manufacturerCode: code,
              productId: (await ProductService(shop.db).create(ProductInput(
                code: 'X-$code', manufacturerCode: code, nameAr: 'صنف $code', brandId: shop.brandId,
                unitId: shop.mixer.unitId))).id),
      ],
      user: shop.admin,
    );
    return r.id;
  }

  group('price lists', () {
    test('an unused list is deleted for good, with its products, and the version before is back', () async {
      final lists = PriceListService(shop.db);
      final v1 = await newList('خلاطات', DateTime(2026, 1, 1), [('A1', 10000)]);
      final v2 = await newList('خلاطات', DateTime(2026, 6, 1), [('A2', 12000)]);
      var first = await (shop.db.select(shop.db.priceLists)..where((l) => l.id.equals(v1))).getSingle();
      expect(first.effectiveTo, isNotNull, reason: 'the new version closed the old one');

      final r = await lists.remove(v2, user: shop.admin);
      expect((r.deleted, r.productsDeleted, r.restoredVersion), (true, 1, first.versionNo));
      expect(await (shop.db.select(shop.db.priceLists)..where((l) => l.id.equals(v2))).getSingleOrNull(), isNull);
      expect(await (shop.db.select(shop.db.priceListItems)..where((i) => i.priceListId.equals(v2))).get(), isEmpty);
      first = await (shop.db.select(shop.db.priceLists)..where((l) => l.id.equals(v1))).getSingle();
      expect(first.effectiveTo, isNull, reason: 'the old version is in force again');
      final products = await shop.db.select(shop.db.products).get();
      expect(products.map((p) => p.manufacturerCode), isNot(contains('A2')));
      expect(products.map((p) => p.manufacturerCode), contains('A1'));
    });

    test('a list documents used leaves every screen, kept only for them; only its unused products go', () async {
      final lists = PriceListService(shop.db);
      // The fixture's list prices the mixer and the pipe; the mixer is bought.
      await PurchaseService(shop.db).post(
        PurchaseInput(supplierId: shop.supplierId, lines: [
          PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(2), unitCost: 30000, priceListId: shop.priceListId),
        ]),
        user: shop.admin,
      );
      expect(await lists.usage(shop.priceListId), contains('فاتورة شراء'));
      final r = await lists.remove(shop.priceListId, user: shop.admin);
      expect((r.deleted, r.keptForDocuments), (true, true));
      final list = await (shop.db.select(shop.db.priceLists)..where((l) => l.id.equals(shop.priceListId))).getSingle();
      expect(list.status, PriceListStatus.deleted, reason: 'kept for the invoice that used it');
      expect((await lists.summaries()).map((s) => s.list.id), isNot(contains(shop.priceListId)),
          reason: 'gone from the price lists screen');
      final ids = (await shop.db.select(shop.db.products).get()).map((p) => p.id);
      expect(ids, contains(shop.mixer.id), reason: 'bought, so kept');
      expect(ids, isNot(contains(shop.pipe.id)), reason: 'never used, so it went with the list');
    });

    test('all withdrawn lists are deleted at once', () async {
      final lists = PriceListService(shop.db);
      final a = await newList('أ', DateTime(2026, 1, 1), [('B1', 1000)]);
      final b = await newList('ب', DateTime(2026, 1, 1), [('B2', 1000)]);
      await lists.withdraw(a, user: shop.admin);
      await lists.withdraw(b, user: shop.admin);
      expect(await lists.removeWithdrawn(user: shop.admin), 2);
      final left = (await lists.summaries()).map((s) => s.list.id);
      expect(left, isNot(contains(a)));
      expect(left, isNot(contains(b)));
    });
  });

  group('products', () {
    test('an unused product is deleted and unlinked from its list; a used one is kept with the reason', () async {
      await buy(3);
      final r = await ProductService(shop.db).deleteUnused([shop.mixer.id, shop.pipe.id], user: shop.admin);
      expect(r.deleted, 1);
      expect(r.keptIds, [shop.mixer.id]);
      expect(r.kept.values.single, contains('فاتورة شراء'));
      final row = await (shop.db.select(shop.db.priceListItems)..where((i) => i.manufacturerCode.equals('P1'))).getSingle();
      expect((row.productId, row.status), (null, 'skipped'));
    });

    test('only the catalogue role deletes products', () async {
      await expectLater(
        ProductService(shop.db).deleteUnused([shop.pipe.id], user: shop.cashier),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('customers and suppliers', () {
    test('one with no dealings is deleted, its opening balance leaves the books; one with dealings is refused',
        () async {
      final parties = PartyService(shop.db);
      final c = await parties.saveCustomer(const CustomerInput(name: 'خطأ', openingBalance: 50000));
      final ledger = LedgerService(shop.db);
      await ledger.catchUp();
      Future<int> receivables() async =>
          (await ledger.balances()).where((b) => b.account.systemKey == 'ar').fold<int>(0, (s, b) => s + b.closing);
      expect(await receivables(), 50000);
      await parties.deleteParty(customer: true, id: c, userId: shop.admin.id);
      await ledger.catchUp();
      expect(await receivables(), 0);
      expect(await (shop.db.select(shop.db.customers)..where((t) => t.id.equals(c))).getSingleOrNull(), isNull);

      await buy(1);
      await expectLater(
        parties.deleteParty(customer: false, id: shop.supplierId),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('payments', () {
    test('a wrong supplier payment is moved to the right supplier, off the invoice it paid', () async {
      final inv = await buy(2, paid: 20000);
      final other = await PartyService(shop.db).saveSupplier(const SupplierInput(name: 'المورد الصحيح'));
      final pay = await (shop.db.select(shop.db.payments)..where((p) => p.invoiceRefId.equals(inv.id))).getSingle();
      await PaymentService(shop.db).correct(pay.id, partyId: other, method: PaymentMethod.bank, user: shop.admin);
      final p = await (shop.db.select(shop.db.payments)..where((t) => t.id.equals(pay.id))).getSingle();
      expect((p.partyId, p.method, p.invoiceRefId), (other, PaymentMethod.bank, null));
      final balances = BalanceService(shop.db);
      expect(await balances.supplierBalance(shop.supplierId), 60000, reason: 'the whole invoice is owed again');
      expect(await balances.supplierBalance(other), -20000, reason: 'paid ahead to the right supplier');
    });

    test('any payment is deleted from one place; an advance with it, unless invoices use it', () async {
      final payments = PaymentService(shop.db);
      final p = await payments.pay(PaymentInput(partyId: shop.supplierId, amount: 5000), user: shop.admin);
      await payments.remove(p.id, user: shop.admin);
      expect((await (shop.db.select(shop.db.payments)..where((t) => t.id.equals(p.id))).getSingle()).status,
          DocStatus.cancelled);

      final advances = SupplierAdvanceService(shop.db);
      final a = await advances.create(supplierId: shop.supplierId, amount: 100000, user: shop.admin);
      await payments.remove(a.paymentId, user: shop.admin);
      expect((await (shop.db.select(shop.db.supplierAdvances)..where((t) => t.id.equals(a.id))).getSingle()).status,
          DocStatus.cancelled);

      final b = await advances.create(supplierId: shop.supplierId, amount: 100000, user: shop.admin);
      final inv = await buy(1);
      await advances.allocate(invoiceId: inv.id, amount: 30000, user: shop.admin);
      await expectLater(payments.remove(b.paymentId, user: shop.admin), throwsA(isA<ValidationException>()));
    });

    test('a cheque does not turn into cash', () async {
      final p = await PaymentService(shop.db).pay(
        PaymentInput(
          partyId: shop.supplierId,
          amount: 5000,
          method: PaymentMethod.cheque,
          cheque: ChequeInput(number: '1', bank: 'بنك', dueDate: DateTime.now()),
        ),
        user: shop.admin,
      );
      await expectLater(
        PaymentService(shop.db).correct(p.id, method: PaymentMethod.cash, user: shop.admin),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  test('no reason is needed to cancel a sale', () async {
    await buy(5);
    final inv = await SalesService(shop.db).post(
      SaleInput(
        customerId: shop.customerId,
        lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000, priceListId: shop.priceListId)],
      ),
      userId: shop.admin.id,
    );
    await SalesService(shop.db).cancel(inv.id, reason: '', user: shop.admin);
    expect((await (shop.db.select(shop.db.salesInvoices)..where((t) => t.id.equals(inv.id))).getSingle()).status,
        DocStatus.cancelled);
  });

  test('one purchase is received into two places, and cancelling takes each back from its place', () async {
    final showroom = await LocationService(shop.db).create(name: 'المعرض');
    final inv = await buy(0, lines: [
      PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(6), unitCost: 30000),
      PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(4), unitCost: 30000, locationId: showroom),
    ]);
    final stock = StockService(shop.db);
    expect(await stock.currentStock(shop.mixer.id, locationId: mainLocationId), qtyOf(6));
    expect(await stock.currentStock(shop.mixer.id, locationId: showroom), qtyOf(4));
    await PurchaseService(shop.db).cancel(inv.id, reason: '', user: shop.admin);
    expect(await stock.currentStock(shop.mixer.id, locationId: mainLocationId), 0);
    expect(await stock.currentStock(shop.mixer.id, locationId: showroom), 0);
  });
}
