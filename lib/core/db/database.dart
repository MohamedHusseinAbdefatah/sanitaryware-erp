import 'package:drift/drift.dart';

import '../pricing_math.dart';
import '../services/stock_price_service.dart';
import 'tables.dart';

part 'database.g.dart';

@DriftDatabase(tables: [
  Users,
  AppSettings,
  Categories,
  Brands,
  Units,
  Products,
  StockMovements,
  Customers,
  Suppliers,
  SalesInvoices,
  SalesInvoiceItems,
  PurchaseInvoices,
  PurchaseInvoiceItems,
  Returns,
  ReturnItems,
  Payments,
  Cheques,
  ExpenseCategories,
  Expenses,
  AuditLogs,
  Locations,
  CostLayers,
  LayerConsumptions,
  PriceLists,
  PriceListItems,
  BuyingPolicies,
  CustomerCategories,
  SellingPolicies,
  Reservations,
  PurchaseOrders,
  PurchaseOrderLines,
  PurchaseOrderReceipts,
  SalesOrders,
  SalesOrderLines,
  SalesOrderDeliveries,
  Approvals,
  SupplierAdvances,
  SupplierAdvanceLists,
  ProductImages,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => latestSchemaVersion;

  static const latestSchemaVersion = 16;

  /// The categories every shop starts with. The first three are the old
  /// price levels; discounts start at 0 until the owner sets them.
  static const starterCategories = [
    ('قطاعي', 'b2c', 'retail'),
    ('جملة', 'b2b', 'wholesale'),
    ('مشروعات ومقاولون', 'project', 'contractor'),
    ('مهندسين', null, null),
  ];

  Future<void> _seedCustomerCategories() async {
    final row = await customSelect('SELECT COUNT(*) AS c FROM customer_categories').getSingle();
    if (row.read<int>('c') > 0) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < starterCategories.length; i++) {
      final (name, type, _) = starterCategories[i];
      await customStatement(
        'INSERT INTO customer_categories (id, name, discount_bp, legacy_type, is_active, created_at, updated_at) '
        'VALUES (?, ?, 0, ?, 1, ?, ?)',
        [i + 1, name, type, now, now],
      );
    }
  }

  /// SQLite's own check of the file; false means the file is damaged.
  Future<bool> integrityOk() async {
    final rows = await customSelect('PRAGMA integrity_check').get();
    return rows.length == 1 && rows.single.data.values.first == 'ok';
  }

  Future<bool> _tableExists(String name) async {
    final rows = await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable.withString(name)],
    ).get();
    return rows.isNotEmpty;
  }

  Future<bool> _columnExists(String table, String column) async {
    final rows = await customSelect('PRAGMA table_info($table)').get();
    return rows.any((r) => r.read<String>('name') == column);
  }

  /// The main warehouse (id 1) always exists.
  Future<void> _seedMainLocation() async {
    final row = await customSelect('SELECT COUNT(*) AS c FROM locations').getSingle();
    if (row.read<int>('c') == 0) {
      await customStatement(
          "INSERT INTO locations (id, name, kind) VALUES (1, 'المخزن الرئيسي', 'warehouse')");
    }
  }

  /// Turns the stock a shop has today into one opening layer per product,
  /// at the product's current average cost, so FIFO starts from the same
  /// stock and value the shop already had. Products with no stock (or
  /// negative stock) get no layer.
  Future<void> _backfillCostLayers() async {
    await customStatement('''
      INSERT INTO cost_layers
        (product_id, location_id, qty_received, qty_remaining, unit_cost, received_at, source_type)
      SELECT m.product_id, 1, SUM(m.qty), SUM(m.qty), p.cost_price, MIN(m.date), 'opening'
      FROM stock_movements m
      JOIN products p ON p.id = m.product_id
      GROUP BY m.product_id
      HAVING SUM(m.qty) > 0
    ''');
  }

  Future<void> _addColumns(Migrator m, TableInfo table, List<GeneratedColumn> columns) async {
    if (!await _tableExists(table.actualTableName)) return;
    for (final c in columns) {
      if (!await _columnExists(table.actualTableName, c.name)) await m.addColumn(table, c);
    }
  }

  /// Schema 11, blueprint section 3. Nothing is thrown away: old prices and
  /// discounts move to where the blueprint keeps them, marked for review,
  /// because nobody has verified them against a source yet.
  Future<void> _upgradeToV11(Migrator m) async {
    // Product master: new fields; the maker's code starts as the old code.
    await _addColumns(m, products, [
      products.manufacturerCode,
      products.matchKey,
      products.description,
      products.subcategoryId,
      products.series,
      products.dimensions,
      products.variant,
      products.finish,
      products.barcode,
      products.technicalSpecs,
      products.vatBasis,
      products.vatRateBp,
    ]);
    final codes = await _columnExists('products', 'code')
        ? await customSelect('SELECT id, code FROM products').get()
        : const <QueryRow>[];
    for (final r in codes) {
      final code = r.read<String>('code');
      await customStatement(
        'UPDATE products SET manufacturer_code = ?, match_key = ? WHERE id = ?',
        [code, matchKeyOf(code), r.read<int>('id')],
      );
    }
    await m.createIndex(Index('idx_products_match_key',
        'CREATE INDEX IF NOT EXISTS idx_products_match_key ON products (match_key)'));

    // Price lists: no longer tied to a supplier. Each old list becomes a
    // version waiting for review; its supplier and VAT tick go into the note.
    final now = DateTime.now();
    if (await _columnExists('price_lists', 'supplier_id')) {
      await customStatement('ALTER TABLE price_list_items RENAME TO price_list_items_v10');
      await customStatement('ALTER TABLE price_lists RENAME TO price_lists_v10');
      await m.createTable(priceLists);
      await m.createTable(priceListItems);
      await customStatement('''
        INSERT INTO price_lists (id, name, brand_id, list_type, version_no, currency, effective_from,
          import_date, source_file, row_count, vat_status, status, note, created_at, updated_at)
        SELECT l.id, l.name, l.brand_id, 'قائمة المورد ' || s.name,
          (SELECT COUNT(*) FROM price_lists_v10 x
            WHERE x.supplier_id = l.supplier_id AND COALESCE(x.brand_id, 0) = COALESCE(l.brand_id, 0) AND x.id <= l.id),
          'EGP', l.effective_date, l.created_at, 'ترحيل من الإصدار السابق',
          (SELECT COUNT(*) FROM price_list_items_v10 i WHERE i.price_list_id = l.id),
          'unverified', 'pending_review',
          'كانت قائمة المورد: ' || s.name ||
            CASE l.vat_included WHEN 1 THEN ' — مسجلة شاملة الضريبة دون تحقق' ELSE ' — مسجلة بدون ضريبة دون تحقق' END ||
            COALESCE(' — ' || l.note, ''),
          l.created_at, l.updated_at
        FROM price_lists_v10 l JOIN suppliers s ON s.id = l.supplier_id
      ''');
      await customStatement('''
        INSERT INTO price_list_items (id, price_list_id, product_id, manufacturer_code, name, variant,
          price, pack_size, status, review_reason)
        SELECT id, price_list_id, product_id, supplier_code, name, colour, price, pack_size,
          CASE WHEN product_id IS NULL THEN 'review' ELSE 'ok' END,
          CASE WHEN product_id IS NULL THEN 'لم يطابق صنفاً في الأصناف' END
        FROM price_list_items_v10
      ''');
      await customStatement('DROP TABLE price_list_items_v10');
      await customStatement('DROP TABLE price_lists_v10');
    }
    await m.createIndex(Index('idx_price_list_items_list',
        'CREATE INDEX IF NOT EXISTS idx_price_list_items_list ON price_list_items (price_list_id)'));
    await m.createIndex(Index('idx_price_list_items_product',
        'CREATE INDEX IF NOT EXISTS idx_price_list_items_product ON price_list_items (product_id)'));

    // The old prices on the product become lists of their own, one per brand
    // and level, waiting for review. A price of zero meant "no price".
    if (await _columnExists('products', 'price_retail')) {
      const levels = [
        ('price_retail', 'legacy_retail', 'b2c', 'قطاعي'),
        ('price_wholesale', 'legacy_wholesale', 'b2b', 'جملة'),
        ('price_contractor', 'legacy_contractor', 'project', 'مقاولين'),
      ];
      for (final (column, type, pricing, label) in levels) {
        final brands =
            await customSelect('SELECT DISTINCT brand_id FROM products WHERE $column > 0').get();
        for (final b in brands) {
          final brandId = b.readNullable<int>('brand_id');
          final listId = await into(priceLists).insert(PriceListsCompanion.insert(
            name: 'أسعار سابقة — $label',
            brandId: Value(brandId),
            listType: type,
            effectiveFrom: dayOf(now),
            importDate: now,
            sourceFile: const Value('ترحيل من الإصدار السابق'),
            status: const Value('pending_review'),
            pricingTypeOnly: Value(pricing),
            note: const Value('أسعار كانت مسجلة على الصنف. راجعها وحدد الماركة والضريبة قبل اعتمادها.'),
          ));
          await customStatement(
            'INSERT INTO price_list_items (price_list_id, product_id, manufacturer_code, name, variant, price, status) '
            "SELECT ?, id, manufacturer_code, name_ar, variant, $column, 'ok' FROM products "
            'WHERE $column > 0 AND ${brandId == null ? 'brand_id IS NULL' : 'brand_id = ?'}',
            [listId, if (brandId != null) brandId],
          );
          await customStatement(
            'UPDATE price_lists SET row_count = (SELECT COUNT(*) FROM price_list_items WHERE price_list_id = ?) WHERE id = ?',
            [listId, listId],
          );
        }
      }
    }
    // Master data holds no price and no changing cost any more.
    for (final c in ['cost_price', 'price_retail', 'price_wholesale', 'price_contractor']) {
      if (await _columnExists('products', c)) {
        await customStatement('ALTER TABLE products DROP COLUMN $c');
      }
    }

    // Policies. Old supplier discounts wait, switched off, until someone ties
    // each to a brand and a price list.
    await m.createTable(buyingPolicies);
    await m.createTable(sellingPolicies);
    await m.createIndex(Index('idx_buying_policies_supplier',
        'CREATE INDEX IF NOT EXISTS idx_buying_policies_supplier ON buying_policies (supplier_id)'));
    await m.createIndex(Index('idx_selling_policies_list',
        'CREATE INDEX IF NOT EXISTS idx_selling_policies_list ON selling_policies (price_list_id)'));
    if (await _tableExists('discount_rules')) {
      await customStatement('''
        INSERT INTO buying_policies (supplier_id, brand_id, scope, category_id, product_id, base_discount_bp,
          valid_from, valid_to, is_active, note)
        SELECT supplier_id, brand_id,
          CASE scope WHEN 'category' THEN 'category' WHEN 'product' THEN 'product' ELSE 'all' END,
          category_id, product_id, percent_bp, valid_from, valid_to, 0,
          'مرحّل من خصومات الموردين — يحتاج ماركة وقائمة أسعار' || COALESCE(' — ' || note, '')
        FROM discount_rules
      ''');
      await customStatement('DROP TABLE discount_rules');
    }

    // Documents keep which version they used.
    await _addColumns(m, salesInvoiceItems, [
      salesInvoiceItems.priceListId,
      salesInvoiceItems.listPrice,
      salesInvoiceItems.pricingType,
      salesInvoiceItems.sellingPolicyId,
      salesInvoiceItems.policyDiscountBp,
      salesInvoiceItems.customerDiscountBp,
      salesInvoiceItems.extraDiscountBp,
      salesInvoiceItems.invoiceDiscountShare,
      salesInvoiceItems.netTotal,
      salesInvoiceItems.vatStatus,
      salesInvoiceItems.vatRateBp,
      salesInvoiceItems.vatAmount,
    ]);
    await _addColumns(m, purchaseInvoiceItems, [
      purchaseInvoiceItems.priceListId,
      purchaseInvoiceItems.listPrice,
      purchaseInvoiceItems.buyingPolicyId,
      purchaseInvoiceItems.baseDiscountBp,
      purchaseInvoiceItems.extraDiscountBp,
    ]);
    await _addColumns(m, purchaseOrderLines, [
      purchaseOrderLines.buyingPolicyId,
      purchaseOrderLines.extraDiscountBp,
    ]);
    if (await _columnExists('sales_order_lines', 'base_discount_bp')) {
      await customStatement(
          'ALTER TABLE sales_order_lines RENAME COLUMN base_discount_bp TO customer_discount_bp');
    }
    await _addColumns(m, salesOrderLines, [
      salesOrderLines.priceListId,
      salesOrderLines.pricingType,
      salesOrderLines.sellingPolicyId,
      salesOrderLines.policyDiscountBp,
      salesOrderLines.vatStatus,
      salesOrderLines.vatRateBp,
    ]);

    // Past invoices: split each invoice discount over its lines, exactly.
    if (!await _tableExists('sales_invoice_items') || !await _columnExists('sales_invoice_items', 'line_total')) return;
    await customStatement('UPDATE sales_invoice_items SET net_total = line_total');
    final discounted = await customSelect('SELECT id, discount FROM sales_invoices WHERE discount > 0').get();
    for (final inv in discounted) {
      final items = await customSelect(
        'SELECT id, line_total FROM sales_invoice_items WHERE invoice_id = ? ORDER BY id',
        variables: [Variable.withInt(inv.read<int>('id'))],
      ).get();
      final shares = allocateProportionally(
          inv.read<int>('discount'), [for (final i in items) i.read<int>('line_total')]);
      for (var k = 0; k < items.length; k++) {
        await customStatement(
          'UPDATE sales_invoice_items SET invoice_discount_share = ?, net_total = line_total - ? WHERE id = ?',
          [shares[k], shares[k], items[k].read<int>('id')],
        );
      }
    }
  }

  /// Schema 12: stock remembers the list version it came in under, a sale line
  /// keeps its exact cost, and a purchase line its share of the invoice discount.
  /// Costs already in stock are history and are not rewritten.
  Future<void> _upgradeToV12(Migrator m) async {
    await _addColumns(m, costLayers, [costLayers.priceListId, costLayers.listPrice]);
    await _addColumns(m, salesInvoiceItems, [salesInvoiceItems.costTotal]);
    await _addColumns(m, purchaseInvoiceItems, [
      purchaseInvoiceItems.invoiceDiscountShare,
      purchaseInvoiceItems.netTotal,
    ]);
    if (await _tableExists('sales_invoice_items') && await _columnExists('sales_invoice_items', 'unit_cost')) {
      await customStatement('UPDATE sales_invoice_items SET cost_total = (qty * unit_cost + 500) / 1000');
    }
    if (await _tableExists('purchase_invoice_items') && await _columnExists('purchase_invoice_items', 'line_total')) {
      await customStatement('UPDATE purchase_invoice_items SET net_total = line_total');
      final discounted = await customSelect('SELECT id, discount FROM purchase_invoices WHERE discount > 0').get();
      for (final inv in discounted) {
        final items = await customSelect(
          'SELECT id, line_total FROM purchase_invoice_items WHERE invoice_id = ? ORDER BY id',
          variables: [Variable.withInt(inv.read<int>('id'))],
        ).get();
        final shares = allocateProportionally(
            inv.read<int>('discount'), [for (final i in items) i.read<int>('line_total')]);
        for (var k = 0; k < items.length; k++) {
          await customStatement(
            'UPDATE purchase_invoice_items SET invoice_discount_share = ?, net_total = line_total - ? WHERE id = ?',
            [shares[k], shares[k], items[k].read<int>('id')],
          );
        }
      }
      if (await _tableExists('cost_layers')) {
        await customStatement('''
          UPDATE cost_layers SET
            price_list_id = (SELECT i.price_list_id FROM purchase_invoice_items i
              WHERE i.invoice_id = cost_layers.source_id AND i.product_id = cost_layers.product_id
                AND i.price_list_id IS NOT NULL LIMIT 1),
            list_price = (SELECT i.list_price FROM purchase_invoice_items i
              WHERE i.invoice_id = cost_layers.source_id AND i.product_id = cost_layers.product_id
                AND i.price_list_id IS NOT NULL LIMIT 1)
          WHERE source_type = 'purchase'
        ''');
        if (await _tableExists('price_lists') && await _columnExists('price_lists', 'list_type')) {
          await StockPriceService(this).stampUnknown();
        }
      }
    }
  }

  /// Schema 13: customer categories the owner names, and selling discounts by
  /// category and brand that hold for every price list version. Each old
  /// price level becomes its category; each old selling policy becomes a rule
  /// for that category and brand, with the same discount and limits.
  Future<void> _upgradeToV13(Migrator m) async {
    if (!await _tableExists('customer_categories')) await m.createTable(customerCategories);
    await _seedCustomerCategories();
    await _addColumns(m, customers, [customers.categoryId]);
    if (await _tableExists('customers')) {
      for (var i = 0; i < 3; i++) {
        await customStatement(
          'UPDATE customers SET category_id = ? WHERE category_id IS NULL AND price_level = ?',
          [i + 1, starterCategories[i].$3],
        );
      }
      await customStatement('UPDATE customers SET category_id = 1 WHERE category_id IS NULL');
    }
    if (await _tableExists('selling_policies') && !await _columnExists('selling_policies', 'customer_category_id')) {
      await customStatement('DROP INDEX IF EXISTS idx_selling_policies_list');
      await customStatement('ALTER TABLE selling_policies RENAME TO selling_policies_v12');
      await m.createTable(sellingPolicies);
      await customStatement('''
        INSERT INTO selling_policies (id, customer_category_id, brand_id, price_list_id, pricing_type, scope,
          category_id, product_id, discount_bp, max_discount_bp, min_margin_bp, valid_from, valid_to,
          is_active, note, created_at, updated_at)
        SELECT id, CASE pricing_type WHEN 'b2b' THEN 2 WHEN 'project' THEN 3 ELSE 1 END, brand_id,
          price_list_id, pricing_type, scope, category_id, product_id, discount_bp, max_discount_bp,
          min_margin_bp, valid_from, valid_to, is_active, note, created_at, updated_at
        FROM selling_policies_v12
      ''');
      await customStatement('DROP TABLE selling_policies_v12');
    } else if (!await _tableExists('selling_policies')) {
      await m.createTable(sellingPolicies);
    }
    await customStatement('CREATE INDEX IF NOT EXISTS idx_selling_policies_customer_category '
        'ON selling_policies (customer_category_id)');
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _seedMainLocation();
          await _seedCustomerCategories();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // v2: quantities became thousandths; units can allow fractions.
            await m.addColumn(units, units.allowDecimal);
            await m.createIndex(Index('idx_products_name_ar',
                'CREATE INDEX IF NOT EXISTS idx_products_name_ar ON products (name_ar)'));
          }
          if (from < 3) {
            // v3: index for "paid on this invoice" (sales list was slow with a year of data).
            await m.createIndex(Index('idx_payments_invoice_ref',
                'CREATE INDEX IF NOT EXISTS idx_payments_invoice_ref ON payments (invoice_ref_type, invoice_ref_id)'));
          }
          if (from < 4) {
            // v4: stock locations and FIFO cost layers. Every step checks
            // before it acts, so it is safe to run on a half-upgraded file.
            final hadLayers = await _tableExists('cost_layers');
            if (!await _tableExists('locations')) await m.createTable(locations);
            if (!hadLayers) await m.createTable(costLayers);
            if (!await _tableExists('layer_consumptions')) await m.createTable(layerConsumptions);
            await m.createIndex(Index('idx_cost_layers_fifo',
                'CREATE INDEX IF NOT EXISTS idx_cost_layers_fifo ON cost_layers (product_id, location_id, received_at)'));
            await m.createIndex(Index('idx_layer_consumptions_ref',
                'CREATE INDEX IF NOT EXISTS idx_layer_consumptions_ref ON layer_consumptions (ref_type, ref_id)'));
            final hasMovements = await _tableExists('stock_movements');
            if (hasMovements && !await _columnExists('stock_movements', 'location_id')) {
              // Existing movements all belong to the main warehouse (id 1).
              await m.addColumn(stockMovements, stockMovements.locationId);
            }
            await _seedMainLocation();
            if (!hadLayers && hasMovements && await _columnExists('products', 'cost_price')) {
              await _backfillCostLayers();
            }
          }
          if (from < 5) {
            // v5: price lists. (Their discount rules became buying policies in v11.)
            if (!await _tableExists('price_lists')) await m.createTable(priceLists);
            if (!await _tableExists('price_list_items')) await m.createTable(priceListItems);
          }
          if (from < 6) {
            // v6: a customer's usual discount (optional, 0 = none).
            if (await _tableExists('customers') && !await _columnExists('customers', 'discount_bp')) {
              await m.addColumn(customers, customers.discountBp);
            }
          }
          if (from < 7) {
            // v7: stock reservations.
            if (!await _tableExists('reservations')) await m.createTable(reservations);
            await m.createIndex(Index('idx_reservations_product',
                'CREATE INDEX IF NOT EXISTS idx_reservations_product ON reservations (product_id)'));
          }
          if (from < 8) {
            // v8: purchase orders with a price lock.
            if (!await _tableExists('purchase_orders')) await m.createTable(purchaseOrders);
            if (!await _tableExists('purchase_order_lines')) await m.createTable(purchaseOrderLines);
            if (!await _tableExists('purchase_order_receipts')) await m.createTable(purchaseOrderReceipts);
            await m.createIndex(Index('idx_po_lines_order',
                'CREATE INDEX IF NOT EXISTS idx_po_lines_order ON purchase_order_lines (order_id)'));
          }
          if (from < 9) {
            // v9: sales orders with a price lock.
            if (!await _tableExists('sales_orders')) await m.createTable(salesOrders);
            if (!await _tableExists('sales_order_lines')) await m.createTable(salesOrderLines);
            if (!await _tableExists('sales_order_deliveries')) await m.createTable(salesOrderDeliveries);
            await m.createIndex(Index('idx_so_lines_order',
                'CREATE INDEX IF NOT EXISTS idx_so_lines_order ON sales_order_lines (order_id)'));
          }
          if (from < 10) {
            // v10: log of manager approvals.
            if (!await _tableExists('approvals')) await m.createTable(approvals);
            await m.createIndex(Index('idx_approvals_doc',
                'CREATE INDEX IF NOT EXISTS idx_approvals_doc ON approvals (doc_type, doc_id)'));
          }
          if (from < 11) await _upgradeToV11(m);
          if (from < 12) await _upgradeToV12(m);
          if (from < 13) await _upgradeToV13(m);
          if (from < 14) {
            // v14: extra costs on a purchase, its due date, and purchase expenses.
            await _addColumns(m, purchaseInvoices, [
              purchaseInvoices.extraCosts,
              purchaseInvoices.extraCostsOnSupplier,
              purchaseInvoices.dueDate,
            ]);
            await _addColumns(m, purchaseInvoiceItems, [purchaseInvoiceItems.extraCostShare]);
            await _addColumns(m, expenses, [expenses.purchaseInvoiceId]);
          }
          if (from < 15) {
            // v15: reservations from orders, and supplier advances locked to lists.
            await _addColumns(m, reservations, [reservations.salesOrderLineId]);
            await _addColumns(m, purchaseOrderLines, [purchaseOrderLines.salesOrderLineId]);
            await _addColumns(m, purchaseInvoices, [purchaseInvoices.advanceId, purchaseInvoices.advanceUsed]);
            if (!await _tableExists('supplier_advances')) await m.createTable(supplierAdvances);
            if (!await _tableExists('supplier_advance_lists')) await m.createTable(supplierAdvanceLists);
          }
          if (from < 16) {
            // v16: product photos.
            if (!await _tableExists('product_images')) await m.createTable(productImages);
          }
        },
        beforeOpen: (details) async {
          // Make SQLite enforce references between tables.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
