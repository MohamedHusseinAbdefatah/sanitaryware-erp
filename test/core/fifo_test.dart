import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/fifo_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';

void main() {
  late AppDatabase db;
  late FifoService fifo;
  late int pid;
  const showroom = 2;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    fifo = FifoService(db);
    pid = await db.into(db.products).insert(ProductsCompanion.insert(code: 'A', nameAr: 'منتج'));
    await db.into(db.locations).insert(LocationsCompanion.insert(name: 'المعرض'));
  });
  tearDown(() => db.close());

  final d1 = DateTime(2026, 1, 1);
  final d2 = DateTime(2026, 2, 1);

  test('main warehouse is seeded', () async {
    final l = await db.select(db.locations).get();
    expect(l.first.id, 1);
  });

  test('sale takes oldest layer first, across layers', () async {
    await fifo.addLayer(productId: pid, qty: 10 * qtyScale, unitCost: 1000, receivedAt: d1);
    await fifo.addLayer(productId: pid, qty: 10 * qtyScale, unitCost: 2000, receivedAt: d2);
    final take = await fifo.consume(productId: pid, qty: 15 * qtyScale, refType: 'sale', refId: 1);
    expect(take.pieces.length, 2);
    expect(take.totalCost, 10 * 1000 + 5 * 2000);
    expect(await fifo.remaining(pid), 5 * qtyScale);
  });

  test('insufficient stock throws and changes nothing', () async {
    await fifo.addLayer(productId: pid, qty: 3 * qtyScale, unitCost: 1000);
    await expectLater(
        fifo.consume(productId: pid, qty: 5 * qtyScale, refType: 'sale', refId: 1),
        throwsA(isA<ValidationException>()));
    expect(await fifo.remaining(pid), 3 * qtyScale);
  });

  test('locations are independent', () async {
    await fifo.addLayer(productId: pid, qty: 5 * qtyScale, unitCost: 1000);
    expect(await fifo.remaining(pid, locationId: showroom), 0);
    await expectLater(
        fifo.consume(productId: pid, qty: qtyScale, refType: 'sale', refId: 1, locationId: showroom),
        throwsA(isA<ValidationException>()));
  });

  test('transfer keeps cost and received date', () async {
    await fifo.addLayer(productId: pid, qty: 10 * qtyScale, unitCost: 1000, receivedAt: d1);
    await fifo.addLayer(productId: pid, qty: 10 * qtyScale, unitCost: 2000, receivedAt: d2);
    await fifo.transfer(productId: pid, qty: 12 * qtyScale, fromLocationId: 1, toLocationId: showroom, refId: 7);
    expect(await fifo.remaining(pid), 8 * qtyScale);
    expect(await fifo.remaining(pid, locationId: showroom), 12 * qtyScale);
    final sale = await fifo.consume(
        productId: pid, qty: 10 * qtyScale, refType: 'sale', refId: 2, locationId: showroom);
    expect(sale.totalCost, 10 * 1000);
    expect(sale.pieces.first.receivedAt, d1);
    final stock = StockService(db);
    expect(await stock.currentStock(pid, locationId: showroom), 12 * qtyScale);
    expect(await stock.currentStock(pid, locationId: 1), -12 * qtyScale);
  });

  test('reverse nets cost to zero and a second reverse throws', () async {
    await fifo.addLayer(productId: pid, qty: 10 * qtyScale, unitCost: 1000);
    await fifo.consume(productId: pid, qty: 4 * qtyScale, refType: 'sale', refId: 9);
    expect(await fifo.costOf('sale', 9), 4000);
    await fifo.reverse('sale', 9);
    expect(await fifo.costOf('sale', 9), 0);
    expect(await fifo.remaining(pid), 10 * qtyScale);
    await expectLater(fifo.reverse('sale', 9), throwsA(isA<ValidationException>()));
  });

  test('fractional quantities work', () async {
    await fifo.addLayer(productId: pid, qty: 6000, unitCost: 3000);
    final take = await fifo.consume(productId: pid, qty: 1500, refType: 'sale', refId: 3);
    expect(take.totalCost, 4500);
    expect(await fifo.remaining(pid), 4500);
  });
}
