import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/services/selling_policy_service.dart';

/// Rolls a current database back to the shape of schema 12 (1.6.x) and fills
/// it, so the real upgrade to 13 runs on what a shop has today.
Future<void> makeSchema12(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  await db.select(db.users).get(); // creates the file at the latest schema
  await db.customStatement('PRAGMA foreign_keys = OFF');
  // Customers without a category.
  await db.customStatement('CREATE TABLE customers_v12 AS SELECT id, created_at, updated_at, name, phone, address, '
      'opening_balance, credit_limit, price_level, discount_bp, notes, is_active FROM customers');
  await db.customStatement('DROP TABLE customers');
  await db.customStatement('ALTER TABLE customers_v12 RENAME TO customers');
  // Selling policies tied to a version and a fixed pricing type.
  await db.customStatement('DROP TABLE selling_policies');
  await db.customStatement('DROP TABLE customer_categories');
  await db.customStatement('''
    CREATE TABLE selling_policies (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at INTEGER NOT NULL DEFAULT 1,
      updated_at INTEGER NOT NULL DEFAULT 1, brand_id INTEGER NOT NULL, price_list_id INTEGER NOT NULL,
      pricing_type TEXT NOT NULL, scope TEXT NOT NULL, category_id INTEGER, product_id INTEGER,
      discount_bp INTEGER NOT NULL DEFAULT 0, max_discount_bp INTEGER, min_margin_bp INTEGER, valid_from INTEGER,
      valid_to INTEGER, is_active INTEGER NOT NULL DEFAULT 1, note TEXT)
  ''');
  await db.customStatement('CREATE INDEX idx_selling_policies_list ON selling_policies (price_list_id)');

  // A 1.6 shop's data.
  await db.customStatement("INSERT INTO brands (id, name) VALUES (1, 'Duravit')");
  await db.customStatement('''
    INSERT INTO products (id, code, manufacturer_code, match_key, name_ar, brand_id)
    VALUES (1, 'P1', 'D-1', 'D-1', 'حوض', 1)
  ''');
  await db.customStatement('''
    INSERT INTO price_lists (id, name, brand_id, list_type, version_no, currency, effective_from, import_date,
      row_count, vat_status, status, created_at, updated_at)
    VALUES (5, 'ديورافيت', 1, 'All', 1, 'EGP', 1700000000, 1700000000, 1, 'unverified', 'active', 1, 1)
  ''');
  await db.customStatement('''
    INSERT INTO price_list_items (id, price_list_id, product_id, manufacturer_code, name, price, status)
    VALUES (1, 5, 1, 'D-1', 'حوض', 100000, 'ok')
  ''');
  await db.customStatement('''
    INSERT INTO customers (id, created_at, updated_at, name, opening_balance, credit_limit, price_level, discount_bp,
      is_active)
    VALUES (1, 1, 1, 'قطاعي', 0, 0, 'retail', 0, 1), (2, 1, 1, 'تاجر', 0, 0, 'wholesale', 100, 1),
           (3, 1, 1, 'مقاول', 0, 0, 'contractor', 0, 1)
  ''');
  await db.customStatement('''
    INSERT INTO selling_policies (id, brand_id, price_list_id, pricing_type, scope, discount_bp, max_discount_bp, note)
    VALUES (9, 1, 5, 'b2b', 'all', 1500, 2000, 'جملة ديورافيت')
  ''');
  await db.customStatement('PRAGMA user_version = 12');
  await db.close();
}

void main() {
  late Directory dir;
  late AppDatabase db;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('erp_v13');
    final file = File('${dir.path}/shop.db');
    await makeSchema12(file);
    db = AppDatabase(NativeDatabase(file));
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('the old price levels become categories, with no discount assumed', () async {
    final categories = await SellingPolicyService(db).categories();
    expect(categories.map((c) => c.name), ['قطاعي', 'جملة', 'مشروعات ومقاولون', 'مهندسين']);
    expect(categories.every((c) => c.discountBp == 0), isTrue);
    final customers = await db.select(db.customers).get();
    expect({for (final c in customers) c.name: c.categoryId}, {'قطاعي': 1, 'تاجر': 2, 'مقاول': 3});
    expect(customers.firstWhere((c) => c.id == 2).discountBp, 100, reason: 'the customer\'s own discount stays');
  });

  test('an old selling policy becomes a rule for its category and brand, for every version', () async {
    final rule = (await db.select(db.sellingPolicies).get()).single;
    expect(rule.id, 9);
    expect(rule.customerCategoryId, 2);
    expect(rule.brandId, 1);
    expect(rule.discountBp, 1500);
    expect(rule.maxDiscountBp, 2000);
    expect(rule.note, 'جملة ديورافيت');
    final trader = await (db.select(db.customers)..where((c) => c.id.equals(2))).getSingle();
    final q = (await SellingPolicyService(db).quotes(1, customer: trader)).single;
    expect(q.policy?.id, 9);
    expect(q.totalBp, 1600);
    final retail = await (db.select(db.customers)..where((c) => c.id.equals(1))).getSingle();
    expect((await SellingPolicyService(db).quotes(1, customer: retail)).single.policyBp, 0);
  });

  test('the file is at the latest schema and passes its own check', () async {
    final v = await db.customSelect('PRAGMA user_version').getSingle();
    expect(v.data.values.first, AppDatabase.latestSchemaVersion);
    expect(await db.integrityOk(), isTrue);
  });
}
