@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sanitaryware_erp/core/auth/auth_service.dart';
import 'package:sanitaryware_erp/core/auth/password_hasher.dart';
import 'package:sanitaryware_erp/core/backup/backup_service.dart';
import 'package:sanitaryware_erp/core/db/connection.dart';
import 'package:sanitaryware_erp/core/db/data_dir.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/balance_service.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/product_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';
import 'package:sanitaryware_erp/core/services/settings_service.dart';
import 'package:sanitaryware_erp/core/services/stock_service.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

/// What a client upgrading the program must find afterwards: the same
/// users, passwords, stock, invoices and balances. This is the release
/// gate for "data survives an update" (the bug fixed in 1.0.1 was exactly
/// a new version opening an empty database).
void main() {
  late Directory appData;

  setUp(() async => appData = await Directory.systemTemp.createTemp('erp_upgrade'));
  tearDown(() => appData.delete(recursive: true));

  /// A shop as version 1.0.0 left it, in the folder 1.0.0 used.
  Future<({String folder, int customerId, int productId})> oldShop() async {
    final folder = legacyDataDirs(appData.path).first; // the 1.0.0 folder
    await Directory(folder).create(recursive: true);
    final db = AppDatabase(NativeDatabase(File(p.join(folder, 'erp.sqlite'))));
    final auth = AuthService(db, hasher: const PasswordHasher(iterations: 10));
    final admin = await auth.firstRunSetup(
      company: const CompanyInfo(name: 'معرض قديم'),
      fullName: 'المدير',
      username: 'owner',
      password: 'secret-1',
    );
    final piece = (await db.select(db.units).get()).first.id;
    final product = await ProductService(db).create(
      ProductInput(code: 'M1', nameAr: 'خلاط', unitId: piece),
      openingQty: qtyOf(10),
      openingCost: 40000,
    );
    final customer = await PartyService(db).saveCustomer(const CustomerInput(name: 'عميل', openingBalance: 10000));
    await SalesService(db).post(
      SaleInput(
        customerId: customer,
        lines: [SaleLineInput(productId: product.id, qty: qtyOf(3), unitPrice: 50000)],
        paidAmount: 20000,
      ),
      userId: admin.id,
    );
    await db.close();
    return (folder: folder, customerId: customer, productId: product.id);
  }

  /// The program's real start-up: find the data folder, then open it.
  Future<StartupResult> startNewVersion() async {
    final paths = AppPaths(await prepareDataDir(appData.path));
    return openAppDatabase(paths, BackupService(dir: paths.backupDir));
  }

  Future<void> expectSameShop(AppDatabase db, int customerId, int productId) async {
    expect(await db.integrityOk(), isTrue);
    expect(await AuthService(db).hasAnyUser(), isTrue); // no setup screen
    expect((await AuthService(db).login('owner', 'secret-1')).fullName, 'المدير');
    expect(await StockService(db).currentStock(productId), qtyOf(7));
    expect(await BalanceService(db).customerBalance(customerId), 10000 + 150000 - 20000);
    expect((await db.select(db.salesInvoices).get()).single.number, 'S-000001');
    expect((await SettingsService(db).company()).name, 'معرض قديم');
  }

  test('updating from 1.0.0 (old folder) keeps everything', () async {
    final old = await oldShop();
    final start = await startNewVersion();
    try {
      await expectSameShop(start.db, old.customerId, old.productId);
    } finally {
      await start.db.close();
    }
    // The data now lives in the fixed folder; the old one is untouched.
    expect(File(p.join(appData.path, dataFolderName, 'erp.sqlite')).existsSync(), isTrue);
    expect(File(p.join(old.folder, 'erp.sqlite')).existsSync(), isTrue);
  });

  test('a second update (already in the fixed folder) keeps everything too', () async {
    final old = await oldShop();
    await (await startNewVersion()).db.close();
    final again = await startNewVersion();
    try {
      await expectSameShop(again.db, old.customerId, old.productId);
    } finally {
      await again.db.close();
    }
  });

  test('a schema-2 database (version 1.0.x) gains the payments index, data intact', () async {
    final old = await oldShop();
    final raw = sql.sqlite3.open(p.join(old.folder, 'erp.sqlite'));
    raw.execute('DROP INDEX IF EXISTS idx_payments_invoice_ref');
    raw.execute('PRAGMA user_version = 2');
    raw.dispose();

    final start = await startNewVersion();
    try {
      await expectSameShop(start.db, old.customerId, old.productId);
      final index = await start.db
          .customSelect("SELECT name FROM sqlite_master WHERE name = 'idx_payments_invoice_ref'")
          .get();
      expect(index, hasLength(1));
    } finally {
      await start.db.close();
    }
  });

  test('a database from an older schema is backed up, upgraded and intact', () async {
    final old = await oldShop();
    // Turn it back into a schema-1 database (before the units fraction flag).
    final raw = sql.sqlite3.open(p.join(old.folder, 'erp.sqlite'));
    raw.execute('DROP INDEX IF EXISTS idx_products_name_ar');
    raw.execute('ALTER TABLE units DROP COLUMN allow_decimal');
    raw.execute('PRAGMA user_version = 1');
    raw.dispose();

    final start = await startNewVersion();
    try {
      await expectSameShop(start.db, old.customerId, old.productId);
      expect((await start.db.select(start.db.units).get()).every((u) => !u.allowDecimal), isTrue);
    } finally {
      await start.db.close();
    }
    final backups = await BackupService(dir: Directory(p.join(appData.path, dataFolderName, 'backups'))).list();
    expect(backups.map((b) => b.reason), contains(BackupReason.beforeMigration));
  });
}
