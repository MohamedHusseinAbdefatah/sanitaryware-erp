import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';

/// Schema 14 adds columns only: a 1.7.0 file gets them with safe defaults.
void main() {
  test('a schema 13 file gets the purchase columns with their defaults', () async {
    final dir = await Directory.systemTemp.createTemp('erp_v14');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/shop.db');
    var db = AppDatabase(NativeDatabase(file));
    await db.select(db.users).get();
    await db.customStatement("INSERT INTO suppliers (id, name) VALUES (1, 'مورد')");
    await db.customStatement('''
      INSERT INTO purchase_invoices (id, number, date, supplier_id, subtotal, total) VALUES (1, 'P-1', 1700000000, 1, 100, 100)
    ''');
    for (final (table, column) in [
      ('purchase_invoices', 'extra_costs'),
      ('purchase_invoices', 'extra_costs_on_supplier'),
      ('purchase_invoices', 'due_date'),
      ('purchase_invoice_items', 'extra_cost_share'),
      ('expenses', 'purchase_invoice_id'),
    ]) {
      await db.customStatement('ALTER TABLE $table DROP COLUMN $column');
    }
    await db.customStatement('PRAGMA user_version = 13');
    await db.close();

    db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final inv = await db.select(db.purchaseInvoices).getSingle();
    expect(inv.extraCosts, 0);
    expect(inv.extraCostsOnSupplier, isTrue);
    expect(inv.dueDate, isNull);
    expect(await db.integrityOk(), isTrue);
    final v = await db.customSelect('PRAGMA user_version').getSingle();
    expect(v.data.values.first, AppDatabase.latestSchemaVersion);
  });
}
