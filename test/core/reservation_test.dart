import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/reservation_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';

void main() {
  late AppDatabase db;
  late ReservationService res;
  late int product;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    res = ReservationService(db);
    product = await db.into(db.products).insert(ProductsCompanion.insert(code: 'P1', nameAr: 'حوض'));
    await StockService(db).record(productId: product, type: StockMovementType.opening, qty: 10000);
  });
  tearDown(() => db.close());

  test('a reservation lowers what is available but not what is on hand', () async {
    await res.reserve(productId: product, qty: 3000);
    expect(await res.reservedQty(product), 3000);
    expect(await res.availableQty(product), 7000);
    expect(await StockService(db).currentStock(product), 10000);
  });

  test('cannot reserve more than is available', () async {
    await res.reserve(productId: product, qty: 8000);
    await expectLater(res.reserve(productId: product, qty: 3000), throwsA(isA<ValidationException>()));
    await expectLater(res.reserve(productId: product, qty: 0), throwsA(isA<ValidationException>()));
  });

  test('releasing gives the stock back, once', () async {
    final id = await res.reserve(productId: product, qty: 4000);
    await res.release(id);
    expect(await res.availableQty(product), 10000);
    await expectLater(res.release(id), throwsA(isA<ValidationException>()));
  });

  test('an expired reservation no longer counts', () async {
    await res.reserve(
        productId: product, qty: 4000, expiresAt: DateTime.now().add(const Duration(days: 1)));
    expect(await res.reservedQty(product, asOf: DateTime.now()), 4000);
    expect(await res.reservedQty(product, asOf: DateTime.now().add(const Duration(days: 2))), 0);
  });

  test('schema 6 upgrades to 7 and keeps its data', () async {
    final dir = await Directory.systemTemp.createTemp('erp_v7');
    final file = File('${dir.path}/shop.db');
    try {
      var d = AppDatabase(NativeDatabase(file));
      await d.into(d.customers).insert(CustomersCompanion.insert(name: 'عميل'));
      await d.customStatement('DROP TABLE reservations');
      await d.customStatement('PRAGMA user_version = 6');
      await d.close();

      d = AppDatabase(NativeDatabase(file));
      expect((await d.select(d.customers).get()).single.name, 'عميل');
      expect(await d.select(d.reservations).get(), isEmpty);
      await d.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
