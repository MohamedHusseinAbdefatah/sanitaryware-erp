import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/pricing_math.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/approval_service.dart';
import 'package:sanitaryware_erp/core/services/buying_policy_service.dart';
import 'package:sanitaryware_erp/core/services/catalog_service.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_order_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/sale_preview_service.dart';
import 'package:sanitaryware_erp/core/services/sales_order_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/selling_policy_service.dart';

import '../support/fixture.dart';

/// Blueprint 3.4 and the worked examples on its page 10.
void main() {
  late Shop shop;
  late AppDatabase db;
  late int duravit, supplierA, supplierB, ceramicCat;
  late int listId;
  late Product basin;
  late BuyingPolicyService buying;
  late SellingPolicyService selling;

  setUp(() async {
    shop = await Shop.open();
    db = shop.db;
    final catalog = CatalogService(db);
    duravit = await catalog.saveBrand(name: 'Duravit');
    ceramicCat = await catalog.saveCategory(name: 'سيراميك');
    supplierA = await PartyService(db).saveSupplier(const SupplierInput(name: 'A'));
    supplierB = await PartyService(db).saveSupplier(const SupplierInput(name: 'B'));
    final piece = (await db.select(db.units).get()).firstWhere((u) => !u.allowDecimal).id;
    basin = await ProductService(db).create(ProductInput(
      nameAr: 'حوض',
      manufacturerCode: 'D-1',
      brandId: duravit,
      categoryId: ceramicCat,
      unitId: piece,
    ));
    listId = (await PriceListService(db).createVersion(
      PriceListHeader(name: 'ديورافيت', brandId: duravit, listType: 'سيراميك', effectiveFrom: DateTime(2026, 1, 1)),
      rows: [PriceRowInput(name: 'حوض', price: 100000, productId: basin.id)], // list 1,000
      user: shop.admin,
    ))
        .id;
    buying = BuyingPolicyService(db);
    selling = SellingPolicyService(db);
  });
  tearDown(() => shop.close());

  Future<int> buyPolicy(int supplier, int bp, {String scope = PolicyScope.all, int? cat, int? product, int extra = 0}) =>
      buying.add(
        BuyingPolicyInput(
          supplierId: supplier,
          brandId: duravit,
          priceListId: listId,
          scope: scope,
          categoryId: cat,
          productId: product,
          baseDiscountBp: bp,
          extraDiscountBp: extra,
        ),
        user: shop.admin,
      );

  Future<int> sellPolicy(String type, int bp, {String scope = PolicyScope.all, int? cat, int? product, int? max, int? minMargin}) =>
      selling.add(
        SellingPolicyInput(
          brandId: duravit,
          priceListId: listId,
          pricingType: type,
          scope: scope,
          categoryId: cat,
          productId: product,
          discountBp: bp,
          maxDiscountBp: max,
          minMarginBp: minMargin,
        ),
        user: shop.admin,
      );

  Future<BuyQuote> buyQuote(int supplier) async => (await buying.quotes(basin.id, supplierId: supplier)).single;

  group('buying policies', () {
    test('Supplier A and Supplier B on the same brand have their own terms', () async {
      await buyPolicy(supplierA, 3000);
      await buyPolicy(supplierB, 2500);
      expect((await buyQuote(supplierA)).netCost, 70000);
      expect((await buyQuote(supplierB)).netCost, 75000);
    });

    test('exception priority: product, then category, then all', () async {
      await buyPolicy(supplierA, 1000);
      expect((await buyQuote(supplierA)).baseBp, 1000);
      await buyPolicy(supplierA, 2000, scope: PolicyScope.category, cat: ceramicCat);
      expect((await buyQuote(supplierA)).baseBp, 2000);
      await buyPolicy(supplierA, 3000, scope: PolicyScope.product, product: basin.id);
      expect((await buyQuote(supplierA)).baseBp, 3000);
    });

    test('base and extra purchase discounts are both recorded', () async {
      await buyPolicy(supplierA, 3000, extra: 200);
      final q = await buyQuote(supplierA);
      expect(q.baseBp, 3000);
      expect(q.extraBp, 200);
      expect(q.netCost, 68000);
    });

    test('with no recorded policy no percentage is assumed', () async {
      final q = await buyQuote(supplierA);
      expect(q.missingPolicy, isTrue);
      expect(q.netCost, isNull);
    });

    test('a policy needs a brand matching its price list', () async {
      await expectLater(
        buying.add(
          BuyingPolicyInput(supplierId: supplierA, brandId: shop.brandId, priceListId: listId, baseDiscountBp: 100),
          user: shop.admin,
        ),
        throwsA(isA<ValidationException>()),
      );
    });

    test('a purchase order approves from the policy, or refuses and asks for the cost', () async {
      final orders = PurchaseOrderService(db);
      final id = await orders.createDraft(
        supplierId: supplierA,
        lines: [PoLineInput(productId: basin.id, qty: qtyOf(2))],
        user: shop.admin,
      );
      await expectLater(orders.approve(id, user: shop.admin), throwsA(isA<ValidationException>()));
      final policy = await buyPolicy(supplierA, 3000, extra: 100);
      await orders.approve(id, user: shop.admin);
      final line = (await orders.detail(id)).lines.single.line;
      expect(line.priceListId, listId);
      expect(line.listPrice, 100000);
      expect(line.buyingPolicyId, policy);
      expect(line.discountBp, 3000);
      expect(line.extraDiscountBp, 100);
      expect(line.unitCost, 69000);

      final inv = await orders.receive(id, qtyByLine: {line.id: qtyOf(2)}, user: shop.admin);
      final item = await (db.select(db.purchaseInvoiceItems)..where((t) => t.invoiceId.equals(inv.id))).getSingle();
      expect(item.priceListId, listId);
      expect(item.buyingPolicyId, policy);
      expect(item.baseDiscountBp, 3000);
    });

    test('buying and selling are independent: changing one leaves the other', () async {
      await buyPolicy(supplierA, 3000);
      await sellPolicy(PricingType.b2c, 2000);
      final buyId = (await db.select(db.buyingPolicies).get()).single.id;
      await buying.setActive(buyId, false, user: shop.admin);
      final q = (await selling.quotes(basin.id)).single;
      expect(q.policyBp, 2000);
      expect((await buyQuote(supplierA)).missingPolicy, isTrue);
    });
  });

  group('selling policies', () {
    Future<Customer> customer(String level, {int discount = 0}) async {
      final id = await PartyService(db).saveCustomer(CustomerInput(
        name: 'c$level$discount',
        priceLevel: level,
        discountBp: discount,
      ));
      return (db.select(db.customers)..where((t) => t.id.equals(id))).getSingle();
    }

    test('each pricing type has its own discount', () async {
      await sellPolicy(PricingType.b2c, 500);
      await sellPolicy(PricingType.b2b, 1500);
      await sellPolicy(PricingType.project, 2000);
      Future<int> bp(String level) async => (await selling.quotes(basin.id, customer: await customer(level))).single.policyBp;
      expect(await bp(PriceLevel.retail), 500);
      expect(await bp(PriceLevel.wholesale), 1500);
      expect(await bp(PriceLevel.contractor), 2000);
    });

    test('exception priority: product, then category, then all', () async {
      await sellPolicy(PricingType.b2c, 100);
      await sellPolicy(PricingType.b2c, 200, scope: PolicyScope.category, cat: ceramicCat);
      await sellPolicy(PricingType.b2c, 300, scope: PolicyScope.product, product: basin.id);
      expect((await selling.quotes(basin.id)).single.policyBp, 300);
    });

    test('base 21% and one more point is 22% in total', () async {
      await sellPolicy(PricingType.b2c, 2100);
      final q = (await selling.quotes(basin.id, extraBp: 100)).single;
      expect(q.totalBp, 2200);
      expect(q.unitPrice, 78000);
    });

    test('the customer discount adds to the policy', () async {
      await sellPolicy(PricingType.b2b, 2000);
      final c = await customer(PriceLevel.wholesale, discount: 100);
      final q = (await selling.quotes(basin.id, customer: c)).single;
      expect(q.totalBp, 2100);
    });
  });

  group('sales', () {
    Future<void> stock(int cost, int count) => PurchaseService(db).post(
          PurchaseInput(
            supplierId: supplierA,
            lines: [PurchaseLineInput(productId: basin.id, qty: qtyOf(count), unitCost: cost)],
          ),
          user: shop.admin,
        );

    SaleLineInput line({int unitPrice = 100000, int discount = 0, int count = 1, int? list}) => SaleLineInput(
          productId: basin.id,
          qty: qtyOf(count),
          unitPrice: unitPrice,
          discount: discount,
          priceListId: list ?? listId,
        );

    Future<SalesInvoice> post(List<SaleLineInput> lines, {int discount = 0, User? user, String? reason}) {
      final total = lines.fold<int>(0, (s, l) => s + l.total) - discount;
      return SalesService(db).post(
        SaleInput(lines: lines, discount: discount, paidAmount: total),
        userId: (user ?? shop.admin).id,
        belowCostReason: reason,
      );
    }

    test('the blueprint example: list 1,000, supplier 30%, customer 20%', () async {
      await buyPolicy(supplierA, 3000);
      await stock((await buyQuote(supplierA)).netCost!, 5);
      await sellPolicy(PricingType.b2c, 2000);

      final input = SaleInput(lines: [line(discount: 20000)], paidAmount: 80000);
      final preview = await SalePreviewService(db).preview(input);
      final l = preview.lines.single;
      expect(l.listPrice, 100000);
      expect(l.discounts.single.bp, 2000);
      expect(l.finalUnitPrice, 80000);
      expect(l.expectedCost, 70000);
      expect(l.grossProfit, 10000);
      expect(l.margin, 1250); // 12.5% of the sale
      expect(l.markup, 1429); // 14.29% of the cost
      expect(l.approvals, isEmpty);
      expect(l.vatAmount, isNull, reason: 'VAT is not verified, so no number');

      final inv = await SalesService(db).post(input, userId: shop.cashier.id);
      final item = await (db.select(db.salesInvoiceItems)..where((t) => t.invoiceId.equals(inv.id))).getSingle();
      expect(item.priceListId, listId);
      expect(item.listPrice, 100000);
      expect(item.policyDiscountBp, 2000);
      expect(item.extraDiscountBp, 0);
      expect(item.netTotal, 80000);
      expect(item.unitCost, 70000);
    });

    test('with verified VAT the preview shows it and measures profit without it', () async {
      await PriceListService(db).setVat(listId, vatStatus: VatStatus.inclusive, vatRateBp: 1400, user: shop.admin);
      await stock(50000, 5);
      final preview = await SalePreviewService(db).preview(SaleInput(lines: [line()], paidAmount: 100000));
      final l = preview.lines.single;
      expect(l.vatAmount, 12281); // 1,000.00 inclusive of 14%
      expect(l.netForProfit, 87719);
      expect(l.grossProfit, 37719);
    });

    test('below FIFO cost is refused unless the owner writes the exception', () async {
      await stock(90000, 5);
      await expectLater(post([line(discount: 20000)], user: shop.cashier), throwsA(isA<BelowCostException>()));
      await expectLater(post([line(discount: 20000)]), throwsA(isA<BelowCostException>()));
      final inv = await post([line(discount: 20000)], reason: 'تصفية بموافقة المالك');
      final logged = await ApprovalService(db).forDocument('sales_invoice', inv.id);
      expect(logged.map((a) => a.kind), contains(ApprovalKind.belowCost));
    });

    test('the invoice discount counts in the below-cost check', () async {
      await stock(90000, 5);
      await expectLater(post([line()], discount: 20000), throwsA(isA<BelowCostException>()));
    });

    test('a cashier cannot sell at a price that is not the approved list price', () async {
      await stock(10000, 5);
      await expectLater(post([line(unitPrice: 90000)], user: shop.cashier), throwsA(isA<ApprovalRequiredException>()));
      final inv = await post([line(unitPrice: 90000)]);
      final logged = await ApprovalService(db).forDocument('sales_invoice', inv.id);
      expect(logged.single.kind, ApprovalKind.priceOverride);
    });

    test('a product with no approved price: the cashier is refused; the admin is logged', () async {
      await stock(10000, 5);
      final manual = SaleLineInput(productId: basin.id, qty: qtyOf(1), unitPrice: 50000);
      await expectLater(post([manual], user: shop.cashier), throwsA(isA<ApprovalRequiredException>()));
      final inv = await post([manual]);
      final item = await (db.select(db.salesInvoiceItems)..where((t) => t.invoiceId.equals(inv.id))).getSingle();
      expect(item.priceListId, isNull);
      expect(item.listPrice, isNull);
      expect((await ApprovalService(db).forDocument('sales_invoice', inv.id)).single.kind, ApprovalKind.priceOverride);
    });

    test('a discount past the policy limit needs the manager', () async {
      await stock(10000, 5);
      await sellPolicy(PricingType.b2c, 2000, max: 2500);
      await post([line(discount: 25000)], user: shop.cashier); // exactly the limit
      await expectLater(post([line(discount: 26000)], user: shop.cashier), throwsA(isA<ApprovalRequiredException>()));
      final inv = await post([line(discount: 26000)]);
      expect((await ApprovalService(db).forDocument('sales_invoice', inv.id)).single.kind, ApprovalKind.extraDiscount);
    });

    test('a margin under the policy minimum needs the manager', () async {
      await stock(70000, 5);
      await sellPolicy(PricingType.b2c, 0, minMargin: 2000); // needs 20%; 800 on 700 is 12.5%
      await expectLater(post([line(discount: 20000)], user: shop.cashier), throwsA(isA<ValidationException>()));
      final inv = await post([line(discount: 20000)]);
      expect((await ApprovalService(db).forDocument('sales_invoice', inv.id)).map((a) => a.kind),
          contains(ApprovalKind.lowMargin));
    });

    test('the invoice discount is split over the lines exactly', () {
      expect(allocateProportionally(100, [1, 1, 1]), [34, 33, 33]);
      expect(allocateProportionally(1000, [100000, 300000]), [250, 750]);
      expect(allocateProportionally(0, [5, 5]), [0, 0]);
      expect(allocateProportionally(10, [0, 0]), [5, 5]);
      for (final total in [1, 7, 999, 12345]) {
        final parts = allocateProportionally(total, [333, 667, 1, 12345]);
        expect(parts.reduce((a, b) => a + b), total);
      }
    });

    test('posted lines keep their share; shares add up to the invoice discount', () async {
      await stock(1000, 20);
      final other = await ProductService(db).create(ProductInput(
          nameAr: 'مرحاض', manufacturerCode: 'D-2', brandId: duravit, unitId: basin.unitId));
      await PurchaseService(db).post(
        PurchaseInput(supplierId: supplierA, lines: [PurchaseLineInput(productId: other.id, qty: qtyOf(5), unitCost: 100)]),
        user: shop.admin,
      );
      final inv = await SalesService(db).post(
        SaleInput(
          lines: [
            line(),
            SaleLineInput(productId: other.id, qty: qtyOf(3), unitPrice: 33333),
          ],
          discount: 10001,
          paidAmount: 100000 + 99999 - 10001,
        ),
        userId: shop.admin.id,
      );
      final items = await (db.select(db.salesInvoiceItems)..where((t) => t.invoiceId.equals(inv.id))).get();
      expect(items.fold<int>(0, (s, i) => s + i.invoiceDiscountShare), 10001);
      expect(items.fold<int>(0, (s, i) => s + i.netTotal), inv.total);
    });
  });

  group('price lock', () {
    test('an order approved on V1 keeps V1 after V2 starts; new documents use V2', () async {
      await PurchaseService(db).post(
        PurchaseInput(supplierId: supplierA, lines: [PurchaseLineInput(productId: basin.id, qty: qtyOf(10), unitCost: 10000)]),
        user: shop.admin,
      );
      final customer = await PartyService(db).saveCustomer(const CustomerInput(name: 'ع'));
      final orders = SalesOrderService(db);
      final id = await orders.createDraft(
        customerId: customer,
        lines: [SoLineInput(productId: basin.id, qty: qtyOf(4))],
        user: shop.admin,
      );
      await orders.confirm(id, user: shop.admin);
      final lineId = (await orders.detail(id)).lines.single.line.id;

      final v2 = (await PriceListService(db).createVersion(
        PriceListHeader(
          name: 'V2',
          brandId: duravit,
          listType: 'سيراميك',
          effectiveFrom: DateTime.now(),
        ),
        rows: [PriceRowInput(name: 'حوض', price: 150000, productId: basin.id)],
        user: shop.admin,
      ))
          .id;
      expect(v2, isNot(listId));

      final inv = await orders.deliver(id, qtyByLine: {lineId: qtyOf(2)}, user: shop.cashier);
      final item = await (db.select(db.salesInvoiceItems)..where((t) => t.invoiceId.equals(inv.id))).getSingle();
      expect(item.priceListId, listId);
      expect(item.listPrice, 100000);
      expect(item.unitPrice, 100000);

      final later = await orders.createDraft(
        customerId: customer,
        lines: [SoLineInput(productId: basin.id, qty: qtyOf(1))],
        user: shop.admin,
      );
      await orders.confirm(later, user: shop.admin);
      expect((await orders.detail(later)).lines.single.line.priceListId, v2);
      expect((await orders.detail(later)).lines.single.line.unitPrice, 150000);
    });

    test('an order cannot be confirmed with no approved price unless the admin types one', () async {
      final loose = await ProductService(db).create(ProductInput(nameAr: 'بلا سعر', unitId: basin.unitId));
      final customer = await PartyService(db).saveCustomer(const CustomerInput(name: 'ع'));
      final orders = SalesOrderService(db);
      final id = await orders.createDraft(
        customerId: customer,
        lines: [SoLineInput(productId: loose.id, qty: qtyOf(1))],
        user: shop.admin,
      );
      await expectLater(orders.confirm(id, user: shop.admin), throwsA(isA<ValidationException>()));
      final lineId = (await orders.detail(id)).lines.single.line.id;
      await expectLater(
        orders.confirm(id, manualPrices: {lineId: 5000}, user: shop.cashier),
        throwsA(isA<ValidationException>()),
      );
      await orders.confirm(id, manualPrices: {lineId: 5000}, user: shop.admin);
      expect((await orders.detail(id)).lines.single.line.unitPrice, 5000);
      expect((await ApprovalService(db).forDocument('sales_order', id)).single.kind, ApprovalKind.priceOverride);
    });

    test('two lists in force: the order must say which', () async {
      final tubs = (await PriceListService(db).createVersion(
        PriceListHeader(name: 'بانيوهات', brandId: duravit, listType: 'بانيوهات', effectiveFrom: DateTime(2026, 1, 1)),
        rows: [PriceRowInput(name: 'حوض', price: 110000, productId: basin.id)],
        user: shop.admin,
      ))
          .id;
      final customer = await PartyService(db).saveCustomer(const CustomerInput(name: 'ع'));
      final orders = SalesOrderService(db);
      final open = await orders.createDraft(
        customerId: customer,
        lines: [SoLineInput(productId: basin.id, qty: qtyOf(1))],
        user: shop.admin,
      );
      await expectLater(orders.confirm(open, user: shop.admin), throwsA(isA<ValidationException>()));
      final chosen = await orders.createDraft(
        customerId: customer,
        lines: [SoLineInput(productId: basin.id, qty: qtyOf(1), priceListId: tubs)],
        user: shop.admin,
      );
      await orders.confirm(chosen, user: shop.admin);
      expect((await orders.detail(chosen)).lines.single.line.listPrice, 110000);
    });
  });
}
