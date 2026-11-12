import 'package:drift/drift.dart';

import '../auth/auth_service.dart';
import '../db/database.dart';
import '../pricing_math.dart';
import '../quantity.dart';
import 'audit_service.dart';
import 'balance_service.dart';
import 'doc_types.dart';
import 'errors.dart';
import 'numbering_service.dart';
import 'purchase_order_service.dart';
import 'sales_order_service.dart';
import 'stock_service.dart';

abstract final class ProjectStatus {
  static const lead = 'lead';
  static const active = 'active';
  static const onHold = 'on_hold';
  static const done = 'done';
  static const cancelled = 'cancelled';
  static const all = [lead, active, onHold, done, cancelled];

  static String label(String s) => switch (s) {
        lead => 'فرصة / عرض سعر',
        active => 'جاري التوريد',
        onHold => 'متوقف',
        done => 'منتهي',
        _ => 'ملغى',
      };
}

class ProjectInput {
  const ProjectInput({
    required this.name,
    this.customerId,
    this.location,
    this.contactName,
    this.contactPhone,
    this.startDate,
    this.endDate,
    this.status = ProjectStatus.active,
    this.contractValue = 0,
    this.paymentTerms,
    this.notes,
  });

  final String name;
  final int? customerId;
  final String? location;
  final String? contactName;
  final String? contactPhone;
  final DateTime? startDate;
  final DateTime? endDate;
  final String status;
  final int contractValue;
  final String? paymentTerms;
  final String? notes;
}

/// A project's money: what was invoiced and collected, what it cost, and
/// what it earned. Revenue is without VAT where the VAT is verified; cost is
/// the exact FIFO cost of what was delivered, plus the project's expenses.
class ProjectMoney {
  const ProjectMoney({
    required this.invoiced,
    required this.returned,
    required this.collected,
    required this.revenue,
    required this.goodsCost,
    required this.expenses,
    required this.purchases,
    required this.ordered,
  });

  /// Invoices, with VAT.
  final int invoiced;
  final int returned;
  final int collected;

  /// Invoices less returns, without VAT.
  final int revenue;
  final int goodsCost;
  final int expenses;

  /// Bought for the project (goes to stock first; its cost counts when sold).
  final int purchases;

  /// Open sales orders not yet invoiced, at order prices.
  final int ordered;

  int get grossProfit => revenue - goodsCost;
  int get netProfit => grossProfit - expenses;
  int get open => invoiced - returned - collected;
  int? get marginBp => revenue == 0 ? null : marginBpOf(netProfit, revenue);
}

int marginBpOf(int profit, int revenue) => (profit * 10000 / revenue).round();

class ProjectRow {
  const ProjectRow(this.project, this.customerName, this.money, this.boqLines, this.boqDoneBp);

  final Project project;
  final String? customerName;
  final ProjectMoney money;
  final int boqLines;

  /// How much of the bill of quantities was delivered, by quantity.
  final int? boqDoneBp;
}

/// One line of the bill of quantities, with how far it got.
class BoqProgress {
  const BoqProgress({
    required this.line,
    this.productCode,
    this.productName,
    this.supplierName,
    required this.quoted,
    required this.ordered,
    required this.purchased,
    required this.delivered,
    required this.inStock,
  });

  final ProjectBoqLine line;
  final String? productCode;
  final String? productName;
  final String? supplierName;

  /// In quotations for the project.
  final int quoted;

  /// In confirmed sales orders for the project.
  final int ordered;

  /// In purchase orders for the project.
  final int purchased;

  /// Invoiced to the project, less returns.
  final int delivered;
  final int inStock;

  int get remaining => line.qtyRequired - delivered;
  int get toBuy => (remaining - inStock - (purchased > delivered ? purchased - delivered : 0)).clamp(0, 1 << 50);
  int get doneBp => line.qtyRequired <= 0 ? 0 : (delivered * 10000 ~/ line.qtyRequired).clamp(0, 10000);
}

/// A document linked to a project, for its tabs.
class ProjectDoc {
  const ProjectDoc(this.refType, this.id, this.number, this.date, this.amount, this.status, {this.party});

  final String refType;
  final int id;
  final String number;
  final DateTime date;
  final int amount;
  final String status;
  final String? party;
}

/// Projects (sites, contractors, compounds): what they need, what was
/// quoted, ordered, delivered and collected, and what each one earned.
class ProjectService {
  ProjectService(this.db);

  final AppDatabase db;

  void _admin(User user) {
    if (!user.isAdmin) throw ValidationException('المشروعات للمدير فقط');
  }

  String? _blank(String? s) => (s ?? '').trim().isEmpty ? null : s!.trim();

  Future<int> save(ProjectInput input, {int? id, required User user}) {
    return db.transaction(() async {
      _admin(user);
      if (input.name.trim().isEmpty) throw ValidationException('اكتب اسم المشروع');
      if (!ProjectStatus.all.contains(input.status)) throw ArgumentError.value(input.status, 'status');
      if (input.contractValue < 0) throw ValidationException('قيمة التعاقد لا تكون سالبة');
      if (input.startDate != null && input.endDate != null && input.endDate!.isBefore(input.startDate!)) {
        throw ValidationException('تاريخ الانتهاء قبل تاريخ البدء');
      }
      final companion = ProjectsCompanion(
        name: Value(input.name.trim()),
        customerId: Value(input.customerId),
        location: Value(_blank(input.location)),
        contactName: Value(_blank(input.contactName)),
        contactPhone: Value(_blank(input.contactPhone)),
        startDate: Value(input.startDate),
        endDate: Value(input.endDate),
        status: Value(input.status),
        contractValue: Value(input.contractValue),
        paymentTerms: Value(_blank(input.paymentTerms)),
        notes: Value(_blank(input.notes)),
        updatedAt: Value(DateTime.now()),
      );
      if (id == null) {
        final newId = await db.into(db.projects).insert(companion.copyWith(code: Value(await NumberingService(db).next('project'))));
        await AuditService(db).log(action: AuditAction.create, entity: 'project', entityId: newId, userId: user.id, details: input.name.trim());
        return newId;
      }
      await (db.update(db.projects)..where((p) => p.id.equals(id))).write(companion);
      await AuditService(db).log(action: AuditAction.update, entity: 'project', entityId: id, userId: user.id, details: input.name.trim());
      return id;
    });
  }

  Future<Project> get(int id) => (db.select(db.projects)..where((p) => p.id.equals(id))).getSingle();

  /// Projects open for new documents (for the pickers on the forms).
  Future<List<Project>> open({int? customerId}) => (db.select(db.projects)
        ..where((p) {
          Expression<bool> w = p.status.isIn([ProjectStatus.lead, ProjectStatus.active, ProjectStatus.onHold]);
          if (customerId != null) w = w & (p.customerId.equals(customerId) | p.customerId.isNull());
          return w;
        })
        ..orderBy([(p) => OrderingTerm.desc(p.id)]))
      .get();

  Stream<List<Project>> watchAll() => (db.select(db.projects)..orderBy([(p) => OrderingTerm.desc(p.id)])).watch();

  /// Links a document to a project (or unlinks it with null). Its ledger
  /// entry follows.
  Future<void> assign(String refType, int id, int? projectId, {required User user}) async {
    _admin(user);
    final table = switch (refType) {
      RefType.salesInvoice => 'sales_invoices',
      RefType.purchaseInvoice => 'purchase_invoices',
      RefType.salesOrder => 'sales_orders',
      RefType.purchaseOrder => 'purchase_orders',
      'expense' => 'expenses',
      _ => throw ArgumentError.value(refType, 'refType'),
    };
    await db.customUpdate('UPDATE $table SET project_id = ? WHERE id = ?',
        variables: [Variable<int>(projectId), Variable.withInt(id)], updates: {
      switch (refType) {
        RefType.salesInvoice => db.salesInvoices,
        RefType.purchaseInvoice => db.purchaseInvoices,
        RefType.salesOrder => db.salesOrders,
        RefType.purchaseOrder => db.purchaseOrders,
        _ => db.expenses,
      },
    });
    await AuditService(db).log(
        action: AuditAction.update, entity: refType, entityId: id, userId: user.id, details: 'المشروع: ${projectId ?? 'بدون'}');
  }

  // ---------------------------------------------------------------- money

  Future<ProjectMoney> money(int projectId) async {
    final invoices = await (db.select(db.salesInvoices)
          ..where((s) => s.projectId.equals(projectId) & s.status.equals(DocStatus.active)))
        .get();
    final ids = invoices.map((i) => i.id).toList();
    final items = ids.isEmpty
        ? const <SalesInvoiceItem>[]
        : await (db.select(db.salesInvoiceItems)..where((i) => i.invoiceId.isIn(ids))).get();
    final vat = items.where((i) => i.vatStatus == VatStatus.inclusive).fold(0, (s, i) => s + (i.vatAmount ?? 0));
    final balances = BalanceService(db);
    var collected = 0;
    for (final i in invoices) {
      collected += await balances.paidOnInvoice(RefType.salesInvoice, i.id);
    }
    var returned = 0, returnedNet = 0, returnCost = 0;
    if (ids.isNotEmpty) {
      final rets = await (db.select(db.returns)
            ..where((r) => r.kind.equals(ReturnKind.sale) & r.status.equals(DocStatus.active) & r.originalInvoiceId.isIn(ids)))
          .get();
      for (final r in rets) {
        returned += r.total;
        final inv = invoices.firstWhere((i) => i.id == r.originalInvoiceId);
        final invItems = items.where((i) => i.invoiceId == inv.id);
        final invVat = invItems.where((i) => i.vatStatus == VatStatus.inclusive).fold(0, (s, i) => s + (i.vatAmount ?? 0));
        // The returned part's VAT in the invoice's own proportion.
        returnedNet += inv.total == 0 ? r.total : r.total - (r.total * invVat / inv.total).round();
        final moves = await (db.select(db.stockMovements)
              ..where((m) =>
                  m.refType.equals(RefType.returnDoc) & m.refId.equals(r.id) & m.type.equals(StockMovementType.saleReturn)))
            .get();
        returnCost += moves.fold(0, (s, m) => s + lineAmount(m.qty, m.unitCost));
      }
    }
    final expenses = await (db.select(db.expenses)
          ..where((e) => e.projectId.equals(projectId) & e.status.equals(DocStatus.active) & e.purchaseInvoiceId.isNull()))
        .get();
    final purchases = await (db.select(db.purchaseInvoices)
          ..where((p) => p.projectId.equals(projectId) & p.status.equals(DocStatus.active)))
        .get();
    final orders = await _orderLines(projectId, confirmedOnly: true);
    final ordered = orders.fold(0, (s, l) => s + lineAmount(l.qty - l.qtyDelivered, l.unitPrice));
    final invoiced = invoices.fold(0, (s, i) => s + i.total);
    return ProjectMoney(
      invoiced: invoiced,
      returned: returned,
      collected: collected,
      revenue: invoiced - vat - returnedNet,
      goodsCost: items.fold(0, (s, i) => s + i.costTotal) - returnCost,
      expenses: expenses.fold(0, (s, e) => s + e.amount),
      purchases: purchases.fold(0, (s, p) => s + p.total),
      ordered: ordered < 0 ? 0 : ordered,
    );
  }

  Future<List<SalesOrderLine>> _orderLines(int projectId, {bool confirmedOnly = false, bool quotesOnly = false}) async {
    final orders = await (db.select(db.salesOrders)..where((o) => o.projectId.equals(projectId))).get();
    final ids = [
      for (final o in orders)
        if (quotesOnly
            ? o.status == SoStatus.quotation
            : (o.status != SoStatus.cancelled && o.status != SoStatus.quotation && (!confirmedOnly || o.status != SoStatus.draft)))
          o.id,
    ];
    if (ids.isEmpty) return const [];
    return (db.select(db.salesOrderLines)..where((l) => l.orderId.isIn(ids))).get();
  }

  Future<List<ProjectRow>> list() async {
    final projects = await (db.select(db.projects)..orderBy([(p) => OrderingTerm.desc(p.id)])).get();
    final customers = {for (final c in await db.select(db.customers).get()) c.id: c.name};
    final out = <ProjectRow>[];
    for (final p in projects) {
      final boq = await boqProgress(p.id);
      final req = boq.fold(0, (s, b) => s + b.line.qtyRequired);
      final del = boq.fold(0, (s, b) => s + (b.delivered < b.line.qtyRequired ? b.delivered : b.line.qtyRequired));
      out.add(ProjectRow(p, customers[p.customerId], await money(p.id), boq.length, req == 0 ? null : del * 10000 ~/ req));
    }
    return out;
  }

  // ------------------------------------------------------------------ BOQ

  Future<int> saveBoqLine({
    int? id,
    required int projectId,
    int? productId,
    String? description,
    required int qtyRequired,
    int? preferredSupplierId,
    DateTime? neededBy,
    String? notes,
    required User user,
  }) async {
    _admin(user);
    if (qtyRequired <= 0) throw ValidationException('الكمية المطلوبة يجب أن تكون أكبر من صفر');
    var text = _blank(description);
    if (productId != null) {
      final p = await (db.select(db.products)..where((t) => t.id.equals(productId))).getSingle();
      text ??= p.nameAr;
    }
    if (text == null) throw ValidationException('اختر صنفاً أو اكتب وصف البند');
    final c = ProjectBoqLinesCompanion(
      projectId: Value(projectId),
      productId: Value(productId),
      description: Value(text),
      qtyRequired: Value(qtyRequired),
      preferredSupplierId: Value(preferredSupplierId),
      neededBy: Value(neededBy),
      notes: Value(_blank(notes)),
      updatedAt: Value(DateTime.now()),
    );
    if (id == null) return db.into(db.projectBoqLines).insert(c);
    await (db.update(db.projectBoqLines)..where((l) => l.id.equals(id))).write(c);
    return id;
  }

  Future<void> deleteBoqLine(int id, {required User user}) async {
    _admin(user);
    await (db.delete(db.projectBoqLines)..where((l) => l.id.equals(id))).go();
  }

  /// Fills the bill of quantities from one of the project's sales orders or
  /// quotations (adds what is not there yet, raises what is less).
  Future<int> boqFromOrder(int projectId, int salesOrderId, {required User user}) {
    return db.transaction(() async {
      _admin(user);
      final lines = await (db.select(db.salesOrderLines)..where((l) => l.orderId.equals(salesOrderId))).get();
      final have = await (db.select(db.projectBoqLines)..where((l) => l.projectId.equals(projectId))).get();
      var n = 0;
      for (final l in lines) {
        final same = have.where((h) => h.productId == l.productId).firstOrNull;
        if (same == null) {
          await saveBoqLine(projectId: projectId, productId: l.productId, qtyRequired: l.qty, user: user);
          n++;
        } else if (same.qtyRequired < l.qty) {
          await (db.update(db.projectBoqLines)..where((x) => x.id.equals(same.id)))
              .write(ProjectBoqLinesCompanion(qtyRequired: Value(l.qty), updatedAt: Value(DateTime.now())));
          n++;
        }
      }
      return n;
    });
  }

  Future<List<BoqProgress>> boqProgress(int projectId) async {
    final lines = await (db.select(db.projectBoqLines)
          ..where((l) => l.projectId.equals(projectId))
          ..orderBy([(l) => OrderingTerm.asc(l.id)]))
        .get();
    if (lines.isEmpty) return const [];
    final products = {for (final p in await db.select(db.products).get()) p.id: p};
    final suppliers = {for (final s in await db.select(db.suppliers).get()) s.id: s.name};
    Map<int, int> sum(Iterable<(int, int)> rows) {
      final m = <int, int>{};
      for (final (p, q) in rows) {
        m[p] = (m[p] ?? 0) + q;
      }
      return m;
    }

    final quoted = sum((await _orderLines(projectId, quotesOnly: true)).map((l) => (l.productId, l.qty)));
    final ordered = sum((await _orderLines(projectId)).map((l) => (l.productId, l.qty)));
    final pos = await (db.select(db.purchaseOrders)
          ..where((o) => o.projectId.equals(projectId) & o.status.isNotValue(PoStatus.cancelled)))
        .get();
    final purchased = pos.isEmpty
        ? <int, int>{}
        : sum((await (db.select(db.purchaseOrderLines)..where((l) => l.orderId.isIn(pos.map((o) => o.id)))).get())
            .map((l) => (l.productId, l.qty)));
    final invoices = await (db.select(db.salesInvoices)
          ..where((s) => s.projectId.equals(projectId) & s.status.equals(DocStatus.active)))
        .get();
    final invIds = invoices.map((i) => i.id).toList();
    final delivered = invIds.isEmpty
        ? <int, int>{}
        : sum((await (db.select(db.salesInvoiceItems)..where((i) => i.invoiceId.isIn(invIds))).get())
            .map((i) => (i.productId, i.qty)));
    if (invIds.isNotEmpty) {
      final rets = await (db.select(db.returns)
            ..where((r) => r.kind.equals(ReturnKind.sale) & r.status.equals(DocStatus.active) & r.originalInvoiceId.isIn(invIds)))
          .get();
      if (rets.isNotEmpty) {
        for (final it in await (db.select(db.returnItems)..where((i) => i.returnId.isIn(rets.map((r) => r.id)))).get()) {
          delivered[it.productId] = (delivered[it.productId] ?? 0) - it.qty;
        }
      }
    }
    final stock = StockService(db);
    return [
      for (final l in lines)
        BoqProgress(
          line: l,
          productCode: products[l.productId]?.code,
          productName: products[l.productId]?.nameAr,
          supplierName: suppliers[l.preferredSupplierId],
          quoted: quoted[l.productId] ?? 0,
          ordered: ordered[l.productId] ?? 0,
          purchased: purchased[l.productId] ?? 0,
          delivered: delivered[l.productId] ?? 0,
          inStock: l.productId == null ? 0 : await stock.currentStock(l.productId!),
        ),
    ];
  }

  /// A quotation for what is left of the bill of quantities, priced by the
  /// usual price lists and the customer's discounts.
  Future<int> quoteRemaining(int projectId, {required User user}) async {
    _admin(user);
    final p = await get(projectId);
    if (p.customerId == null) throw ValidationException('حدد عميل المشروع أولاً');
    final lines = [
      for (final b in await boqProgress(projectId))
        if (b.line.productId != null && b.remaining > 0) SoLineInput(productId: b.line.productId!, qty: b.remaining),
    ];
    if (lines.isEmpty) throw ValidationException('لا توجد بنود متبقية مرتبطة بأصناف');
    return SalesOrderService(db).createDraft(
      customerId: p.customerId!,
      lines: lines,
      asQuotation: true,
      notes: 'عرض سعر لمشروع ${p.name}',
      projectId: projectId,
      user: user,
    );
  }

  /// Purchase orders for what the project still needs beyond the stock on
  /// hand, one per preferred supplier. Lines with no supplier are skipped.
  Future<List<int>> orderShortages(int projectId, {required User user}) async {
    _admin(user);
    final p = await get(projectId);
    final bySupplier = <int, List<PoLineInput>>{};
    for (final b in await boqProgress(projectId)) {
      if (b.line.productId == null || b.line.preferredSupplierId == null || b.toBuy <= 0) continue;
      (bySupplier[b.line.preferredSupplierId!] ??= []).add(PoLineInput(productId: b.line.productId!, qty: b.toBuy));
    }
    if (bySupplier.isEmpty) {
      throw ValidationException('لا يوجد نقص يحتاج أمر شراء (أو لم يُحدد مورد مفضل للبنود الناقصة)');
    }
    final ids = <int>[];
    for (final e in bySupplier.entries) {
      ids.add(await PurchaseOrderService(db).createDraft(
        supplierId: e.key,
        lines: e.value,
        notes: 'لمشروع ${p.name}',
        projectId: projectId,
        user: user,
      ));
    }
    return ids;
  }

  // ------------------------------------------------------------- documents

  Future<List<ProjectDoc>> documents(int projectId) async {
    final customers = {for (final c in await db.select(db.customers).get()) c.id: c.name};
    final suppliers = {for (final s in await db.select(db.suppliers).get()) s.id: s.name};
    final out = <ProjectDoc>[];
    for (final o in await (db.select(db.salesOrders)..where((x) => x.projectId.equals(projectId))).get()) {
      final lines = await (db.select(db.salesOrderLines)..where((l) => l.orderId.equals(o.id))).get();
      out.add(ProjectDoc(RefType.salesOrder, o.id, o.number, o.orderDate,
          lines.fold(0, (s, l) => s + lineAmount(l.qty, l.unitPrice)), o.status, party: customers[o.customerId]));
    }
    for (final i in await (db.select(db.salesInvoices)..where((x) => x.projectId.equals(projectId))).get()) {
      out.add(ProjectDoc(RefType.salesInvoice, i.id, i.number, i.date, i.total, i.status, party: customers[i.customerId]));
    }
    for (final o in await (db.select(db.purchaseOrders)..where((x) => x.projectId.equals(projectId))).get()) {
      final lines = await (db.select(db.purchaseOrderLines)..where((l) => l.orderId.equals(o.id))).get();
      out.add(ProjectDoc(RefType.purchaseOrder, o.id, o.number, o.orderDate,
          lines.fold(0, (s, l) => s + lineAmount(l.qty, l.unitCost)), o.status, party: suppliers[o.supplierId]));
    }
    for (final i in await (db.select(db.purchaseInvoices)..where((x) => x.projectId.equals(projectId))).get()) {
      out.add(ProjectDoc(RefType.purchaseInvoice, i.id, i.number, i.date, i.total, i.status, party: suppliers[i.supplierId]));
    }
    final cats = {for (final c in await db.select(db.expenseCategories).get()) c.id: c.nameAr};
    for (final e in await (db.select(db.expenses)..where((x) => x.projectId.equals(projectId))).get()) {
      out.add(ProjectDoc('expense', e.id, 'EX-${e.id}', e.date, e.amount, e.status, party: e.description ?? cats[e.categoryId]));
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }

  /// The customer's documents not linked to any project, to link them.
  Future<List<ProjectDoc>> unlinked(int customerId) async {
    final out = <ProjectDoc>[];
    for (final o in await (db.select(db.salesOrders)
          ..where((x) => x.customerId.equals(customerId) & x.projectId.isNull() & x.status.isNotValue(SoStatus.cancelled)))
        .get()) {
      out.add(ProjectDoc(RefType.salesOrder, o.id, o.number, o.orderDate, 0, o.status));
    }
    for (final i in await (db.select(db.salesInvoices)
          ..where((x) => x.customerId.equals(customerId) & x.projectId.isNull() & x.status.equals(DocStatus.active)))
        .get()) {
      out.add(ProjectDoc(RefType.salesInvoice, i.id, i.number, i.date, i.total, i.status));
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
  }
}
