import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/quantity.dart';
import 'package:sanitaryware_erp/core/services/errors.dart';
import 'package:sanitaryware_erp/core/services/expense_service.dart';
import 'package:sanitaryware_erp/core/services/ledger_service.dart';
import 'package:sanitaryware_erp/core/services/payment_service.dart';
import 'package:sanitaryware_erp/core/services/project_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_order_service.dart';
import 'package:sanitaryware_erp/core/services/purchase_service.dart';
import 'package:sanitaryware_erp/core/services/sales_order_service.dart';
import 'package:sanitaryware_erp/core/services/sales_service.dart';

import '../support/fixture.dart';

void main() {
  late Shop shop;
  late ProjectService projects;
  late int projectId;

  setUp(() async {
    shop = await Shop.open();
    projects = ProjectService(shop.db);
    await PurchaseService(shop.db).post(
      PurchaseInput(
        supplierId: shop.supplierId,
        lines: [PurchaseLineInput(productId: shop.mixer.id, qty: qtyOf(5), unitCost: 30000)],
      ),
      user: shop.admin,
    );
    projectId = await projects.save(
      ProjectInput(name: 'كمبوند النخيل', customerId: shop.customerId, contractValue: 1000000),
      user: shop.admin,
    );
  });
  tearDown(() => shop.close());

  test('a project gets a code; only the admin manages projects', () async {
    final p = await projects.get(projectId);
    expect(p.code, startsWith('PRJ-'));
    await expectLater(
      projects.save(const ProjectInput(name: 'x'), user: shop.cashier),
      throwsA(isA<ValidationException>()),
    );
  });

  test('BOQ progress, quotation for the rest, and purchase orders for shortages', () async {
    await projects.saveBoqLine(
      projectId: projectId,
      productId: shop.mixer.id,
      qtyRequired: qtyOf(12),
      preferredSupplierId: shop.supplierId,
      user: shop.admin,
    );
    // Deliver 3 on an invoice for the project.
    await SalesService(shop.db).post(
      SaleInput(
        customerId: shop.customerId,
        projectId: projectId,
        lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(3), unitPrice: 50000, priceListId: shop.priceListId)],
      ),
      userId: shop.cashier.id,
    );
    var b = (await projects.boqProgress(projectId)).single;
    expect(b.delivered, qtyOf(3));
    expect(b.remaining, qtyOf(9));
    expect(b.inStock, qtyOf(2));
    expect(b.toBuy, qtyOf(7));

    final quoteId = await projects.quoteRemaining(projectId, user: shop.admin);
    final quote = await SalesOrderService(shop.db).detail(quoteId);
    expect(quote.order.projectId, projectId);
    expect(quote.order.status, SoStatus.quotation);
    expect(quote.lines.single.line.qty, qtyOf(9));

    final poIds = await projects.orderShortages(projectId, user: shop.admin);
    final po = await PurchaseOrderService(shop.db).detail(poIds.single);
    expect(po.order.projectId, projectId);
    expect(po.lines.single.line.qty, qtyOf(7));
    b = (await projects.boqProgress(projectId)).single;
    expect(b.quoted, qtyOf(9));
    expect(b.purchased, qtyOf(7));
  });

  test('profitability: revenue, exact cost, project expenses, collections', () async {
    final inv = await SalesService(shop.db).post(
      SaleInput(
        customerId: shop.customerId,
        projectId: projectId,
        lines: [SaleLineInput(productId: shop.mixer.id, qty: qtyOf(2), unitPrice: 50000, priceListId: shop.priceListId)],
        paidAmount: 40000,
      ),
      userId: shop.cashier.id,
    );
    await PaymentService(shop.db).receive(PaymentInput(partyId: shop.customerId, amount: 30000, invoiceId: inv.id));
    final cat = (await shop.db.select(shop.db.expenseCategories).get()).first;
    await ExpenseService(shop.db)
        .add(ExpenseInput(categoryId: cat.id, amount: 5000, projectId: projectId), user: shop.admin);
    final m = await projects.money(projectId);
    expect(m.invoiced, 100000);
    expect(m.revenue, 100000);
    expect(m.goodsCost, 60000);
    expect(m.expenses, 5000);
    expect(m.netProfit, 35000);
    expect(m.collected, 70000);
    expect(m.open, 30000);
    // The ledger lines carry the project too.
    await LedgerService(shop.db).catchUp();
    final tagged = await (shop.db.select(shop.db.journalLines)..where((l) => l.projectId.equals(projectId))).get();
    expect(tagged, isNotEmpty);
  });

  test('an invoice delivered from a project order belongs to the project', () async {
    final orders = SalesOrderService(shop.db);
    final id = await orders.createDraft(
      customerId: shop.customerId,
      lines: [SoLineInput(productId: shop.mixer.id, qty: qtyOf(2))],
      projectId: projectId,
      user: shop.admin,
    );
    await orders.confirm(id, user: shop.admin);
    final lineId = (await orders.detail(id)).lines.single.line.id;
    final inv = await orders.deliver(id, qtyByLine: {lineId: qtyOf(2)}, user: shop.cashier);
    final saved = await (shop.db.select(shop.db.salesInvoices)..where((s) => s.id.equals(inv.id))).getSingle();
    expect(saved.projectId, projectId);
    final rows = await projects.list();
    expect(rows.single.money.invoiced, saved.total);
  });
}
