import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/services/approval_service.dart';
import 'package:sanitaryware_erp/core/services/balance_service.dart';
import 'package:sanitaryware_erp/core/services/doc_types.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/payment_service.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/sales_order_service.dart';

import '../support/fixture.dart';

void main() {
  late Shop shop;
  late SalesOrderService orders;
  late int customer;

  setUp(() async {
    shop = await Shop.open();
    orders = SalesOrderService(shop.db);
    // 20 mixers in stock at cost 300.00; retail price is 500.00.
    await PurchaseService(shop.db).post(
      PurchaseInput(
        supplierId: shop.supplierId,
        lines: [PurchaseLineInput(productId: shop.mixer.id, qty: shop.pieces(20), unitCost: 30000)],
      ),
      user: shop.admin,
    );
    customer = await PartyService(shop.db)
        .saveCustomer(const CustomerInput(name: 'مقاول', discountBp: 1000));
  });
  tearDown(() => shop.close());

  Future<int> draft(int count, {int extra = 0, User? user}) => orders.createDraft(
        customerId: customer,
        lines: [SoLineInput(productId: shop.mixer.id, qty: shop.pieces(count), extraDiscountBp: extra)],
        user: user ?? shop.admin,
      );

  test('confirming freezes the price: base 10% + extra 5%', () async {
    final id = await draft(10, extra: 500);
    await orders.confirm(id, user: shop.admin);
    // A dearer version starts afterwards.
    await PriceListService(shop.db).createVersion(
      PriceListHeader(name: 'V2', brandId: shop.brandId, listType: 'عام', effectiveFrom: DateTime.now()),
      rows: [PriceRowInput(name: 'خلاط', price: 60000, productId: shop.mixer.id)],
      user: shop.admin,
    );
    final line = (await orders.detail(id)).lines.single.line;
    expect(line.listPrice, 50000);
    expect(line.customerDiscountBp, 1000);
    expect(line.extraDiscountBp, 500);
    expect(line.unitPrice, 42500); // 500.00 less 15%
  });

  test('partial deliveries use the frozen price and update the order', () async {
    final id = await draft(10);
    await orders.confirm(id, user: shop.admin);
    final lineId = (await orders.detail(id)).lines.single.line.id;

    final inv = await orders.deliver(id, qtyByLine: {lineId: shop.pieces(4)}, user: shop.cashier);
    expect(inv.total, 180000); // 4 x 450.00
    expect(await shop.stockOf(shop.mixer), shop.pieces(16));
    var d = await orders.detail(id);
    expect(d.order.status, SoStatus.partlyDelivered);
    expect(d.remainingValue, 270000);

    await expectLater(orders.deliver(id, qtyByLine: {lineId: shop.pieces(7)}, user: shop.cashier),
        throwsA(isA<ValidationException>()));
    await orders.deliver(id, qtyByLine: {lineId: shop.pieces(6)}, user: shop.cashier);
    d = await orders.detail(id);
    expect(d.order.status, SoStatus.delivered);
    expect(await shop.stockOf(shop.mixer), shop.pieces(10));
  });

  test('a cashier cannot give more than the extra-discount limit', () async {
    await expectLater(draft(1, extra: 600, user: shop.cashier), throwsA(isA<ValidationException>()));
    await draft(1, extra: 500, user: shop.cashier);
    await draft(1, extra: 600, user: shop.admin);
  });

  test('cancelling: drafts and untouched confirmed orders only', () async {
    final a = await draft(1);
    await orders.cancel(a, user: shop.admin);
    await expectLater(orders.confirm(a, user: shop.admin), throwsA(isA<ValidationException>()));

    final b = await draft(2);
    await orders.confirm(b, user: shop.admin);
    final lineId = (await orders.detail(b)).lines.single.line.id;
    await orders.deliver(b, qtyByLine: {lineId: shop.pieces(1)}, user: shop.cashier);
    await expectLater(orders.cancel(b, user: shop.admin), throwsA(isA<ValidationException>()));
  });

  test('an outside order id cannot be imported twice; numbers run SO-000001', () async {
    final lines = [SoLineInput(productId: shop.mixer.id, qty: shop.pieces(1))];
    final id = await orders.createDraft(
        customerId: customer,
        lines: lines,
        channel: SaleChannel.shopify,
        externalId: '1001',
        user: shop.admin);
    expect((await orders.detail(id)).order.number, 'SO-000001');
    await expectLater(
        orders.createDraft(
            customerId: customer,
            lines: lines,
            channel: SaleChannel.shopify,
            externalId: '1001',
            user: shop.admin),
        throwsA(isA<ValidationException>()));
    // Same id on another channel is a different order.
    await orders.createDraft(
        customerId: customer, lines: lines, channel: SaleChannel.phone, externalId: '1001', user: shop.admin);
  });

  test('a quotation becomes an order when confirmed', () async {
    final id = await orders.createDraft(
        customerId: customer,
        lines: [SoLineInput(productId: shop.mixer.id, qty: shop.pieces(2))],
        asQuotation: true,
        user: shop.cashier);
    expect((await orders.detail(id)).order.status, SoStatus.quotation);
    await orders.confirm(id, user: shop.cashier);
    final d = await orders.detail(id);
    expect(d.order.status, SoStatus.confirmed);
    expect(d.lines.single.line.unitPrice, 45000);
  });

  test('selling below cost needs the admin and a reason, and is logged', () async {
    // The admin gives a 100% extra discount: the price falls to zero.
    final id = await orders.createDraft(
        customerId: customer,
        lines: [SoLineInput(productId: shop.mixer.id, qty: shop.pieces(1), extraDiscountBp: 10000)],
        approvalReason: 'عرض خاص',
        user: shop.admin);
    await orders.confirm(id, user: shop.admin);
    final lineId = (await orders.detail(id)).lines.single.line.id;
    expect((await orders.detail(id)).lines.single.line.unitPrice, 0);

    await expectLater(orders.deliver(id, qtyByLine: {lineId: shop.pieces(1)}, user: shop.cashier),
        throwsA(isA<ValidationException>()));
    await expectLater(orders.deliver(id, qtyByLine: {lineId: shop.pieces(1)}, user: shop.admin),
        throwsA(isA<ValidationException>()));
    final inv = await orders.deliver(id,
        qtyByLine: {lineId: shop.pieces(1)}, belowCostReason: 'تصفية', user: shop.admin);

    final approvals = ApprovalService(shop.db);
    final onOrder = await approvals.forDocument('sales_order', id);
    expect(onOrder.single.kind, ApprovalKind.extraDiscount);
    expect(onOrder.single.reason, 'عرض خاص');
    final onInvoice = await approvals.forDocument('sales_invoice', inv.id);
    expect(onInvoice.single.kind, ApprovalKind.belowCost);
    expect(onInvoice.single.approvedBy, shop.admin.id);
  });

  test('schema 8 upgrades to 9 and keeps its data', () async {
    final dir = await Directory.systemTemp.createTemp('erp_v9');
    final file = File('${dir.path}/shop.db');
    try {
      var d = AppDatabase(NativeDatabase(file));
      await d.into(d.customers).insert(CustomersCompanion.insert(name: 'عميل'));
      await d.customStatement('DROP TABLE sales_order_deliveries');
      await d.customStatement('DROP TABLE sales_order_lines');
      await d.customStatement('DROP TABLE sales_orders');
      await d.customStatement('PRAGMA user_version = 8');
      await d.close();

      d = AppDatabase(NativeDatabase(file));
      expect((await d.select(d.customers).get()).single.name, 'عميل');
      expect(await d.select(d.salesOrders).get(), isEmpty);
      await d.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('schema 9 upgrades to 10 and keeps its data', () async {
    final dir = await Directory.systemTemp.createTemp('erp_v10');
    final file = File('${dir.path}/shop.db');
    try {
      var d = AppDatabase(NativeDatabase(file));
      await d.into(d.customers).insert(CustomersCompanion.insert(name: 'عميل'));
      await d.customStatement('DROP TABLE approvals');
      await d.customStatement('PRAGMA user_version = 9');
      await d.close();

      d = AppDatabase(NativeDatabase(file));
      expect((await d.select(d.customers).get()).single.name, 'عميل');
      expect(await d.select(d.approvals).get(), isEmpty);
      await d.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('an advance on an order sits as customer credit', () async {
    final id = await draft(2);
    await orders.confirm(id, user: shop.admin);
    final payments = PaymentService(shop.db);
    await payments.receiveAdvance(id, amount: 100000, userId: shop.cashier.id);
    expect(await payments.advancesOn(RefType.salesOrder, id), 100000);
    expect(await BalanceService(shop.db).customerBalance(customer), -100000);
    await expectLater(payments.receiveAdvance(id, amount: 0), throwsA(isA<ValidationException>()));
    await orders.cancel(id, user: shop.admin);
    await expectLater(payments.receiveAdvance(id, amount: 5000), throwsA(isA<ValidationException>()));
  });

  test('delivering puts the advance onto the invoice; balance does not change', () async {
    final id = await draft(2); // 2 x 450.00 = 900.00
    await orders.confirm(id, user: shop.admin);
    await PaymentService(shop.db).receiveAdvance(id, amount: 50000, userId: shop.cashier.id);
    final lineId = (await orders.detail(id)).lines.single.line.id;
    final inv = await orders.deliver(id, qtyByLine: {lineId: shop.pieces(2)}, user: shop.cashier);
    final balances = BalanceService(shop.db);
    expect(inv.total, 90000);
    expect(await balances.paidOnInvoice(RefType.salesInvoice, inv.id), 50000);
    expect(await PaymentService(shop.db).advancesOn(RefType.salesOrder, id), 0);
    expect(await balances.customerBalance(customer), 40000);
  });

  test('an advance bigger than the invoice stays on the order as credit', () async {
    final id = await draft(2);
    await orders.confirm(id, user: shop.admin);
    await PaymentService(shop.db).receiveAdvance(id, amount: 100000, userId: shop.cashier.id);
    final lineId = (await orders.detail(id)).lines.single.line.id;
    final inv = await orders.deliver(id, qtyByLine: {lineId: shop.pieces(2)}, user: shop.cashier);
    expect(await BalanceService(shop.db).paidOnInvoice(RefType.salesInvoice, inv.id), 0);
    expect(await PaymentService(shop.db).advancesOn(RefType.salesOrder, id), 100000);
    expect(await BalanceService(shop.db).customerBalance(customer), -10000);
  });
}
