import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/services/supplier_advance_service.dart';

/// Schema 20 (version 2.4) only adds columns and tables. A 2.3 file keeps
/// every row as it was, and what an invoice took from an old (locked)
/// advance becomes an allocation of the same amount.
void main() {
  test('a schema 19 file gets the new columns and tables and keeps its data', () async {
    final dir = await Directory.systemTemp.createTemp('erp_v20');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/shop.db');
    var db = AppDatabase(NativeDatabase(file));
    await db.select(db.users).get();
    for (final s in [
      "INSERT INTO products (id, code, manufacturer_code, match_key, name_ar) VALUES (1, 'A', 'A-1', 'A1', 'حوض')",
      "INSERT INTO audit_logs (id, action, entity, details) VALUES (1, 'update', 'product', 'قديم')",
      "INSERT INTO suppliers (id, name) VALUES (1, 'مورد')",
      "INSERT INTO payments (id, number, date, direction, party_type, party_id, amount, method, invoice_ref_type, invoice_ref_id) "
          "VALUES (1, 'R-1', 1700000000, 'out', 'supplier', 1, 300000, 'cash', 'supplier_advance', 1)",
      "INSERT INTO supplier_advances (id, number, supplier_id, date, amount, payment_id) VALUES (1, 'SA-1', 1, 1700000000, 300000, 1)",
      "INSERT INTO purchase_invoices (id, number, date, supplier_id, subtotal, total, advance_id, advance_used) "
          "VALUES (1, 'P-1', 1700001000, 1, 200000, 200000, 1, 200000)",
      "INSERT INTO purchase_invoices (id, number, date, supplier_id, subtotal, total, status, advance_id, advance_used) "
          "VALUES (2, 'P-2', 1700002000, 1, 50000, 50000, 'cancelled', 1, 50000)",
    ]) {
      await db.customStatement(s);
    }
    for (final t in [
      'price_list_categories',
      'supplier_advance_allocations',
      'stock_entry_lines',
      'stock_entries',
      'remembered_logins',
      'project_tasks',
    ]) {
      await db.customStatement('DROP TABLE $t');
    }
    for (final (table, column) in [
      ('products', 'model_no'),
      ('price_list_items', 'model_no'),
      ('audit_logs', 'old_value'),
      ('audit_logs', 'new_value'),
      ('audit_logs', 'reason'),
      ('price_lists', 'category_id'),
      ('purchase_invoices', 'discount_bp'),
      ('purchase_invoice_items', 'list_category_id'),
      ('purchase_invoice_items', 'list_category_name'),
    ]) {
      await db.customStatement('ALTER TABLE $table DROP COLUMN $column');
    }
    await db.customStatement('PRAGMA user_version = 19');
    await db.close();

    db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final p = await db.select(db.products).getSingle();
    expect((p.nameAr, p.manufacturerCode, p.modelNo), ('حوض', 'A-1', null));
    final a = await db.select(db.auditLogs).getSingle();
    expect((a.details, a.oldValue, a.reason), ('قديم', null, null));

    final allocations = await db.select(db.supplierAdvanceAllocations).get();
    expect(allocations.map((x) => (x.invoiceId, x.amount, x.status)).toSet(),
        {(1, 200000, 'active'), (2, 50000, 'cancelled')});
    final advances = SupplierAdvanceService(db);
    expect((await advances.row(1)).remaining, 100000, reason: 'the same as before the upgrade');
    expect((await advances.balance(1)).remaining, 100000);
    expect((await db.select(db.purchaseInvoices).get()).first.advanceUsed, 200000);

    expect(await db.select(db.projectTasks).get(), isEmpty);
    expect(await db.integrityOk(), isTrue);
    final v = await db.customSelect('PRAGMA user_version').getSingle();
    expect(v.data.values.first, AppDatabase.latestSchemaVersion);
  });
}
