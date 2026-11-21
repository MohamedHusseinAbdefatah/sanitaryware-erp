import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/audit_service.dart';
import 'package:sanitaryware_erp/core/services/buying_policy_service.dart';
import 'package:sanitaryware_erp/core/services/catalog_service.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/payment_service.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/selling_policy_service.dart';
import 'package:sanitaryware_erp/core/services/stock_entry_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';
import 'package:sanitaryware_erp/core/services/supplier_advance_service.dart';

import '../support/fixture.dart';

/// Version 2.4: the owner's real-world scenarios for money and stock.
void main() {
  late Shop shop;

  setUp(() async => shop = await Shop.open());
  tearDown(() => shop.close());

  Future<AuditLog> lastAudit() async => (await (shop.db.select(shop.db.auditLogs)
            ..orderBy([(t) => OrderingTerm.desc(t.id)])
            ..limit(1))
          .get())
      .single;

  group('a supplier advance used on two brands', () {
    test('100,000 paid ahead; 30,000 on a Duravit invoice and 20,000 on an Ideal Standard one', () async {
      final catalog = CatalogService(shop.db);
      final products = ProductService(shop.db);
      final lists = PriceListService(shop.db);
      final duravit = await catalog.saveBrand(name: 'Duravit');
      final ideal = await catalog.saveBrand(name: 'Ideal Standard');
      final basin = await products.create(ProductInput(nameAr: 'حوض', manufacturerCode: 'D1', brandId: duravit));
      final wc = await products.create(ProductInput(nameAr: 'مرحاض', manufacturerCode: 'I1', brandId: ideal));
      final dList = (await lists.createVersion(
        PriceListHeader(name: 'Duravit', brandId: duravit, listType: 'سيراميك', effectiveFrom: DateTime(2024)),
        rows: [PriceRowInput(name: 'حوض', price: 1500000, productId: basin.id)],
        user: shop.admin,
      ))
          .id;
      final iList = (await lists.createVersion(
        PriceListHeader(name: 'Ideal', brandId: ideal, listType: 'سيراميك', effectiveFrom: DateTime(2024)),
        rows: [PriceRowInput(name: 'مرحاض', price: 1000000, productId: wc.id)],
        user: shop.admin,
      ))
          .id;

      final advances = SupplierAdvanceService(shop.db);
      await advances.create(supplierId: shop.supplierId, amount: 10000000, user: shop.admin);
      expect(await shop.supplierBalance(), -10000000);

      final purchases = PurchaseService(shop.db);
      final first = await purchases.post(
        PurchaseInput(
          supplierId: shop.supplierId,
          advanceAmount: 3000000,
          lines: [
            PurchaseLineInput(
                productId: basin.id, qty: qtyOf(4), unitCost: 1500000, priceListId: dList, listPrice: 1500000),
          ],
        ),
        user: shop.admin,
      );
      final second = await purchases.post(
        PurchaseInput(
          supplierId: shop.supplierId,
          advanceAmount: 2000000,
          paidAmount: 500000,
          lines: [
            PurchaseLineInput(productId: wc.id, qty: qtyOf(3), unitCost: 1000000, priceListId: iList, listPrice: 1000000),
          ],
        ),
        user: shop.admin,
      );

      final b = await advances.balance(shop.supplierId);
      expect(b.paid, 10000000);
      expect(b.allocated, 5000000);
      expect(b.remaining, 5000000, reason: '100,000 - 30,000 - 20,000');
      final uses = await advances.allocations(supplierId: shop.supplierId);
      expect(uses.map((u) => (u.invoiceNumber, u.allocation.amount)).toSet(),
          {(first.number, 3000000), (second.number, 2000000)});
      expect((await purchases.detail(first.id)).paid, 3000000);
      expect((await purchases.detail(second.id)).paid, 2500000, reason: '20,000 from the advance + 5,000 cash');
      // Owed: 60,000 + 30,000 bought; paid 100,000 ahead + 5,000 cash.
      expect(await shop.supplierBalance(), 6000000 + 3000000 - 10000000 - 500000);

      // The owner corrects the second invoice's use of the advance to 25,000.
      await advances.correctInvoiceAllocation(second.id, 2500000, reason: 'خطأ في المبلغ', user: shop.admin);
      expect((await advances.balance(shop.supplierId)).remaining, 4500000);
      expect((await purchases.detail(second.id)).paid, 3000000);
      await expectLater(
        advances.correctInvoiceAllocation(second.id, 0, reason: 'x', user: shop.cashier),
        throwsA(isA<ValidationException>()),
      );
      expect((await lastAudit()).action, AuditAction.correct);
    });
  });

  group('owner corrects a supplier payment', () {
    test('the balance and the invoice follow; the old and new values and reason are logged', () async {
      final payments = PaymentService(shop.db);
      final p = await payments.pay(PaymentInput(partyId: shop.supplierId, amount: 100000), user: shop.admin);
      expect(await shop.supplierBalance(), -100000);

      await payments.correct(p.id, amount: 80000, reason: 'كُتب 1000 والصحيح 800', user: shop.admin);
      expect(await shop.supplierBalance(), -80000);
      final log = await lastAudit();
      expect(log.action, AuditAction.correct);
      expect(log.entity, 'payment');
      expect(log.oldValue, contains('1,000.00'));
      expect(log.newValue, contains('800.00'));
      expect(log.reason, 'كُتب 1000 والصحيح 800');
      expect(log.userId, shop.admin.id);
      final fresh = await (shop.db.select(shop.db.payments)..where((t) => t.id.equals(p.id))).getSingle();
      expect(fresh.number, p.number, reason: 'the payment keeps its number');
    });

    test('only the owner; never past an invoice; never below what an advance already gave', () async {
      final payments = PaymentService(shop.db);
      final inv = await PurchaseService(shop.db).post(
        PurchaseInput(
          supplierId: shop.supplierId,
          paidAmount: 30000,
          lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitCost: 40000)],
        ),
        user: shop.admin,
      );
      final onInvoice = (await payments.onInvoice('purchase_invoice', inv.id)).single;
      await expectLater(payments.correct(onInvoice.id, amount: 20000, reason: 'x', user: shop.cashier),
          throwsA(isA<ValidationException>()));
      await expectLater(payments.correct(onInvoice.id, amount: 50000, reason: 'x', user: shop.admin),
          throwsA(isA<ValidationException>()), reason: 'the invoice is 400');
      await payments.correct(onInvoice.id, amount: 40000, reason: 'دُفعت كاملة', user: shop.admin);
      expect((await PurchaseService(shop.db).detail(inv.id)).paid, 40000);

      final advances = SupplierAdvanceService(shop.db);
      final a = await advances.create(supplierId: shop.supplierId, amount: 100000, user: shop.admin);
      final inv2 = await PurchaseService(shop.db).post(
        PurchaseInput(
          supplierId: shop.supplierId,
          advanceAmount: 60000,
          lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(2), unitCost: 40000)],
        ),
        user: shop.admin,
      );
      expect(inv2.total, 80000);
      await expectLater(payments.correct(a.paymentId, amount: 50000, reason: 'x', user: shop.admin),
          throwsA(isA<ValidationException>()), reason: '60,000 of it was already used');
      await payments.correct(a.paymentId, amount: 70000, reason: 'المبلغ الصحيح', user: shop.admin);
      expect((await advances.row(a.id)).advance.amount, 70000);
      expect((await advances.balance(shop.supplierId)).remaining, 10000);
    });
  });

  group('purchase policy corrected', () {
    test('a saved invoice keeps its discount; the next one uses the corrected one', () async {
      final buying = BuyingPolicyService(shop.db);
      final id = await buying.add(
        BuyingPolicyInput(
            supplierId: shop.supplierId, brandId: shop.brandId, priceListId: shop.priceListId, baseDiscountBp: 2000),
        user: shop.admin,
      );
      final q = (await buying.quotes(shop.mixer.id, supplierId: shop.supplierId)).first;
      expect(q.netCost, 40000);
      final inv = await PurchaseService(shop.db).post(
        PurchaseInput(supplierId: shop.supplierId, lines: [
          PurchaseLineInput(
              productId: shop.mixer.id,
              qty: qtyOf(1),
              unitCost: q.netCost!,
              priceListId: q.quote.priceListId,
              listPrice: q.listPrice,
              buyingPolicyId: id,
              baseDiscountBp: 2000),
        ]),
        user: shop.admin,
      );

      await expectLater(
        buying.correct(id, baseDiscountBp: 2500, extraDiscountBp: 0, reason: 'x', user: shop.cashier),
        throwsA(isA<ValidationException>()),
      );
      await buying.correct(id, baseDiscountBp: 2500, extraDiscountBp: 0, reason: 'الخصم الصحيح 25%', user: shop.admin);
      expect((await buying.quotes(shop.mixer.id, supplierId: shop.supplierId)).first.netCost, 37500);
      final kept = (await PurchaseService(shop.db).detail(inv.id)).lines.single.item;
      expect((kept.baseDiscountBp, kept.unitCost), (2000, 40000), reason: 'history is not rewritten');
      final log = await lastAudit();
      expect((log.oldValue, log.newValue), ('20.0% + 0.0%', '25.0% + 0.0%'));
    });
  });

  group('sales discount by brand and customer type', () {
    test('Duravit 10%, Ideal Standard 5% for one customer type; a sold invoice keeps its price', () async {
      final catalog = CatalogService(shop.db);
      final products = ProductService(shop.db);
      final lists = PriceListService(shop.db);
      final selling = SellingPolicyService(shop.db);
      final duravit = await catalog.saveBrand(name: 'Duravit');
      final ideal = await catalog.saveBrand(name: 'Ideal Standard');
      final basin = await products.create(ProductInput(nameAr: 'حوض', manufacturerCode: 'D1', brandId: duravit));
      final wc = await products.create(ProductInput(nameAr: 'مرحاض', manufacturerCode: 'I1', brandId: ideal));
      await lists.createVersion(
        PriceListHeader(name: 'D', brandId: duravit, listType: 'عام', effectiveFrom: DateTime(2024)),
        rows: [PriceRowInput(name: 'حوض', price: 100000, productId: basin.id)],
        user: shop.admin,
      );
      await lists.createVersion(
        PriceListHeader(name: 'I', brandId: ideal, listType: 'عام', effectiveFrom: DateTime(2024)),
        rows: [PriceRowInput(name: 'مرحاض', price: 100000, productId: wc.id)],
        user: shop.admin,
      );
      final retail = (await selling.categories()).first;

      await selling.setBrandDiscount(customerCategoryId: retail.id, brandId: duravit, discountBp: 1000, user: shop.admin);
      await selling.setBrandDiscount(customerCategoryId: retail.id, brandId: ideal, discountBp: 500, user: shop.admin);
      Future<SellQuote> q(Product p) async => (await selling.quotes(p.id)).single;
      expect((await q(basin)).unitPrice, 90000);
      expect((await q(wc)).unitPrice, 95000);
      expect((await q(basin)).policyBp, 1000);

      // Sold at 10%, then Duravit changes to 12%: the invoice keeps 10%.
      await PurchaseService(shop.db).post(
        PurchaseInput(supplierId: shop.supplierId, lines: [PurchaseLineInput(productId: basin.id, qty: qtyOf(1), unitCost: 50000)]),
        user: shop.admin,
      );
      final quote = await q(basin);
      final sale = await SalesService(shop.db).post(
        SaleInput(paidAmount: 90000, lines: [
          SaleLineInput(productId: basin.id, qty: qtyOf(1), unitPrice: quote.listPrice, priceListId: quote.quote.priceListId,
              discount: quote.listPrice - quote.unitPrice),
        ]),
        userId: shop.admin.id,
      );
      await selling.setBrandDiscount(customerCategoryId: retail.id, brandId: duravit, discountBp: 1200, user: shop.admin);
      expect((await q(basin)).unitPrice, 88000);
      final kept = (await SalesService(shop.db).detail(sale.id)).lines.single.item;
      expect(kept.lineTotal, 90000);
      expect(kept.policyDiscountBp, 1000);

      // Back to the category's usual discount.
      await selling.setBrandDiscount(customerCategoryId: retail.id, brandId: duravit, discountBp: null, user: shop.admin);
      expect((await q(basin)).policyBp, retail.discountBp);
      await expectLater(
        selling.setBrandDiscount(customerCategoryId: retail.id, brandId: ideal, discountBp: 700, user: shop.cashier),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('purchase invoice discount', () {
    test('none, a fixed amount and a percent are all kept as typed', () async {
      final purchases = PurchaseService(shop.db);
      PurchaseInput input({int discount = 0, int? bp}) => PurchaseInput(
            supplierId: shop.supplierId,
            discount: discount,
            discountBp: bp,
            lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(2), unitCost: 50000)],
          );
      final none = await purchases.post(input(), user: shop.admin);
      expect((none.subtotal, none.discount, none.total, none.discountBp), (100000, 0, 100000, null));
      final fixed = await purchases.post(input(discount: 15000), user: shop.admin);
      expect((fixed.discount, fixed.total, fixed.discountBp), (15000, 85000, null));
      final pct = await purchases.post(input(discount: 10000, bp: 1000), user: shop.admin);
      expect((pct.discount, pct.total, pct.discountBp), (10000, 90000, 1000));
      await expectLater(purchases.post(input(discount: 100001), user: shop.admin), throwsA(isA<ValidationException>()));
    });

    test('the owner corrects a saved invoice: quantities change, payments move, the old one stays cancelled', () async {
      final purchases = PurchaseService(shop.db);
      final old = await purchases.post(
        PurchaseInput(
          supplierId: shop.supplierId,
          paidAmount: 50000,
          lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(5), unitCost: 40000)],
        ),
        user: shop.admin,
      );
      expect(await shop.stockOf(shop.mixer), qtyOf(5));
      final fixed = await purchases.correct(
        old.id,
        PurchaseInput(
          supplierId: shop.supplierId,
          lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(3), unitCost: 40000)],
          discount: 2000,
        ),
        reason: 'الكمية 3 لا 5',
        user: shop.admin,
      );
      expect(await shop.stockOf(shop.mixer), qtyOf(3));
      expect(fixed.total, 118000);
      expect((await purchases.detail(fixed.id)).paid, 50000, reason: 'the payment moved over');
      final before = await (shop.db.select(shop.db.purchaseInvoices)..where((t) => t.id.equals(old.id))).getSingle();
      expect(before.status, 'cancelled');
      expect(await shop.supplierBalance(), 118000 - 50000);
      await expectLater(
        purchases.correct(fixed.id, PurchaseInput(supplierId: shop.supplierId, lines: const []), reason: 'x', user: shop.cashier),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('stock entered by hand from a 2024 list', () {
    test('stock and its historical cost come in; no invoice, no payment, no supplier balance', () async {
      final lists = PriceListService(shop.db);
      final old = (await lists.createVersion(
        PriceListHeader(name: '2024', brandId: shop.brandId, listType: 'عام', effectiveFrom: DateTime(2018, 1, 1)),
        rows: [PriceRowInput(name: 'خلاط', price: 40000, productId: shop.mixer.id)],
        user: shop.admin,
      ))
          .id;
      final entries = StockEntryService(shop.db);
      final (price, _) = await entries.priceIn(old, shop.mixer.id);
      expect(price, 40000);
      final e = await entries.enter(
        StockEntryInput(
          lines: [StockEntryLineInput(productId: shop.mixer.id, qty: qtyOf(10), listPrice: price, discountBp: 2500)],
          effectiveDate: DateTime(2019, 3, 1),
          reason: 'مخزون قديم',
          priceListId: old,
          supplierId: shop.supplierId,
        ),
        user: shop.admin,
      );
      expect(e.total, 300000, reason: '10 x (400 less 25%)');
      expect(await shop.stockOf(shop.mixer), qtyOf(10));
      expect(await shop.costOf(shop.mixer), 30000);
      final layer = (await shop.db.select(shop.db.costLayers).get()).single;
      expect((layer.priceListId, layer.listPrice, layer.receivedAt), (old, 40000, DateTime(2019, 3, 1)));
      expect(await shop.db.select(shop.db.purchaseInvoices).get(), isEmpty);
      expect(await shop.db.select(shop.db.payments).get(), isEmpty);
      expect(await shop.supplierBalance(), 0);
      expect(e.createdAt.year, DateTime.now().year, reason: 'entered today, bought in 2019');

      final again = StockEntryInput(
        lines: [StockEntryLineInput(productId: shop.mixer.id, qty: qtyOf(10), listPrice: price, discountBp: 2500)],
        effectiveDate: DateTime(2019, 3, 1),
        reason: 'مرة ثانية',
      );
      await expectLater(entries.enter(again, user: shop.admin), throwsA(isA<DuplicateStockEntryException>()));
      await expectLater(entries.enter(again, user: shop.cashier), throwsA(isA<ValidationException>()));

      await entries.cancel(e.id, reason: 'خطأ', user: shop.admin);
      expect(await shop.stockOf(shop.mixer), 0);
      final moves = await (shop.db.select(shop.db.stockMovements)..where((m) => m.type.equals(StockMovementType.opening))).get();
      expect(moves.map((m) => m.qty), [qtyOf(10), -qtyOf(10)], reason: 'history kept, nothing deleted');
    });
  });

  group('price list categories', () {
    test('فاخر 10% and اقتصادي 4%: the category discount prices a purchase when the supplier has none', () async {
      final lists = PriceListService(shop.db);
      final catalog = CatalogService(shop.db);
      final products = ProductService(shop.db);
      final luxury = await lists.saveCategory(name: 'فاخر', buyingDiscountBp: 1000, user: shop.admin);
      final economy = await lists.saveCategory(name: 'اقتصادي', buyingDiscountBp: 400, user: shop.admin);
      await expectLater(lists.saveCategory(name: 'متوسط', buyingDiscountBp: 700, user: shop.cashier),
          throwsA(isA<ValidationException>()));

      final brandA = await catalog.saveBrand(name: 'A');
      final brandB = await catalog.saveBrand(name: 'B');
      final a = await products.create(ProductInput(nameAr: 'حوض فاخر', manufacturerCode: 'A1', brandId: brandA));
      final b = await products.create(ProductInput(nameAr: 'حوض اقتصادي', manufacturerCode: 'B1', brandId: brandB));
      await lists.createVersion(
        PriceListHeader(name: 'A', brandId: brandA, listType: 'عام', effectiveFrom: DateTime(2024), categoryId: luxury),
        rows: [PriceRowInput(name: 'حوض فاخر', price: 100000, productId: a.id)],
        user: shop.admin,
      );
      final bList = (await lists.createVersion(
        PriceListHeader(name: 'B', brandId: brandB, listType: 'عام', effectiveFrom: DateTime(2024), categoryId: economy),
        rows: [PriceRowInput(name: 'حوض اقتصادي', price: 100000, productId: b.id)],
        user: shop.admin,
      ))
          .id;

      final buying = BuyingPolicyService(shop.db);
      final qa = (await buying.quotes(a.id, supplierId: shop.supplierId)).single;
      expect((qa.fromCategory, qa.baseBp, qa.netCost), (true, 1000, 90000));
      final qb = (await buying.quotes(b.id, supplierId: shop.supplierId)).single;
      expect(qb.netCost, 96000);

      // A supplier's own recorded discount comes first.
      await buying.add(
        BuyingPolicyInput(supplierId: shop.supplierId, brandId: brandB, priceListId: bList, baseDiscountBp: 600),
        user: shop.admin,
      );
      final qb2 = (await buying.quotes(b.id, supplierId: shop.supplierId)).single;
      expect((qb2.fromCategory, qb2.netCost), (false, 94000));

      // Bought under فاخر at 10%; the category then changes to 12%.
      final inv = await PurchaseService(shop.db).post(
        PurchaseInput(supplierId: shop.supplierId, lines: [
          PurchaseLineInput(
            productId: a.id,
            qty: qtyOf(1),
            unitCost: qa.netCost!,
            priceListId: qa.quote.priceListId,
            listPrice: qa.listPrice,
            baseDiscountBp: qa.baseBp,
            listCategoryId: qa.category!.id,
            listCategoryName: qa.category!.name,
          ),
        ]),
        user: shop.admin,
      );
      await lists.saveCategory(id: luxury, name: 'فاخر', buyingDiscountBp: 1200, reason: 'عرض جديد', user: shop.admin);
      expect((await buying.quotes(a.id, supplierId: shop.supplierId)).single.netCost, 88000);
      final kept = (await PurchaseService(shop.db).detail(inv.id)).lines.single.item;
      expect((kept.baseDiscountBp, kept.unitCost, kept.listCategoryName), (1000, 90000, 'فاخر'));

      // A category in use cannot be deleted, only switched off.
      await expectLater(lists.deleteCategory(luxury, user: shop.admin), throwsA(isA<ValidationException>()));
      final unused = await lists.saveCategory(name: 'مؤقت', buyingDiscountBp: 0, user: shop.admin);
      await lists.deleteCategory(unused, user: shop.admin);
      expect((await lists.categories()).map((c) => c.name), containsAll(['فاخر', 'اقتصادي']));
    });
  });
}
