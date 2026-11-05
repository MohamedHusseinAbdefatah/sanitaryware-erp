import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/reports/report_service.dart';
import 'package:sanitaryware_erp/core/services/approval_service.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/reservation_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';

import '../support/fixture.dart';

void main() {
  late Shop shop;
  late SalesService sales;

  setUp(() async {
    shop = await Shop.open();
    sales = SalesService(shop.db);
  });
  tearDown(() => shop.close());

  Future<void> buy(int count, int unitCost) => PurchaseService(shop.db).post(
        PurchaseInput(
          supplierId: shop.supplierId,
          lines: [PurchaseLineInput(productId: shop.mixer.id, qty: shop.pieces(count), unitCost: unitCost)],
        ),
        user: shop.admin,
      );

  SaleInput sale(int count, int price, {int? customerId}) => SaleInput(
        customerId: customerId ?? shop.customerId,
        lines: [SaleLineInput(productId: shop.mixer.id, qty: shop.pieces(count), unitPrice: price)],
      );

  group('below cost', () {
    setUp(() => buy(10, 40000));

    test('a cashier is refused and nothing is saved', () async {
      await expectLater(
        sales.post(sale(1, 30000), userId: shop.cashier.id),
        throwsA(isA<BelowCostException>().having((e) => e.needsReason, 'needsReason', false)),
      );
      expect(await shop.stockOf(shop.mixer), shop.pieces(10));
    });

    test('an admin needs a reason, which is then logged', () async {
      await expectLater(
        sales.post(sale(1, 30000), userId: shop.admin.id),
        throwsA(isA<BelowCostException>().having((e) => e.needsReason, 'needsReason', true)),
      );
      final invoice =
          await sales.post(sale(1, 30000), userId: shop.admin.id, belowCostReason: 'عميل قديم');
      final log = await ApprovalService(shop.db).forDocument('sales_invoice', invoice.id);
      expect(log.single.kind, ApprovalKind.belowCost);
      expect(log.single.reason, 'عميل قديم');
    });

    test('selling at cost is fine for a cashier', () async {
      await sales.post(sale(1, 40000), userId: shop.cashier.id);
    });

    test('a discount that pushes the line under cost counts', () async {
      final input = SaleInput(
        customerId: shop.customerId,
        lines: [
          SaleLineInput(productId: shop.mixer.id, qty: shop.pieces(1), unitPrice: 50000, discount: 15000),
        ],
      );
      await expectLater(sales.post(input, userId: shop.cashier.id), throwsA(isA<BelowCostException>()));
    });
  });

  group('reservations', () {
    late int other;
    setUp(() async {
      await buy(10, 40000);
      other = await PartyService(shop.db).saveCustomer(const CustomerInput(name: 'مقاول'));
      await ReservationService(shop.db)
          .reserve(productId: shop.mixer.id, qty: shop.pieces(8), customerId: other);
    });

    test('stock held for someone else cannot be sold', () async {
      await expectLater(
        sales.post(sale(5, 50000), userId: shop.admin.id),
        throwsA(isA<ReservedStockException>()),
      );
      // 2 are still free.
      await sales.post(sale(2, 50000), userId: shop.admin.id);
    });

    test('a walk-in sale is also kept off reserved stock', () async {
      final walkIn = SaleInput(
        lines: [SaleLineInput(productId: shop.mixer.id, qty: shop.pieces(5), unitPrice: 50000)],
        paidAmount: 250000,
      );
      await expectLater(sales.post(walkIn, userId: shop.admin.id), throwsA(isA<ReservedStockException>()));
    });

    test('the reserving customer can buy it, which uses the reservation up', () async {
      final reservations = ReservationService(shop.db);
      await sales.post(sale(3, 50000, customerId: other), userId: shop.admin.id);
      expect(await reservations.reservedQty(shop.mixer.id), shop.pieces(5));
      await sales.post(sale(5, 50000, customerId: other), userId: shop.admin.id);
      expect(await reservations.reservedQty(shop.mixer.id), 0);
    });
  });

  group('stock valuation', () {
    test('uses what the remaining layers cost, not the average', () async {
      await buy(10, 40000);
      await buy(10, 60000);
      await sales.post(sale(10, 70000), userId: shop.admin.id); // takes the 400.00 layer
      final value = await ReportService(shop.db).stockValuation();
      final row = value.rows.single;
      expect(row[2], shop.pieces(10));
      expect(row[4], 600000); // 10 x 600.00
      expect(row[3], 60000);
    });
  });
}
