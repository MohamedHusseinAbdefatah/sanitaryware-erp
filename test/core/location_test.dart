import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/fifo_service.dart';
import 'package:sanitaryware_erp/core/services/location_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';

void main() {
  late AppDatabase db;
  late LocationService places;
  late int product;
  late int showroom;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    places = LocationService(db);
    product = await db.into(db.products).insert(ProductsCompanion.insert(code: 'P1', nameAr: 'حوض'));
    showroom = await places.create(name: 'المعرض', kind: LocationKind.showroomDisplay);
    // 10 units in the main warehouse, cost 100.00, as one layer.
    await FifoService(db).addLayer(
        productId: product, qty: 10000, unitCost: 10000, sourceType: 'opening');
    await StockService(db).record(
        productId: product, type: StockMovementType.opening, qty: 10000, unitCost: 10000);
  });
  tearDown(() => db.close());

  test('main warehouse exists and names must be new', () async {
    expect((await places.all()).first.id, mainLocationId);
    await expectLater(places.create(name: 'المعرض'), throwsA(isA<ValidationException>()));
    await expectLater(places.create(name: '  '), throwsA(isA<ValidationException>()));
  });

  test('the main warehouse cannot be switched off', () async {
    await expectLater(
        places.update(mainLocationId,
            name: 'المخزن الرئيسي', kind: LocationKind.warehouse, isSellable: true, isActive: false),
        throwsA(isA<ValidationException>()));
  });

  test('a transfer moves stock and keeps its cost', () async {
    await places.transfer(
        productId: product, qty: 4000, fromLocationId: mainLocationId, toLocationId: showroom);
    expect(await places.stockByLocation(product), {mainLocationId: 6000, showroom: 4000});
    expect(await StockService(db).currentStock(product), 10000);
    final fifo = FifoService(db);
    final take = await fifo.consume(
        productId: product,
        qty: 4000,
        refType: 'test',
        refId: 1,
        locationId: showroom);
    expect(take.averageUnitCost, 10000);
  });

  test('cannot move more than is there, or to the same place', () async {
    await expectLater(
        places.transfer(
            productId: product, qty: 11000, fromLocationId: mainLocationId, toLocationId: showroom),
        throwsA(isA<ValidationException>()));
    await expectLater(
        places.transfer(
            productId: product, qty: 1000, fromLocationId: showroom, toLocationId: showroom),
        throwsA(isA<ValidationException>()));
    await expectLater(
        places.transfer(
            productId: product, qty: 0, fromLocationId: mainLocationId, toLocationId: showroom),
        throwsA(isA<ValidationException>()));
  });
}
