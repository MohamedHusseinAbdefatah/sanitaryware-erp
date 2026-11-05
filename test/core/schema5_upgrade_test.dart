import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';

void main() {
  test('schema 4 upgrades to 5 and keeps its data', () async {
    final dir = await Directory.systemTemp.createTemp('erp_v5');
    final file = File('${dir.path}/shop.db');
    try {
      var db = AppDatabase(NativeDatabase(file));
      await db.into(db.suppliers).insert(SuppliersCompanion.insert(name: 'مورد'));
      await db.customStatement('DROP TABLE discount_rules');
      await db.customStatement('DROP TABLE price_list_items');
      await db.customStatement('DROP TABLE price_lists');
      await db.customStatement('PRAGMA user_version = 4');
      await db.close();

      db = AppDatabase(NativeDatabase(file));
      expect((await db.select(db.suppliers).get()).single.name, 'مورد');
      expect(await db.select(db.priceLists).get(), isEmpty);
      expect(await db.select(db.discountRules).get(), isEmpty);
      await db.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
