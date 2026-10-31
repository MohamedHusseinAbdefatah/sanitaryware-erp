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
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        beforeOpen: (details) async {
          // Make SQLite enforce references between tables.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );
}
