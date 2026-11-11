import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/inventory_service.dart';
import 'package:sanitaryware_erp/core/services/location_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';

import '../support/fixture.dart';

/// The inventory is what the shop holds, kept apart from the catalogue and
/// the price lists: a product loaded from a list but never bought is not in it.
void main() {
  late Shop shop;
  late InventoryService inventory;

  setUp(() async {
    shop = await Shop.open();
    inventory = InventoryService(shop.db);
  });
  tearDown(() => shop.close());

  Future<void> buy(int count, int cost) => PurchaseService(shop.db).post(
        PurchaseInput(
          supplierId: shop.supplierId,
          lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(count), unitCost: cost)],
        ),
        user: shop.admin,
      );

  Future<void> sell(int count) => SalesService(shop.db).post(
        SaleInput(
          lines: [
            SaleLineInput(productId: shop.mixer.id, qty: qtyOf(count), unitPrice: 50000, priceListId: shop.priceListId),
          ],
          paidAmount: 50000 * count,
        ),
        userId: shop.admin.id,
      );

  test('products only on a price list are not in the inventory', () async {
    // The fixture's mixer and pipe are on an approved list, never bought.
    expect(await inventory.watch().first, isEmpty);
    expect(await inventory.watch(includeSoldOut: true).first, isEmpty);
  });

  test('what was bought shows with its quantity, place, value and date', () async {
    await buy(4, 30000);
    final rows = await inventory.watch().first;
    expect(rows.map((r) => r.product.id), [shop.mixer.id]);
    final r = rows.single;
    expect(r.stock, qtyOf(4));
    expect(r.value, 120000);
    expect(r.places.single.$2, qtyOf(4));
    expect(r.lastIn, isNotNull);
  });

  test('sold out leaves the list, unless asked for', () async {
    await buy(2, 30000);
    await sell(2);
    expect(await inventory.watch().first, isEmpty);
    final all = await inventory.watch(includeSoldOut: true).first;
    expect(all.single.stock, 0);
    expect(all.single.value, 0);
  });

  test('stock in two places is shown by place', () async {
    await buy(5, 30000);
    final places = LocationService(shop.db);
    final showroom = await places.create(name: 'المعرض');
    await places.transfer(productId: shop.mixer.id, qty: qtyOf(2), fromLocationId: mainLocationId, toLocationId: showroom);
    final r = (await inventory.watch().first).single;
    expect(r.stock, qtyOf(5));
    expect(r.places.map((p) => p.$2), [qtyOf(3), qtyOf(2)]);
  });

  test('search', () async {
    await buy(1, 30000);
    expect(await inventory.watch(search: 'لا يوجد').first, isEmpty);
    expect((await inventory.watch(search: shop.mixer.code).first).length, 1);
  });
}
