import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/payment_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_order_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/reservation_service.dart';
import 'package:sanitaryware_erp/core/services/sales_order_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/supplier_advance_service.dart';

import '../support/fixture.dart';

/// 1.9.0: reservations come from orders, and money paid to a supplier ahead
/// is locked to that day's price lists.
void main() {
  late Shop shop;

  setUp(() async => shop = await Shop.open());
  tearDown(() => shop.close());

  Future<void> buy(int count) => PurchaseService(shop.db).post(
        PurchaseInput(
          supplierId: shop.supplierId,
          lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(count), unitCost: 30000)],
        ),
        user: shop.admin,
      );

  group('reservations from orders', () {
    late SalesOrderService orders;
    late ReservationService reservations;

    Future<int> confirmedOrder(int count, {int? customerId}) async {
      final id = await orders.createDraft(
        customerId: customerId ?? shop.customerId,
        lines: [SoLineInput(productId: shop.mixer.id, qty: qtyOf(count))],
        user: shop.admin,
      );
      await orders.confirm(id, user: shop.admin);
      return id;
    }

    setUp(() {
      orders = SalesOrderService(shop.db);
      reservations = ReservationService(shop.db);
    });

    test('confirming holds what is in stock; the rest is short', () async {
      await buy(6);
      final id = await confirmedOrder(10);
      expect(await reservations.reservedQty(shop.mixer.id), qtyOf(6));
      final s = (await orders.shortages(id)).single;
      expect(s.held, qtyOf(6));
      expect(s.onOrder, 0);
      expect(s.short, qtyOf(4));
      final rows = await reservations.watchActive().first;
      expect(rows.single.orderNumber, startsWith('SO-'));
    });

    test('the shortage goes on a purchase order; on arrival it is held for the customer', () async {
      await buy(6);
      final id = await confirmedOrder(10);
      final poId = await orders.orderShortages(id, supplierId: shop.supplierId, user: shop.admin);
      expect((await orders.shortages(id)).single.onOrder, qtyOf(4));
      expect((await orders.shortages(id)).single.short, 0);
      await expectLater(orders.orderShortages(id, supplierId: shop.supplierId, user: shop.admin),
          throwsA(isA<ValidationException>()), reason: 'nothing left to order');
      final po = PurchaseOrderService(shop.db);
      final line = (await po.detail(poId)).lines.single;
      await po.approve(poId, manualCosts: {line.line.id: 30000}, user: shop.admin);
      await po.receive(poId, qtyByLine: {line.line.id: qtyOf(4)}, user: shop.admin);
      final s = (await orders.shortages(id)).single;
      expect(s.held, qtyOf(10));
      expect(s.onOrder, 0);
      expect(s.short, 0);
    });

    test('another customer cannot buy what is held; delivering uses it and releases the rest', () async {
      await buy(6);
      final id = await confirmedOrder(6);
      await expectLater(
        SalesService(shop.db).post(
          SaleInput(lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000, priceListId: shop.priceListId)],
              paidAmount: 50000),
          userId: shop.admin.id,
        ),
        throwsA(isA<ReservedStockException>()),
      );
      final line = (await orders.detail(id)).lines.single.line;
      await orders.deliver(id, qtyByLine: {line.id: qtyOf(6)}, paidAmount: 0, user: shop.admin);
      expect(await reservations.reservedQty(shop.mixer.id), 0);
    });

    test('cancelling the order gives the stock back', () async {
      await buy(6);
      final id = await confirmedOrder(4);
      expect(await reservations.reservedQty(shop.mixer.id), qtyOf(4));
      await orders.cancel(id, user: shop.admin);
      expect(await reservations.reservedQty(shop.mixer.id), 0);
    });

    test('goods that arrive later can be held for the order', () async {
      final id = await confirmedOrder(3);
      expect((await orders.shortages(id)).single.short, qtyOf(3));
      await buy(5);
      expect(await orders.holdAvailable(id, userId: shop.admin.id), qtyOf(3));
      expect((await orders.shortages(id)).single.held, qtyOf(3));
    });
  });

  group('supplier advance by supplier (2.4)', () {
    late SupplierAdvanceService advances;

    setUp(() => advances = SupplierAdvanceService(shop.db));

    Future<SupplierAdvance> pay(int amount) => advances.create(
          supplierId: shop.supplierId,
          amount: amount,
          date: DateTime.now().subtract(const Duration(days: 30)),
          user: shop.admin,
        );

    Future<PurchaseInvoice> buy(int pieces, {int advanceAmount = 0}) => PurchaseService(shop.db).post(
          PurchaseInput(
            supplierId: shop.supplierId,
            advanceAmount: advanceAmount,
            lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(pieces), unitCost: 40000)],
          ),
          user: shop.admin,
        );

    test('it counts in the supplier balance from the day it is paid, with no price list', () async {
      final a = await pay(300000);
      expect(a.number, startsWith('SA-'));
      expect(await shop.supplierBalance(), -300000);
      final row = await advances.row(a.id);
      expect(row.lists, isEmpty);
      expect(row.remaining, 300000);
      expect((await advances.balance(shop.supplierId)).remaining, 300000);
    });

    test('an invoice takes part of the advance; the invoice shows it as paid', () async {
      final a = await pay(300000);
      final inv = await buy(5, advanceAmount: 150000);
      expect(inv.total, 200000);
      final fresh = await (shop.db.select(shop.db.purchaseInvoices)..where((t) => t.id.equals(inv.id))).getSingle();
      expect(fresh.advanceUsed, 150000);
      expect((await advances.row(a.id)).remaining, 150000);
      expect(await shop.supplierBalance(), -100000, reason: '300 paid ahead, 200 bought');
      final detail = await PurchaseService(shop.db).detail(inv.id);
      expect(detail.paid, 150000);
    });

    test('more than the advance balance, or than the invoice, is refused', () async {
      await pay(100000);
      await expectLater(buy(3, advanceAmount: 110000), throwsA(isA<ValidationException>()));
      final inv = await buy(1);
      await expectLater(advances.allocate(invoiceId: inv.id, amount: 50000, user: shop.admin),
          throwsA(isA<ValidationException>()), reason: 'the invoice is 400 only');
    });

    test('it is cancelled only while nothing was taken; cancelling the invoice frees it', () async {
      final a = await pay(300000);
      final inv = await buy(1, advanceAmount: 40000);
      await expectLater(advances.cancel(a.id, reason: 'خطأ', user: shop.admin), throwsA(isA<ValidationException>()));
      final payment = (await shop.db.select(shop.db.payments).get()).single;
      await expectLater(PaymentService(shop.db).cancel(payment.id, reason: 'خطأ', user: shop.admin),
          throwsA(isA<ValidationException>()), reason: 'not from the payments screen');
      await PurchaseService(shop.db).cancel(inv.id, reason: 'خطأ', user: shop.admin);
      expect((await advances.row(a.id)).remaining, 300000);
      await advances.cancel(a.id, reason: 'خطأ', user: shop.admin);
      expect((await advances.row(a.id)).advance.status, DocStatus.cancelled);
      expect(await shop.supplierBalance(), 0);
    });
  });
}
