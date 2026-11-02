import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';

void main() {
  test('a v1 database upgrades to the latest schema and keeps its rows', () async {
    // The parts of the v1 schema that the upgrades touch (a full v1 database
    // is tested in test/acceptance/upgrade_test.dart).
    final db = AppDatabase(NativeDatabase.memory(setup: (raw) {
      raw.execute('''
        CREATE TABLE units (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name_ar TEXT NOT NULL,
          created_at INTEGER NOT NULL DEFAULT (strftime('%s', CURRENT_TIMESTAMP)),
          updated_at INTEGER NOT NULL DEFAULT (strftime('%s', CURRENT_TIMESTAMP))
        );
        CREATE TABLE products (id INTEGER PRIMARY KEY, name_ar TEXT NOT NULL);
        CREATE TABLE payments (id INTEGER PRIMARY KEY, invoice_ref_type TEXT, invoice_ref_id INTEGER);
        INSERT INTO units (name_ar) VALUES ('قطعة');
        PRAGMA user_version = 1;
      ''');
    }));
    addTearDown(db.close);

    final units = await db.select(db.units).get();
    expect(units.single.nameAr, 'قطعة');
    expect(units.single.allowDecimal, isFalse);

    final index = await db
        .customSelect("SELECT name FROM sqlite_master WHERE name = 'idx_products_name_ar'")
        .get();
    expect(index, hasLength(1));
  });
}
