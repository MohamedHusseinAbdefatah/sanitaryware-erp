// DB=<erp.sqlite>: schema version, integrity, and how many rows the main
// tables hold (a check after an upgrade, on a copy of real data).
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';

void main() {
  test('db check', () async {
    final db = AppDatabase(NativeDatabase(File(Platform.environment['DB']!)));
    final v = (await db.customSelect('PRAGMA user_version').getSingle()).data.values.first;
    // ignore: avoid_print
    print('schema $v integrity ${await db.integrityOk()}');
    for (final t in ['products', 'customers', 'suppliers', 'sales_invoices', 'purchase_invoices', 'price_lists',
        'price_list_items', 'journal_entries', 'customer_contacts', 'expense_attachments']) {
      final n = (await db.customSelect('SELECT COUNT(*) AS n FROM $t').getSingle()).read<int>('n');
      // ignore: avoid_print
      print('$t $n');
    }
    await db.close();
  });
}
