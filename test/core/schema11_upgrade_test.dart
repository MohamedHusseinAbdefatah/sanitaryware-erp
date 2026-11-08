import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/pricing_math.dart';
import 'package:sanitaryware_erp/core/services/price_list_service.dart';

/// Rolls a current database back to the exact old shape of schema 10 and fills
/// it, so the real upgrade runs on what a 1.1.0 shop has.
Future<void> makeSchema10(File file) async {
  final db = AppDatabase(NativeDatabase(file));
  await db.select(db.users).get(); // creates the file at the latest schema
  for (final c in [
    'manufacturer_code', 'match_key', 'description', 'subcategory_id', 'series', 'dimensions',
    'variant', 'finish', 'barcode', 'technical_specs', 'vat_basis', 'vat_rate_bp',
  ]) {
    if (c == 'match_key') await db.customStatement('DROP INDEX idx_products_match_key');
    await db.customStatement('ALTER TABLE products DROP COLUMN $c');
  }
  await db.customStatement('ALTER TABLE products ADD COLUMN cost_price INTEGER NOT NULL DEFAULT 0');
  await db.customStatement('ALTER TABLE products ADD COLUMN price_retail INTEGER NOT NULL DEFAULT 0');
  await db.customStatement('ALTER TABLE products ADD COLUMN price_wholesale INTEGER NOT NULL DEFAULT 0');
  await db.customStatement('ALTER TABLE products ADD COLUMN price_contractor INTEGER NOT NULL DEFAULT 0');
  await db.customStatement('DROP TABLE buying_policies');
  await db.customStatement('DROP TABLE selling_policies');
  await db.customStatement('DROP TABLE price_list_items');
  await db.customStatement('DROP TABLE price_lists');
  await db.customStatement('''
    CREATE TABLE price_lists (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at INTEGER NOT NULL DEFAULT 1,
      updated_at INTEGER NOT NULL DEFAULT 1, supplier_id INTEGER NOT NULL, brand_id INTEGER, name TEXT NOT NULL,
      effective_date INTEGER NOT NULL, vat_included INTEGER NOT NULL DEFAULT 0, is_active INTEGER NOT NULL DEFAULT 1, note TEXT)
  ''');
  await db.customStatement('''
    CREATE TABLE price_list_items (id INTEGER PRIMARY KEY AUTOINCREMENT, price_list_id INTEGER NOT NULL, product_id INTEGER,
      supplier_code TEXT NOT NULL DEFAULT '', name TEXT NOT NULL, colour TEXT, price INTEGER NOT NULL, pack_size INTEGER)
  ''');
  await db.customStatement('''
    CREATE TABLE discount_rules (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at INTEGER NOT NULL DEFAULT 1,
      updated_at INTEGER NOT NULL DEFAULT 1, supplier_id INTEGER NOT NULL, scope TEXT NOT NULL, brand_id INTEGER,
      category_id INTEGER, product_id INTEGER, percent_bp INTEGER NOT NULL, valid_from INTEGER, valid_to INTEGER,
      is_active INTEGER NOT NULL DEFAULT 1, note TEXT)
  ''');
  for (final c in [
    'price_list_id', 'list_price', 'pricing_type', 'selling_policy_id', 'policy_discount_bp', 'customer_discount_bp',
    'extra_discount_bp', 'invoice_discount_share', 'net_total', 'vat_status', 'vat_rate_bp', 'vat_amount', 'cost_total',
  ]) {
    await db.customStatement('ALTER TABLE sales_invoice_items DROP COLUMN $c');
  }
  for (final c in [
    'price_list_id', 'list_price', 'buying_policy_id', 'base_discount_bp', 'extra_discount_bp',
    'invoice_discount_share', 'net_total',
  ]) {
    await db.customStatement('ALTER TABLE purchase_invoice_items DROP COLUMN $c');
  }
  for (final c in ['price_list_id', 'list_price']) {
    await db.customStatement('ALTER TABLE cost_layers DROP COLUMN $c');
  }
  for (final c in ['buying_policy_id', 'extra_discount_bp']) {
    await db.customStatement('ALTER TABLE purchase_order_lines DROP COLUMN $c');
  }
  for (final c in ['price_list_id', 'pricing_type', 'selling_policy_id', 'policy_discount_bp', 'vat_status', 'vat_rate_bp']) {
    await db.customStatement('ALTER TABLE sales_order_lines DROP COLUMN $c');
  }
  await db.customStatement('ALTER TABLE sales_order_lines RENAME COLUMN customer_discount_bp TO base_discount_bp');

  // A 1.1.0 shop's data.
  await db.customStatement("INSERT INTO brands (id, name) VALUES (1, 'Duravit')");
  await db.customStatement("INSERT INTO suppliers (id, name) VALUES (1, 'مورد أ')");
  await db.customStatement('''
    INSERT INTO products (id, code, name_ar, brand_id, cost_price, price_retail, price_wholesale, price_contractor)
    VALUES (1, '0123-A', 'حوض', 1, 40000, 50000, 45000, 0),
           (2, 'X 9', 'بلا ماركة', NULL, 100, 200, 0, 0),
           (3, 'Z', 'بلا أسعار', NULL, 0, 0, 0, 0)
  ''');
  await db.customStatement('''
    INSERT INTO price_lists (id, supplier_id, brand_id, name, effective_date, vat_included, note)
    VALUES (7, 1, 1, 'قائمة قديمة', 1700000000, 1, 'ملاحظة')
  ''');
  await db.customStatement('''
    INSERT INTO price_list_items (id, price_list_id, product_id, supplier_code, name, colour, price, pack_size)
    VALUES (70, 7, 1, '0123-A', 'حوض', 'أبيض', 90000, 4), (71, 7, NULL, 'Q', 'غير مطابق', NULL, 1000, NULL)
  ''');
  await db.customStatement('''
    INSERT INTO discount_rules (id, supplier_id, scope, brand_id, percent_bp, note)
    VALUES (1, 1, 'brand', 1, 2100, 'قديم'), (2, 1, 'supplier', NULL, 500, NULL)
  ''');
  await db.customStatement('''
    INSERT INTO sales_invoices (id, number, date, subtotal, discount, total) VALUES (1, 'S-1', 1700000000, 30000, 100, 29900)
  ''');
  await db.customStatement('''
    INSERT INTO sales_invoice_items (id, invoice_id, product_id, qty, unit_price, unit_cost, line_total)
    VALUES (1, 1, 1, 1000, 10000, 7171, 10000), (2, 1, 1, 2000, 10000, 7171, 20000)
  ''');
  await db.customStatement('''
    INSERT INTO customers (id, name) VALUES (1, 'ع')
  ''');
  await db.customStatement('''
    INSERT INTO sales_orders (id, number, customer_id, order_date) VALUES (1, 'SO-1', 1, 1700000000)
  ''');
  await db.customStatement('''
    INSERT INTO sales_order_lines (id, order_id, product_id, qty, base_discount_bp, list_price, unit_price)
    VALUES (1, 1, 1, 1000, 1000, 50000, 45000)
  ''');
  await db.customStatement('PRAGMA user_version = 10');
  await db.close();
}

void main() {
  late Directory dir;
  late File file;
  late AppDatabase db;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('erp_v11');
    file = File('${dir.path}/shop.db');
    await makeSchema10(file);
    db = AppDatabase(NativeDatabase(file));
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test('the master keeps its code as Product ID and maker code; price columns are gone', () async {
    final products = await (db.select(db.products)..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    expect(products[0].code, '0123-A');
    expect(products[0].manufacturerCode, '0123-A');
    expect(products[0].matchKey, '0123-A');
    expect(products[1].matchKey, 'X9');
    final cols = await db.customSelect('PRAGMA table_info(products)').get();
    final names = cols.map((c) => c.read<String>('name'));
    for (final gone in ['cost_price', 'price_retail', 'price_wholesale', 'price_contractor']) {
      expect(names, isNot(contains(gone)));
    }
  });

  test('old supplier lists are kept as versions pending review, with no VAT assumed', () async {
    final old = await (db.select(db.priceLists)..where((l) => l.id.equals(7))).getSingle();
    expect(old.brandId, 1);
    expect(old.status, PriceListStatus.pendingReview);
    expect(old.vatStatus, VatStatus.unverified);
    expect(old.rowCount, 2);
    expect(old.note, contains('مورد أ'));
    expect(old.note, contains('ملاحظة'));
    final items = await (db.select(db.priceListItems)..where((i) => i.priceListId.equals(7))).get();
    final kept = items.firstWhere((i) => i.id == 70);
    expect(kept.price, 90000);
    expect(kept.manufacturerCode, '0123-A');
    expect(kept.variant, 'أبيض');
    expect(kept.packSize, 4);
    expect(kept.status, PriceRowStatus.ok);
    expect(items.firstWhere((i) => i.id == 71).status, PriceRowStatus.review);
  });

  test('prices that were on the product move to lists waiting for review; a zero is no price', () async {
    final lists = await db.select(db.priceLists).get();
    final legacy = lists.where((l) => l.listType.startsWith('legacy_')).toList();
    final items = await db.select(db.priceListItems).get();
    int? priceOf(String type, int? brand, int product) {
      final l = legacy.where((x) => x.listType == type && x.brandId == brand).firstOrNull;
      if (l == null) return null;
      return items.where((i) => i.priceListId == l.id && i.productId == product).firstOrNull?.price;
    }

    expect(priceOf('legacy_retail', 1, 1), 50000);
    expect(priceOf('legacy_wholesale', 1, 1), 45000);
    expect(priceOf('legacy_contractor', 1, 1), isNull);
    expect(priceOf('legacy_retail', null, 2), 200);
    expect(items.where((i) => i.productId == 3), isEmpty);
    expect(legacy.every((l) => l.status == PriceListStatus.pendingReview), isTrue);
    expect(legacy.firstWhere((l) => l.listType == 'legacy_wholesale').pricingTypeOnly, PricingType.b2b);

    // Until reviewed they price nothing.
    expect(await PriceListService(db).quotesFor(1), isEmpty);
  });

  test('a reviewed list starts pricing', () async {
    final admin = User(
      id: 1, username: 'a', passwordHash: '', salt: '', fullName: 'a', role: 'admin', isActive: true,
      createdAt: DateTime(2026), updatedAt: DateTime(2026),
    );
    await db.customStatement(
        "INSERT INTO users (id, username, password_hash, salt, full_name, role) VALUES (1, 'a', '', '', 'a', 'admin')");
    final lists = await db.select(db.priceLists).get();
    final retail = lists.firstWhere((l) => l.listType == 'legacy_retail' && l.brandId == 1);
    await PriceListService(db).approvePending(retail.id, brandId: 1, vatStatus: VatStatus.inclusive, user: admin);
    final quotes = await PriceListService(db).quotesFor(1, pricingType: PricingType.b2c);
    expect(quotes.single.price, 50000);
    expect(await PriceListService(db).quotesFor(1, pricingType: PricingType.b2b), isEmpty);
  });

  test('old supplier discounts wait switched off, with the percent kept', () async {
    final rows = await db.select(db.buyingPolicies).get();
    expect(rows, hasLength(2));
    expect(rows.every((r) => !r.isActive), isTrue);
    expect(rows.every((r) => r.priceListId == null), isTrue);
    expect(rows.map((r) => r.baseDiscountBp).toSet(), {2100, 500});
    expect(rows.firstWhere((r) => r.baseDiscountBp == 2100).brandId, 1);
    expect(rows.firstWhere((r) => r.baseDiscountBp == 2100).note, contains('قديم'));
    final tables = await db.customSelect("SELECT name FROM sqlite_master WHERE name = 'discount_rules'").get();
    expect(tables, isEmpty);
  });

  test('past invoices get their discount split over lines, exactly', () async {
    final items = await (db.select(db.salesInvoiceItems)..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    expect(items.map((i) => i.invoiceDiscountShare), [33, 67]);
    expect(items.map((i) => i.netTotal), [9967, 19933]);
    expect(items.first.priceListId, isNull);
  });

  test('schema 12: past sale lines get their cost total', () async {
    final items = await (db.select(db.salesInvoiceItems)..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    expect(items.map((i) => i.costTotal), [7171, 14342]);
  });

  test('order lines keep what they froze: base discount becomes the customer discount', () async {
    final l = await db.select(db.salesOrderLines).getSingle();
    expect(l.customerDiscountBp, 1000);
    expect(l.listPrice, 50000);
    expect(l.unitPrice, 45000);
  });

  test('schema 12: purchase lines get their discount share; layers from a known list keep it', () async {
    // From 11 to 12 only, on a database with a purchase already in it.
    final d2 = await Directory.systemTemp.createTemp('erp_v12');
    final f2 = File('${d2.path}/shop.db');
    var old = AppDatabase(NativeDatabase(f2));
    await old.customStatement("INSERT INTO suppliers (id, name) VALUES (1, 'م')");
    await old.customStatement("INSERT INTO products (id, code, name_ar) VALUES (1, 'A', 'أ')");
    await old.customStatement('''
      INSERT INTO purchase_invoices (id, number, date, supplier_id, subtotal, discount, total)
      VALUES (1, 'P-1', 1700000000, 1, 30000, 100, 29900)
    ''');
    await old.customStatement('''
      INSERT INTO purchase_invoice_items (id, invoice_id, product_id, qty, unit_cost, line_total, price_list_id, list_price)
      VALUES (1, 1, 1, 1000, 10000, 10000, 9, 11000), (2, 1, 1, 2000, 10000, 20000, 9, 11000)
    ''');
    await old.customStatement('''
      INSERT INTO cost_layers (id, product_id, location_id, qty_received, qty_remaining, unit_cost, received_at, source_type, source_id)
      VALUES (1, 1, 1, 3000, 3000, 10000, 1700000000, 'purchase', 1)
    ''');
    for (final c in ['invoice_discount_share', 'net_total']) {
      await old.customStatement('ALTER TABLE purchase_invoice_items DROP COLUMN $c');
    }
    for (final c in ['price_list_id', 'list_price']) {
      await old.customStatement('ALTER TABLE cost_layers DROP COLUMN $c');
    }
    await old.customStatement('ALTER TABLE sales_invoice_items DROP COLUMN cost_total');
    await old.customStatement('PRAGMA user_version = 11');
    await old.close();

    old = AppDatabase(NativeDatabase(f2));
    final items = await (old.select(old.purchaseInvoiceItems)..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    expect(items.map((i) => i.invoiceDiscountShare), [33, 67]);
    expect(items.map((i) => i.netTotal), [9967, 19933]);
    final layer = await old.select(old.costLayers).getSingle();
    expect(layer.priceListId, 9);
    expect(layer.listPrice, 11000);
    expect(layer.unitCost, 10000, reason: 'costs already in stock are not rewritten');
    await old.close();
    await d2.delete(recursive: true);
  });

  test('the file is sound after the upgrade', () async {
    expect(await db.integrityOk(), isTrue);
    final fk = await db.customSelect('PRAGMA foreign_key_check').get();
    expect(fk, isEmpty);
  });
}
