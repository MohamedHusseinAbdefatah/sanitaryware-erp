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
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => latestSchemaVersion;

  static const latestSchemaVersion = 3;

  /// SQLite's own check of the file; false means the file is damaged.
  Future<bool> integrityOk() async {
    final rows = await customSelect('PRAGMA integrity_check').get();
    return rows.length == 1 && rows.single.data.values.first == 'ok';
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
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
        },
        beforeOpen: (details) async {
          // Make SQLite enforce references between tables.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
