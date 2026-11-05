import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';

void main() {
  test('schema 3 upgrades to 4: location 1, layers from stock', () async {
    final dir = await Directory.systemTemp.createTemp('erp_v4');
    final file = File('${dir.path}/shop.db');
    try {
      var db = AppDatabase(NativeDatabase(file));
      final pid = await db.into(db.products).insert(
          ProductsCompanion.insert(code: 'A', nameAr: 'منتج'));
      // Products had an average cost in schema 3.
      await db.customStatement('ALTER TABLE products ADD COLUMN cost_price INTEGER NOT NULL DEFAULT 2500');
      await db.into(db.stockMovements).insert(
          StockMovementsCompanion.insert(productId: pid, type: 'purchase', qty: 5000));
      await db.customStatement('DROP TABLE layer_consumptions');
      await db.customStatement('DROP TABLE cost_layers');
      await db.customStatement('DROP TABLE locations');
      await db.customStatement('ALTER TABLE stock_movements DROP COLUMN location_id');
      await db.customStatement('PRAGMA user_version = 3');
      await db.close();

      db = AppDatabase(NativeDatabase(file));
      final locs = await db.select(db.locations).get();
      expect(locs.single.id, 1);
      final layers = await db.select(db.costLayers).get();
      expect(layers.single.qtyRemaining, 5000);
      expect(layers.single.unitCost, 2500);
      final m = await db.select(db.stockMovements).get();
      expect(m.single.locationId, 1);
      await db.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
