import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/services/balance_service.dart';
import 'package:sanitaryware_erp/core/services/buying_policy_service.dart';
import 'package:sanitaryware_erp/core/services/doc_types.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/payment_service.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_order_service.dart';

import '../support/fixture.dart';

void main() {
  late Shop shop;
  late PurchaseOrderService orders;
  late PriceListService lists;

  setUp(() async {
    shop = await Shop.open();
    orders = PurchaseOrderService(shop.db);
    lists = PriceListService(shop.db);
    final list = await lists.createVersion(
      PriceListHeader(
        name: 'القديمة',
        brandId: shop.brandId,
        listType: 'عام',
        effectiveFrom: DateTime.now().subtract(const Duration(days: 30)),
      ),
      rows: [PriceRowInput(name: 'خلاط', price: 100000, productId: shop.mixer.id)],
      user: shop.admin,
    );
    await BuyingPolicyService(shop.db).add(
      BuyingPolicyInput(
        supplierId: shop.supplierId,
        brandId: shop.brandId,
        priceListId: list.id,
        baseDiscountBp: 1000,
      ),
      user: shop.admin,
    );
  });

  /// A new, dearer version arrives after approval.
  Future<void> newVersion() => lists.createVersion(
        PriceListHeader(name: 'الجديدة', brandId: shop.brandId, listType: 'عام', effectiveFrom: DateTime.now()),
        rows: [PriceRowInput(name: 'خلاط', price: 120000, productId: shop.mixer.id)],
        user: shop.admin,
      );
  tearDown(() => shop.close());

  Future<int> draft(int count) => orders.createDraft(
        supplierId: shop.supplierId,
        lines: [PoLineInput(productId: shop.mixer.id, qty: shop.pieces(count))],
        user: shop.admin,
      );

  test('approval freezes the list price and discount', () async {
    final id = await draft(10);
    await orders.approve(id, user: shop.admin);
    await newVersion();
    final d = await orders.detail(id);
    final line = d.lines.single.line;
    expect(d.order.status, PoStatus.approved);
    expect(line.listPrice, 100000);
    expect(line.discountBp, 1000);
    expect(line.unitCost, 90000);
    expect(d.orderedValue, 900000);
  });

  test('partial receipts use the frozen price and keep the order open', () async {
    final id = await draft(10);
    await orders.approve(id, user: shop.admin);
    await newVersion();
    final lineId = (await orders.detail(id)).lines.single.line.id;

    final inv = await orders.receive(id, qtyByLine: {lineId: shop.pieces(4)}, user: shop.admin);
    expect(inv.total, 360000);
    expect(await shop.stockOf(shop.mixer), shop.pieces(4));
    expect(await shop.costOf(shop.mixer), 90000);
    expect(await shop.supplierBalance(), 360000);
    var d = await orders.detail(id);
    expect(d.order.status, PoStatus.partlyReceived);
    expect(d.lines.single.remaining, shop.pieces(6));
    expect(d.remainingValue, 540000);

    await expectLater(orders.receive(id, qtyByLine: {lineId: shop.pieces(7)}, user: shop.admin),
        throwsA(isA<ValidationException>()));

    await orders.receive(id, qtyByLine: {lineId: shop.pieces(6)}, user: shop.admin);
    d = await orders.detail(id);
    expect(d.order.status, PoStatus.received);
    expect(await shop.stockOf(shop.mixer), shop.pieces(10));
    await expectLater(orders.receive(id, qtyByLine: {lineId: shop.pieces(1)}, user: shop.admin),
        throwsA(isA<ValidationException>()));
  });

  test('a manual cost overrides the lists; a line with neither list nor cost is refused', () async {
    final id = await orders.createDraft(
      supplierId: shop.supplierId,
      lines: [
        PoLineInput(productId: shop.mixer.id, qty: shop.pieces(1)),
        PoLineInput(productId: shop.pipe.id, qty: shop.pieces(1)),
      ],
      user: shop.admin,
    );
    final mixerLine = (await orders.detail(id)).lines.first.line.id;
    // The first version's list closed for the mixer's list type, so the pipe has no price in force.
    await expectLater(
      orders.approve(id, manualCosts: {mixerLine: 80000}, user: shop.admin),
      throwsA(isA<ValidationException>()),
    );
    final pipeLine = (await orders.detail(id)).lines.last.line.id;
    await orders.approve(id, manualCosts: {mixerLine: 80000, pipeLine: 1500}, user: shop.admin);
    final d = await orders.detail(id);
    expect(d.lines[0].line.unitCost, 80000);
    expect(d.lines[0].line.listPrice, isNull);
    expect(d.lines[1].line.unitCost, 1500);
  });

  test('drafts can be cancelled, received orders cannot', () async {
    final a = await draft(2);
    await orders.cancel(a, user: shop.admin);
    expect((await orders.detail(a)).order.status, PoStatus.cancelled);
    await expectLater(orders.approve(a, user: shop.admin), throwsA(isA<ValidationException>()));

    final b = await draft(2);
    await orders.approve(b, user: shop.admin);
    final lineId = (await orders.detail(b)).lines.single.line.id;
    await orders.receive(b, qtyByLine: {lineId: shop.pieces(1)}, user: shop.admin);
    await expectLater(orders.cancel(b, user: shop.admin), throwsA(isA<ValidationException>()));
  });

  test('only the admin can use purchase orders; empty orders are refused', () async {
    await expectLater(
        orders.createDraft(
            supplierId: shop.supplierId,
            lines: [PoLineInput(productId: shop.mixer.id, qty: shop.pieces(1))],
            user: shop.cashier),
        throwsA(isA<ValidationException>()));
    await expectLater(orders.createDraft(supplierId: shop.supplierId, lines: const [], user: shop.admin),
        throwsA(isA<ValidationException>()));
  });

  test('numbers run PO-000001, PO-000002', () async {
    final a = await draft(1);
    final b = await draft(1);
    expect((await orders.detail(a)).order.number, 'PO-000001');
    expect((await orders.detail(b)).order.number, 'PO-000002');
  });

  test('schema 7 upgrades to 8 and keeps its data', () async {
    final dir = await Directory.systemTemp.createTemp('erp_v8');
    final file = File('${dir.path}/shop.db');
    try {
      var d = AppDatabase(NativeDatabase(file));
      await d.into(d.suppliers).insert(SuppliersCompanion.insert(name: 'مورد'));
      await d.customStatement('DROP TABLE purchase_order_receipts');
      await d.customStatement('DROP TABLE purchase_order_lines');
      await d.customStatement('DROP TABLE purchase_orders');
      await d.customStatement('PRAGMA user_version = 7');
      await d.close();

      d = AppDatabase(NativeDatabase(file));
      expect((await d.select(d.suppliers).get()).single.name, 'مورد');
      expect(await d.select(d.purchaseOrders).get(), isEmpty);
      await d.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('an advance to the supplier sits as supplier credit; admin only', () async {
    final id = await draft(2);
    await orders.approve(id, user: shop.admin);
    final payments = PaymentService(shop.db);
    await payments.payAdvance(id, amount: 50000, user: shop.admin);
    expect(await payments.advancesOn(RefType.purchaseOrder, id), 50000);
    expect(await shop.supplierBalance(), -50000);
    await expectLater(payments.payAdvance(id, amount: 1000, user: shop.cashier),
        throwsA(isA<ValidationException>()));
  });

  test('receiving puts the advance onto the supplier invoice', () async {
    final id = await draft(2); // 2 x 900.00 = 1,800.00
    await orders.approve(id, user: shop.admin);
    await PaymentService(shop.db).payAdvance(id, amount: 50000, user: shop.admin);
    final lineId = (await orders.detail(id)).lines.single.line.id;
    final inv = await orders.receive(id, qtyByLine: {lineId: shop.pieces(2)}, user: shop.admin);
    expect(inv.total, 180000);
    final balances = BalanceService(shop.db);
    expect(await balances.paidOnInvoice(RefType.purchaseInvoice, inv.id), 50000);
    expect(await PaymentService(shop.db).advancesOn(RefType.purchaseOrder, id), 0);
    expect(await shop.supplierBalance(), 130000);
  });
}
