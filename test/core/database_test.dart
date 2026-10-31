import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/services/numbering_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> addProduct(String code) {
    return db.into(db.products).insert(
          ProductsCompanion.insert(code: code, nameAr: 'منتج $code'),
        );
  }

  group('stock', () {
    test('current stock is the sum of movements', () async {
      final stock = StockService(db);
      final id = await addProduct('A1');
      expect(await stock.currentStock(id), 0);

      await stock.record(
          productId: id, type: StockMovementType.purchase, qty: 10, unitCost: 5000);
      await stock.record(productId: id, type: StockMovementType.sale, qty: -3);
      await stock.record(productId: id, type: StockMovementType.saleReturn, qty: 1);
      expect(await stock.currentStock(id), 8);
    });

    test('stock is tracked per product', () async {
      final stock = StockService(db);
      final a = await addProduct('A1');
      final b = await addProduct('B1');
      await stock.record(productId: a, type: StockMovementType.opening, qty: 5);
      await stock.record(productId: b, type: StockMovementType.opening, qty: 7);
      expect(await stock.currentStock(a), 5);
      expect(await stock.currentStock(b), 7);
    });

    test('a zero movement is rejected', () async {
      final stock = StockService(db);
      final id = await addProduct('A1');
      expect(
        () => stock.record(productId: id, type: StockMovementType.adjustment, qty: 0),
        throwsArgumentError,
      );
    });

    test('a failed transaction leaves no stock behind', () async {
      final stock = StockService(db);
      final id = await addProduct('A1');
      try {
        await db.transaction(() async {
          await stock.record(productId: id, type: StockMovementType.purchase, qty: 10);
          throw StateError('simulated crash while saving the invoice');
        });
      } on StateError {
        // expected
      }
      expect(await stock.currentStock(id), 0);
    });
  });

  group('database rules', () {
    test('duplicate product code is rejected', () async {
      await addProduct('A1');
      await expectLater(addProduct('A1'), throwsA(anything));
    });

    test('foreign keys are enforced', () async {
      await expectLater(
        db.into(db.stockMovements).insert(
              StockMovementsCompanion.insert(
                productId: 9999,
                type: StockMovementType.opening,
                qty: 1,
              ),
            ),
        throwsA(anything),
      );
    });

    test('money columns default to zero and keep integers', () async {
      final id = await db.into(db.products).insert(
            ProductsCompanion.insert(
              code: 'M1',
              nameAr: 'خلاط',
              priceRetail: const Value(123456),
            ),
          );
      final p = await (db.select(db.products)..where((t) => t.id.equals(id))).getSingle();
      expect(p.priceRetail, 123456);
      expect(p.costPrice, 0);
      expect(p.isActive, isTrue);
    });
  });

  group('numbering', () {
    test('numbers are sequential and never repeat', () async {
      final numbering = NumberingService(db);
      expect(await numbering.next('sales'), 'S-000001');
      expect(await numbering.next('sales'), 'S-000002');
      expect(await numbering.next('sales'), 'S-000003');
    });

    test('each document kind has its own counter', () async {
      final numbering = NumberingService(db);
      expect(await numbering.next('sales'), 'S-000001');
      expect(await numbering.next('purchase'), 'P-000001');
      expect(await numbering.next('payment'), 'R-000001');
      expect(await numbering.next('sales'), 'S-000002');
    });

    test('unknown kind is rejected', () {
      final numbering = NumberingService(db);
      expect(() => numbering.next('nope'), throwsArgumentError);
    });

    test('a rolled-back save does not consume a number', () async {
      final numbering = NumberingService(db);
      try {
        await db.transaction(() async {
          await numbering.next('sales');
          throw StateError('rollback');
        });
      } on StateError {
        // expected
      }
      expect(await numbering.next('sales'), 'S-000001');
    });
  });
}
