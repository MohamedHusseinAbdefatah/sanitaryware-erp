import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';

/// Schema 15 adds two tables and a few columns: a 1.8.0 file keeps its data
/// and its existing reservations stay as they were.
void main() {
  test('a schema 14 file gets the order links and the advance tables', () async {
    final dir = await Directory.systemTemp.createTemp('erp_v15');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/shop.db');
    var db = AppDatabase(NativeDatabase(file));
    await db.select(db.users).get();
    await db.customStatement("INSERT INTO products (id, code, manufacturer_code, match_key, name_ar) VALUES (1, 'A', 'A', 'A', 'صنف')");
    await db.customStatement('INSERT INTO reservations (id, product_id, qty) VALUES (1, 1, 2000)');
    await db.customStatement('DROP TABLE supplier_advance_lists');
    await db.customStatement('DROP TABLE supplier_advances');
    for (final (table, column) in [
      ('reservations', 'sales_order_line_id'),
      ('purchase_order_lines', 'sales_order_line_id'),
      ('purchase_invoices', 'advance_id'),
      ('purchase_invoices', 'advance_used'),
    ]) {
      await db.customStatement('ALTER TABLE $table DROP COLUMN $column');
    }
    await db.customStatement('PRAGMA user_version = 14');
    await db.close();

    db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final r = await db.select(db.reservations).getSingle();
    expect(r.qty, 2000);
    expect(r.salesOrderLineId, isNull);
    expect(await db.select(db.supplierAdvances).get(), isEmpty);
    expect(await db.integrityOk(), isTrue);
    final v = await db.customSelect('PRAGMA user_version').getSingle();
    expect(v.data.values.first, AppDatabase.latestSchemaVersion);
  });
}
