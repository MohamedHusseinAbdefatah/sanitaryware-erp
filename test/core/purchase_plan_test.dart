import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/reports/report_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_order_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/reservation_service.dart';

import '../support/fixture.dart';

void main() {
  late Shop shop;
  late ReportService reports;

  setUp(() async {
    shop = await Shop.open();
    reports = ReportService(shop.db);
    await ProductService(shop.db).update(
      shop.mixer.id,
      ProductInput(
        code: 'M1',
        nameAr: 'خلاط',
        unitId: shop.mixer.unitId,
        priceRetail: 50000,
        minStock: shop.pieces(10),
      ),
    );
    await PurchaseService(shop.db).post(
      PurchaseInput(
        supplierId: shop.supplierId,
        lines: [PurchaseLineInput(productId: shop.mixer.id, qty: shop.pieces(4), unitCost: 40000)],
      ),
      user: shop.admin,
    );
  });
  tearDown(() => shop.close());

  test('suggests the gap to the minimum, with the last supplier and cost', () async {
    final t = await reports.purchasePlan();
    expect(t.rows, [
      ['M1', 'خلاط', shop.pieces(4), 0, 0, shop.pieces(10), shop.pieces(6), 'مورد', 240000],
    ]);
  });

  test('reserved stock raises the need; open orders lower it', () async {
    await ReservationService(shop.db).reserve(productId: shop.mixer.id, qty: shop.pieces(2));
    var t = await reports.purchasePlan();
    expect(t.rows.single[6], shop.pieces(8));

    final orders = PurchaseOrderService(shop.db);
    final id = await orders.createDraft(
      supplierId: shop.supplierId,
      lines: [PoLineInput(productId: shop.mixer.id, qty: shop.pieces(3))],
      user: shop.admin,
    );
    await orders.approve(id, user: shop.admin);
    t = await reports.purchasePlan();
    expect(t.rows.single[4], shop.pieces(3));
    expect(t.rows.single[6], shop.pieces(5));
  });

  test('an item above its minimum is not listed', () async {
    await PurchaseService(shop.db).post(
      PurchaseInput(
        supplierId: shop.supplierId,
        lines: [PurchaseLineInput(productId: shop.mixer.id, qty: shop.pieces(10), unitCost: 40000)],
      ),
      user: shop.admin,
    );
    expect((await reports.purchasePlan()).rows, isEmpty);
  });
}
