import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/backup/backup_service.dart';
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/reports/report_service.dart';
import 'package:sanitaryware_erp/core/services/buying_policy_service.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/expense_service.dart';
import 'package:sanitaryware_erp/core/services/ledger_service.dart';
import 'package:sanitaryware_erp/core/services/party_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_plan_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/reservation_service.dart';
import 'package:sanitaryware_erp/core/services/sales_order_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';

import '../support/fixture.dart';

/// The last blueprint items: the customer file (6.1), expense details (9.1),
/// purchase planning (4.1), reservation states (5.3) and timed backups (9.3).
void main() {
  late Shop shop;

  setUp(() async => shop = await Shop.open());
  tearDown(() => shop.close());

  Future<void> buy(int count, int cost) => PurchaseService(shop.db).post(
        PurchaseInput(
          supplierId: shop.supplierId,
          lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(count), unitCost: cost)],
        ),
        user: shop.admin,
      );

  group('customer file', () {
    test('email, tax number and payment terms are kept; an edit without them keeps them', () async {
      final parties = PartyService(shop.db);
      await parties.saveCustomer(
        const CustomerInput(name: 'شركة النخيل', email: 'buy@nakheel.example', taxNumber: '123-456-789', paymentTermsDays: 30),
        id: shop.customerId,
      );
      var c = await parties.customer(shop.customerId);
      expect((c.email, c.taxNumber, c.paymentTermsDays), ('buy@nakheel.example', '123-456-789', 30));
      // An update that does not mention them (an import, a quick edit) leaves them.
      await parties.saveCustomer(const CustomerInput(name: 'شركة النخيل'), id: shop.customerId);
      c = await parties.customer(shop.customerId);
      expect((c.email, c.paymentTermsDays), ('buy@nakheel.example', 30));
      await expectLater(
          parties.saveCustomer(const CustomerInput(name: 'x', paymentTermsDays: 400), id: shop.customerId),
          throwsA(isA<ValidationException>()));
    });

    test('contacts are added, edited and removed', () async {
      final parties = PartyService(shop.db);
      final id = await parties.saveContact(customerId: shop.customerId, name: 'م. سامي', role: 'مهندس الموقع', phone: '0100');
      await parties.saveContact(id: id, customerId: shop.customerId, name: 'م. سامي علي', role: 'مهندس الموقع');
      final list = await parties.watchContacts(shop.customerId).first;
      expect(list.single.name, 'م. سامي علي');
      await parties.deleteContact(id);
      expect(await parties.watchContacts(shop.customerId).first, isEmpty);
    });

    test('a credit sale falls due after the terms, and ages from that day', () async {
      await PartyService(shop.db).saveCustomer(const CustomerInput(name: 'عميل', paymentTermsDays: 30), id: shop.customerId);
      await buy(5, 30000);
      final day = DateTime(2026, 3, 1, 10);
      final inv = await SalesService(shop.db).post(
        SaleInput(
          customerId: shop.customerId,
          date: day,
          lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000, priceListId: shop.priceListId)],
        ),
        userId: shop.admin.id,
      );
      expect(inv.dueDate, DateTime(2026, 3, 31));
      final ledger = LedgerService(shop.db);
      // Twenty days after the sale it is not due yet; fifty days after, 1-30 late.
      expect((await ledger.aging(customers: true, asOf: DateTime(2026, 3, 21))).single.buckets[0], 50000);
      expect((await ledger.aging(customers: true, asOf: DateTime(2026, 4, 20))).single.buckets[1], 50000);
    });

    test('a sale paid in full has no due date', () async {
      await PartyService(shop.db).saveCustomer(const CustomerInput(name: 'عميل', paymentTermsDays: 30), id: shop.customerId);
      await buy(5, 30000);
      final inv = await SalesService(shop.db).post(
        SaleInput(
          customerId: shop.customerId,
          lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(1), unitPrice: 50000, priceListId: shop.priceListId)],
          paidAmount: 50000,
        ),
        userId: shop.admin.id,
      );
      expect(inv.dueDate, isNull);
    });
  });

  group('expenses', () {
    test('input VAT is posted apart, kept out of the expense and the profit, and reported', () async {
      final cat = (await shop.db.select(shop.db.expenseCategories).get()).first;
      final e = await ExpenseService(shop.db).add(
        ExpenseInput(
          categoryId: cat.id,
          amount: 11400,
          vatAmount: 1400,
          payee: 'شركة الكهرباء',
          docNumber: 'R-77',
          attachmentName: 'receipt.pdf',
          attachmentBytes: const [37, 80, 68, 70],
        ),
        user: shop.admin,
      );
      expect((e.payee, e.docNumber, e.vatAmount), ('شركة الكهرباء', 'R-77', 1400));
      final ledger = LedgerService(shop.db);
      final balances = await ledger.balances();
      int bal(bool Function(Account) f) => balances.where((b) => f(b.account)).fold(0, (s, b) => s + b.closing);
      expect(bal((a) => a.systemKey == 'vat_in'), 1400);
      expect(bal((a) => a.systemKey == 'cash'), -11400);
      expect(bal((a) => a.kind == AccountKind.expense), 10000);
      final now = DateTime.now();
      expect((await ledger.vat(from: now.subtract(const Duration(days: 1)), to: now)).inputVat, 1400);
      final profit = await ReportService(shop.db).build(ReportKind.profit, from: DateTime(2000), to: now);
      expect(profit.rows.firstWhere((r) => r[0] == 'المصروفات')[1], -10000, reason: 'expenses in the profit report without VAT');
      final file = await ExpenseService(shop.db).attachment(e.id);
      expect((file!.fileName, file.bytes.length), ('receipt.pdf', 4));
    });

    test('VAT cannot be the whole amount or more', () async {
      final cat = (await shop.db.select(shop.db.expenseCategories).get()).first;
      await expectLater(
        ExpenseService(shop.db).add(ExpenseInput(categoryId: cat.id, amount: 1000, vatAmount: 1000), user: shop.admin),
        throwsA(isA<ValidationException>()),
      );
    });
  });

  group('purchase planning', () {
    late int supplierB;

    setUp(() async {
      final parties = PartyService(shop.db);
      await parties.saveSupplier(const SupplierInput(name: 'مورد', leadTimeDays: 10), id: shop.supplierId);
      supplierB = await parties.saveSupplier(const SupplierInput(name: 'مورد ب', leadTimeDays: 20));
      final buying = BuyingPolicyService(shop.db);
      await buying.add(
          BuyingPolicyInput(supplierId: shop.supplierId, brandId: shop.brandId, priceListId: shop.priceListId, baseDiscountBp: 3000),
          user: shop.admin);
      await buying.add(
          BuyingPolicyInput(supplierId: supplierB, brandId: shop.brandId, priceListId: shop.priceListId, baseDiscountBp: 3500),
          user: shop.admin);
      // 90 sold in the last 90 days: one a day.
      await buy(100, 35000);
      for (var d = 1; d <= 3; d++) {
        await SalesService(shop.db).post(
          SaleInput(
            customerId: shop.customerId,
            date: DateTime.now().subtract(Duration(days: d * 30 - 20)),
            lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(30), unitPrice: 50000, priceListId: shop.priceListId)],
            paidAmount: 1500000,
          ),
          userId: shop.admin.id,
        );
      }
    });

    test('sales speed, lead time and safety days give the quantity; suppliers side by side', () async {
      final plan = PurchasePlanService(shop.db);
      await plan.setSafetyDays(5);
      final rows = await plan.build(onlyNeeded: false);
      final r = rows.firstWhere((r) => r.productId == shop.mixer.id);
      expect((r.stock, r.sold30, r.sold60, r.sold90), (qtyOf(10), qtyOf(30), qtyOf(60), qtyOf(90)));
      // Last bought from the first supplier: lead 10 + safety 5 = 15 days at one a day.
      expect(r.supplierId, shop.supplierId);
      expect(r.target, qtyOf(15));
      expect(r.suggested, qtyOf(5));
      // Both offers, cheapest first: 35% off 500.00 = 325.00, 30% off = 350.00.
      expect([for (final o in r.offers) (o.supplierName, o.netCost)], [('مورد ب', 32500), ('مورد', 35000)]);
      // Choosing the slower supplier asks for more.
      r.supplierId = supplierB;
      expect(r.suggested, qtyOf(15));
    });

    test('the plan is saved as one draft purchase order per supplier', () async {
      final plan = PurchasePlanService(shop.db);
      final rows = await plan.build(onlyNeeded: false);
      final r = rows.firstWhere((r) => r.productId == shop.mixer.id);
      r.supplierId = supplierB;
      r.qty = qtyOf(12);
      final ids = await plan.saveDrafts(rows.where((x) => x.productId == shop.mixer.id).toList(), user: shop.admin);
      final order = await (shop.db.select(shop.db.purchaseOrders)..where((o) => o.id.equals(ids.single))).getSingle();
      expect((order.supplierId, order.status), (supplierB, 'draft'));
      final line = await (shop.db.select(shop.db.purchaseOrderLines)..where((l) => l.orderId.equals(order.id))).getSingle();
      expect(line.qty, qtyOf(12));
      // On order now, so nothing more is suggested for it.
      final again = (await plan.build(onlyNeeded: false)).firstWhere((x) => x.productId == shop.mixer.id);
      expect(again.onOrder, 0, reason: 'a draft is not yet an order');
    });
  });

  test('reservation states: active, expired, used, released and cancelled', () async {
    await buy(5, 30000);
    final orders = SalesOrderService(shop.db);
    final id = await orders.createDraft(
      customerId: shop.customerId,
      lines: [SoLineInput(productId: shop.mixer.id, qty: qtyOf(2))],
      user: shop.admin,
    );
    await orders.confirm(id, user: shop.admin);
    var r = await shop.db.select(shop.db.reservations).getSingle();
    expect(ReservationStatus.label(r), 'نشط');
    expect(ReservationStatus.label(r.copyWith(expiresAt: Value(DateTime(2000)))), 'منتهي');
    await orders.cancel(id, user: shop.admin);
    r = await shop.db.select(shop.db.reservations).getSingle();
    expect((r.status, ReservationStatus.label(r)), (ReservationStatus.cancelled, 'ملغي'));
  });

  test('timed backups are kept apart from the others', () async {
    final dir = await Directory.systemTemp.createTemp('erp_timed');
    addTearDown(() => dir.delete(recursive: true));
    final backups = BackupService(dir: dir, keep: 3);
    for (var i = 0; i < 3; i++) {
      await backups.backup(shop.db, reason: BackupReason.manual);
    }
    for (var i = 0; i < 5; i++) {
      await backups.backup(shop.db, reason: BackupReason.scheduled);
    }
    final all = await backups.list();
    expect(all.where((b) => b.reason == BackupReason.manual).length, 3);
    expect(all.where((b) => b.reason == BackupReason.scheduled).length, 3);
  });

  test('a schema 18 file gets the new columns and tables and keeps its data', () async {
    final dir = await Directory.systemTemp.createTemp('erp_v19');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/shop.db');
    var db = AppDatabase(NativeDatabase(file));
    await db.select(db.users).get();
    await db.customStatement("INSERT INTO customers (id, name) VALUES (1, 'عميل قديم')");
    await db.customStatement('DROP TABLE customer_contacts');
    await db.customStatement('DROP TABLE expense_attachments');
    for (final (table, column) in [
      ('customers', 'email'),
      ('customers', 'tax_number'),
      ('customers', 'payment_terms_days'),
      ('suppliers', 'email'),
      ('suppliers', 'tax_number'),
      ('suppliers', 'lead_time_days'),
      ('sales_invoices', 'due_date'),
      ('expenses', 'payee'),
      ('expenses', 'vat_amount'),
      ('expenses', 'doc_number'),
    ]) {
      await db.customStatement('ALTER TABLE $table DROP COLUMN $column');
    }
    await db.customStatement('PRAGMA user_version = 18');
    await db.close();

    db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);
    final c = await db.select(db.customers).getSingle();
    expect((c.name, c.paymentTermsDays, c.email), ('عميل قديم', 0, null));
    expect(await db.select(db.customerContacts).get(), isEmpty);
    expect(await db.integrityOk(), isTrue);
    final v = await db.customSelect('PRAGMA user_version').getSingle();
    expect(v.data.values.first, AppDatabase.latestSchemaVersion);
  });
}
