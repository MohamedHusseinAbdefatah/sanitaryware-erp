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
  int get schemaVersion => 2;

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
        },
        beforeOpen: (details) async {
          // Make SQLite enforce references between tables.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
