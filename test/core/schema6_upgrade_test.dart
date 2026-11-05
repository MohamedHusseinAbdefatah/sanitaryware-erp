import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';

void main() {
  test('schema 5 upgrades to 6: customers keep their data, discount starts at 0', () async {
    final dir = await Directory.systemTemp.createTemp('erp_v6');
    final file = File('${dir.path}/shop.db');
    try {
      var db = AppDatabase(NativeDatabase(file));
      await db.into(db.customers).insert(CustomersCompanion.insert(name: 'عميل'));
      await db.customStatement('ALTER TABLE customers DROP COLUMN discount_bp');
      await db.customStatement('PRAGMA user_version = 5');
      await db.close();

      db = AppDatabase(NativeDatabase(file));
      final c = (await db.select(db.customers).get()).single;
      expect(c.name, 'عميل');
      expect(c.discountBp, 0);
      await db.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('a customer discount is saved and checked', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final parties = PartyService(db);
    final id = await parties.saveCustomer(const CustomerInput(name: 'مقاول', discountBp: 1250));
    expect((await parties.customer(id)).discountBp, 1250);
    await expectLater(parties.saveCustomer(const CustomerInput(name: 'x', discountBp: 10001)),
        throwsA(isA<ValidationException>()));
    await expectLater(parties.saveCustomer(const CustomerInput(name: 'x', discountBp: -1)),
        throwsA(isA<ValidationException>()));
  });
}
