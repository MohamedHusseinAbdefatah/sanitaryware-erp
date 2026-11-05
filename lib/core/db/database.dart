import 'package:drift/drift.dart';

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
  DiscountRules,
  Reservations,
  PurchaseOrders,
  PurchaseOrderLines,
  PurchaseOrderReceipts,
  SalesOrders,
  SalesOrderLines,
  SalesOrderDeliveries,
  Approvals,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => latestSchemaVersion;

  static const latestSchemaVersion = 10;

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

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _seedMainLocation();
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
            // v5: supplier price lists and optional discount rules.
            if (!await _tableExists('price_lists')) await m.createTable(priceLists);
            if (!await _tableExists('price_list_items')) await m.createTable(priceListItems);
            if (!await _tableExists('discount_rules')) await m.createTable(discountRules);
            await m.createIndex(Index('idx_price_list_items_list',
                'CREATE INDEX IF NOT EXISTS idx_price_list_items_list ON price_list_items (price_list_id)'));
            await m.createIndex(Index('idx_price_list_items_product',
                'CREATE INDEX IF NOT EXISTS idx_price_list_items_product ON price_list_items (product_id)'));
            await m.createIndex(Index('idx_discount_rules_supplier',
                'CREATE INDEX IF NOT EXISTS idx_discount_rules_supplier ON discount_rules (supplier_id)'));
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
        },
        beforeOpen: (details) async {
          // Make SQLite enforce references between tables.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
