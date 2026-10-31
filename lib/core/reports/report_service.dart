import 'package:drift/drift.dart';

import '../db/database.dart';
import '../quantity.dart';
import '../services/balance_service.dart';
import '../services/doc_types.dart';
import '../services/query_helpers.dart';
import '../services/settings_service.dart';
import '../services/stock_service.dart';
import 'report_table.dart';

enum ReportKind {
  dailySales('المبيعات اليومية', dated: true),
  salesByCustomer('المبيعات حسب العميل', dated: true),
  salesByProduct('المبيعات حسب الصنف', dated: true),
  profit('الأرباح', dated: true),
  expensesByCategory('المصروفات حسب البند', dated: true),
  chequesDue('الشيكات المستحقة', dated: true),
  stockLevels('أرصدة المخزن', byCategory: true),
  lowStock('الأصناف تحت حد الطلب'),
  stockValuation('تقييم المخزون', byCategory: true),
  customersOwing('مديونيات العملاء'),
  supplierBalances('أرصدة الموردين');

  const ReportKind(this.title, {this.dated = false, this.byCategory = false});

  final String title;

  /// Takes a date range (otherwise it is "as of now").
  final bool dated;

  /// Can be limited to one product category.
  final bool byCategory;
}

/// The numbers on the dashboard.
class DashboardSummary {
  const DashboardSummary({
    required this.todaySales,
    required this.todayInvoices,
    required this.todayReceived,
    required this.lowStockCount,
    required this.chequesInDue,
    required this.chequesInDueTotal,
    required this.chequesOutDue,
    required this.chequesOutDueTotal,
    required this.topDebtors,
  });

  final int todaySales;
  final int todayInvoices;

  /// Counted money received today (sales at the counter and payments).
  final int todayReceived;
  final int lowStockCount;

  /// Pending cheques due within the next 7 days (or overdue).
  final int chequesInDue;
  final int chequesInDueTotal;
  final int chequesOutDue;
  final int chequesOutDueTotal;

  /// Up to five customers owing the most.
  final List<(String name, int balance)> topDebtors;
}

/// Every report in the plan, each returning a [ReportTable].
/// Cancelled documents never count. Ranges are whole days, inclusive.
class ReportService {
  ReportService(this.db);

  final AppDatabase db;

  Future<ReportTable> build(ReportKind kind, {DateTime? from, DateTime? to, int? categoryId}) {
    return switch (kind) {
      ReportKind.dailySales => dailySales(from: from, to: to),
      ReportKind.salesByCustomer => salesByCustomer(from: from, to: to),
      ReportKind.salesByProduct => salesByProduct(from: from, to: to),
      ReportKind.profit => profit(from: from, to: to),
      ReportKind.expensesByCategory => expensesByCategory(from: from, to: to),
      ReportKind.chequesDue => chequesDue(from: from, to: to),
      ReportKind.stockLevels => stockLevels(categoryId: categoryId),
      ReportKind.lowStock => lowStock(),
      ReportKind.stockValuation => stockValuation(categoryId: categoryId),
      ReportKind.customersOwing => customersOwing(),
      ReportKind.supplierBalances => supplierBalances(),
    };
  }

  Future<DashboardSummary> dashboard({DateTime? now}) async {
    final today = _day(now ?? DateTime.now());
    final sales = await _sales(today, today);
    final pending = await SettingsService(db).getBool(SettingKey.countPendingCheques);
    final received = await db.customSelect(
      'SELECT COALESCE(SUM(p.amount), 0) AS total FROM payments p '
      "WHERE p.direction = '${PaymentDirection.inbound}' AND p.party_type = '${PartyType.customer}' "
      'AND ${BalanceService.countedPayment('p')} AND p.date >= ? AND p.date < ?',
      variables: [
        Variable.withBool(pending),
        Variable.withDateTime(today),
        Variable.withDateTime(today.add(const Duration(days: 1))),
      ],
    ).getSingle();
    final cheques = (await chequesDue(to: today.add(const Duration(days: 7)))).rows;
    final incoming = cheques.where((r) => r[4] == 'وارد');
    final outgoing = cheques.where((r) => r[4] == 'صادر');
    final debtors = (await customersOwing()).rows.take(5);
    return DashboardSummary(
      todaySales: sales.fold(0, (s, i) => s + i.total),
      todayInvoices: sales.length,
      todayReceived: received.read<int>('total'),
      lowStockCount: (await lowStock()).rows.length,
      chequesInDue: incoming.length,
      chequesInDueTotal: incoming.fold(0, (s, r) => s + (r[5] as int)),
      chequesOutDue: outgoing.length,
      chequesOutDueTotal: outgoing.fold(0, (s, r) => s + (r[5] as int)),
      topDebtors: [for (final r in debtors) (r[0] as String, r[2] as int)],
    );
  }

  // ---------------------------------------------------------------- sales

  Future<ReportTable> dailySales({DateTime? from, DateTime? to}) async {
    final byDay = <DateTime, List<int>>{}; // [count, sales, returns]
    for (final s in await _sales(from, to)) {
      final d = _day(s.date);
      final v = byDay.putIfAbsent(d, () => [0, 0, 0]);
      v[0]++;
      v[1] += s.total;
    }
    for (final r in await _returns(ReturnKind.sale, from, to)) {
      byDay.putIfAbsent(_day(r.date), () => [0, 0, 0])[2] += r.total;
    }
    final days = byDay.keys.toList()..sort();
    return ReportTable(
      title: ReportKind.dailySales.title,
      columns: const [
        ReportColumn('التاريخ', ColumnType.date),
        ReportColumn('عدد الفواتير', ColumnType.count, sum: true),
        ReportColumn('المبيعات', ColumnType.money, sum: true),
        ReportColumn('المرتجعات', ColumnType.money, sum: true),
        ReportColumn('الصافي', ColumnType.money, sum: true),
      ],
      rows: [
        for (final d in days)
          [d, byDay[d]![0], byDay[d]![1], byDay[d]![2], byDay[d]![1] - byDay[d]![2]],
      ],
    );
  }

  Future<ReportTable> salesByCustomer({DateTime? from, DateTime? to}) async {
    final names = {for (final c in await db.select(db.customers).get()) c.id: c.name};
    final rows = <int?, List<int>>{}; // customer id (null = cash) -> [count, sales, returns]
    for (final s in await _sales(from, to)) {
      final v = rows.putIfAbsent(s.customerId, () => [0, 0, 0]);
      v[0]++;
      v[1] += s.total;
    }
    for (final r in await _returns(ReturnKind.sale, from, to)) {
      rows.putIfAbsent(r.partyId, () => [0, 0, 0])[2] += r.total;
    }
    final list = [
      for (final e in rows.entries)
        [e.key == null ? 'نقدي' : names[e.key] ?? '', e.value[0], e.value[1], e.value[2], e.value[1] - e.value[2]],
    ]..sort((a, b) => (b[4] as int).compareTo(a[4] as int));
    return ReportTable(
      title: ReportKind.salesByCustomer.title,
      columns: const [
        ReportColumn('العميل', ColumnType.text),
        ReportColumn('عدد الفواتير', ColumnType.count, sum: true),
        ReportColumn('المبيعات', ColumnType.money, sum: true),
        ReportColumn('المرتجعات', ColumnType.money, sum: true),
        ReportColumn('الصافي', ColumnType.money, sum: true),
      ],
      rows: list,
    );
  }

  Future<ReportTable> salesByProduct({DateTime? from, DateTime? to}) async {
    final invoiceIds = {for (final s in await _sales(from, to)) s.id};
    final returnIds = {for (final r in await _returns(ReturnKind.sale, from, to)) r.id};
    final products = {for (final p in await db.select(db.products).get()) p.id: p};
    final v = <int, List<int>>{}; // product -> [qty, value, returnedQty, returnedValue]
    for (final i in await db.select(db.salesInvoiceItems).get()) {
      if (!invoiceIds.contains(i.invoiceId)) continue;
      final x = v.putIfAbsent(i.productId, () => [0, 0, 0, 0]);
      x[0] += i.qty;
      x[1] += i.lineTotal;
    }
    for (final i in await db.select(db.returnItems).get()) {
      if (!returnIds.contains(i.returnId)) continue;
      final x = v.putIfAbsent(i.productId, () => [0, 0, 0, 0]);
      x[2] += i.qty;
      x[3] += i.lineTotal;
    }
    final list = [
      for (final e in v.entries)
        [products[e.key]!.code, products[e.key]!.nameAr, e.value[0], e.value[1], e.value[2], e.value[3],
            e.value[1] - e.value[3]],
    ]..sort((a, b) => (b[6] as int).compareTo(a[6] as int));
    return ReportTable(
      title: ReportKind.salesByProduct.title,
      subtitle: 'القيم قبل خصم الفاتورة الإجمالي',
      columns: const [
        ReportColumn('الكود', ColumnType.text),
        ReportColumn('الصنف', ColumnType.text),
        ReportColumn('الكمية المباعة', ColumnType.qty),
        ReportColumn('قيمة المبيعات', ColumnType.money, sum: true),
        ReportColumn('الكمية المرتجعة', ColumnType.qty),
        ReportColumn('قيمة المرتجعات', ColumnType.money, sum: true),
        ReportColumn('الصافي', ColumnType.money, sum: true),
      ],
      rows: list,
    );
  }

  /// Sales after invoice discounts, minus returns, minus the cost of what
  /// was sold (as copied onto each invoice line), plus the cost of goods
  /// that came back, minus expenses.
  Future<ReportTable> profit({DateTime? from, DateTime? to}) async {
    final sales = await _sales(from, to);
    final salesTotal = sales.fold(0, (s, i) => s + i.total);
    final ids = {for (final s in sales) s.id};
    var cost = 0;
    for (final i in await db.select(db.salesInvoiceItems).get()) {
      if (ids.contains(i.invoiceId)) cost += lineAmount(i.qty, i.unitCost);
    }
    final returns = await _returns(ReturnKind.sale, from, to);
    final returnsTotal = returns.fold(0, (s, r) => s + r.total);
    final returnIds = {for (final r in returns) r.id};
    var returnedCost = 0;
    for (final m in await (db.select(db.stockMovements)
          ..where((t) => t.type.equals(StockMovementType.saleReturn) & t.refType.equals(RefType.returnDoc)))
        .get()) {
      if (returnIds.contains(m.refId)) returnedCost += lineAmount(m.qty, m.unitCost);
    }
    final expenses = (await _expenses(from, to)).fold(0, (s, e) => s + e.amount);
    final netSales = salesTotal - returnsTotal;
    final netCost = cost - returnedCost;
    final gross = netSales - netCost;
    return ReportTable(
      title: ReportKind.profit.title,
      columns: const [
        ReportColumn('البند', ColumnType.text),
        ReportColumn('المبلغ', ColumnType.money),
      ],
      rows: [
        ['المبيعات (بعد الخصم)', salesTotal],
        ['مرتجعات المبيعات', -returnsTotal],
        ['صافي المبيعات', netSales],
        ['تكلفة البضاعة المباعة', -cost],
        ['تكلفة البضاعة المرتجعة', returnedCost],
        ['صافي التكلفة', -netCost],
        ['مجمل الربح', gross],
        ['المصروفات', -expenses],
        ['صافي الربح', gross - expenses],
      ],
    );
  }

  // ------------------------------------------------------------- expenses

  Future<ReportTable> expensesByCategory({DateTime? from, DateTime? to}) async {
    final names = {for (final c in await db.select(db.expenseCategories).get()) c.id: c.nameAr};
    final v = <int, List<int>>{};
    for (final e in await _expenses(from, to)) {
      final x = v.putIfAbsent(e.categoryId, () => [0, 0]);
      x[0]++;
      x[1] += e.amount;
    }
    final list = [
      for (final e in v.entries) [names[e.key] ?? '', e.value[0], e.value[1]],
    ]..sort((a, b) => (b[2] as int).compareTo(a[2] as int));
    return ReportTable(
      title: ReportKind.expensesByCategory.title,
      columns: const [
        ReportColumn('البند', ColumnType.text),
        ReportColumn('العدد', ColumnType.count, sum: true),
        ReportColumn('المبلغ', ColumnType.money, sum: true),
      ],
      rows: list,
    );
  }

  // -------------------------------------------------------------- cheques

  /// Pending cheques by due date (received and issued).
  Future<ReportTable> chequesDue({DateTime? from, DateTime? to}) async {
    final rows = await db.customSelect(
      '''
      SELECT ch.due_date AS due, ch.cheque_no AS no, ch.bank AS bank, p.direction AS dir, p.amount AS amount,
             COALESCE(cu.name, su.name, '') AS party
      FROM cheques ch
      JOIN payments p ON p.id = ch.payment_id
      LEFT JOIN customers cu ON p.party_type = '${PartyType.customer}' AND cu.id = p.party_id
      LEFT JOIN suppliers su ON p.party_type = '${PartyType.supplier}' AND su.id = p.party_id
      WHERE ch.status = '${ChequeStatus.pending}' AND p.status = '${DocStatus.active}'
        AND (? IS NULL OR ch.due_date >= ?) AND (? IS NULL OR ch.due_date < ?)
      ORDER BY ch.due_date
      ''',
      variables: dateRangeVariables(from, to),
    ).get();
    return ReportTable(
      title: ReportKind.chequesDue.title,
      columns: const [
        ReportColumn('تاريخ الاستحقاق', ColumnType.date),
        ReportColumn('رقم الشيك', ColumnType.text),
        ReportColumn('البنك', ColumnType.text),
        ReportColumn('الطرف', ColumnType.text),
        ReportColumn('النوع', ColumnType.text),
        ReportColumn('المبلغ', ColumnType.money, sum: true),
      ],
      rows: [
        for (final r in rows)
          [
            r.read<DateTime>('due'),
            r.read<String>('no'),
            r.readNullable<String>('bank') ?? '',
            r.read<String>('party'),
            r.read<String>('dir') == PaymentDirection.inbound ? 'وارد' : 'صادر',
            r.read<int>('amount'),
          ],
      ],
    );
  }

  // ---------------------------------------------------------------- stock

  Future<ReportTable> stockLevels({int? categoryId}) async {
    final rows = await _stockRows(categoryId: categoryId);
    return ReportTable(
      title: ReportKind.stockLevels.title,
      columns: const [
        ReportColumn('الكود', ColumnType.text),
        ReportColumn('الصنف', ColumnType.text),
        ReportColumn('التصنيف', ColumnType.text),
        ReportColumn('الوحدة', ColumnType.text),
        ReportColumn('الرصيد', ColumnType.qty),
      ],
      rows: [for (final r in rows) [r.code, r.name, r.category ?? '', r.unit ?? '', r.stock]],
    );
  }

  Future<ReportTable> lowStock() async {
    final rows = (await _stockRows()).where((r) => r.minStock > 0 && r.stock <= r.minStock).toList();
    return ReportTable(
      title: ReportKind.lowStock.title,
      columns: const [
        ReportColumn('الكود', ColumnType.text),
        ReportColumn('الصنف', ColumnType.text),
        ReportColumn('الرصيد', ColumnType.qty),
        ReportColumn('حد الطلب', ColumnType.qty),
        ReportColumn('العجز', ColumnType.qty),
      ],
      rows: [for (final r in rows) [r.code, r.name, r.stock, r.minStock, r.minStock - r.stock]],
    );
  }

  /// Stock on hand at average cost. Products at zero or below are left out.
  Future<ReportTable> stockValuation({int? categoryId}) async {
    final rows = (await _stockRows(categoryId: categoryId)).where((r) => r.stock > 0).toList();
    return ReportTable(
      title: ReportKind.stockValuation.title,
      columns: const [
        ReportColumn('الكود', ColumnType.text),
        ReportColumn('الصنف', ColumnType.text),
        ReportColumn('الرصيد', ColumnType.qty),
        ReportColumn('متوسط التكلفة', ColumnType.money),
        ReportColumn('القيمة', ColumnType.money, sum: true),
      ],
      rows: [for (final r in rows) [r.code, r.name, r.stock, r.cost, lineAmount(r.stock, r.cost)]],
    );
  }

  // ------------------------------------------------------------- balances

  Future<ReportTable> customersOwing() async {
    final balances = await BalanceService(db).watchCustomerBalances().first;
    final customers = await db.select(db.customers).get();
    final list = [
      for (final c in customers)
        if ((balances[c.id] ?? 0) > 0) [c.name, c.phone ?? '', balances[c.id], c.creditLimit == 0 ? null : c.creditLimit],
    ]..sort((a, b) => (b[2] as int).compareTo(a[2] as int));
    return ReportTable(
      title: ReportKind.customersOwing.title,
      columns: const [
        ReportColumn('العميل', ColumnType.text),
        ReportColumn('التليفون', ColumnType.text),
        ReportColumn('الرصيد', ColumnType.money, sum: true),
        ReportColumn('حد الائتمان', ColumnType.money),
      ],
      rows: list,
    );
  }

  Future<ReportTable> supplierBalances() async {
    final balances = await BalanceService(db).watchSupplierBalances().first;
    final suppliers = await db.select(db.suppliers).get();
    final list = [
      for (final s in suppliers)
        if ((balances[s.id] ?? 0) != 0) [s.name, s.phone ?? '', balances[s.id]],
    ]..sort((a, b) => (b[2] as int).compareTo(a[2] as int));
    return ReportTable(
      title: ReportKind.supplierBalances.title,
      columns: const [
        ReportColumn('المورد', ColumnType.text),
        ReportColumn('التليفون', ColumnType.text),
        ReportColumn('الرصيد', ColumnType.money, sum: true),
      ],
      rows: list,
    );
  }

  // -------------------------------------------------------------- helpers

  Future<List<SalesInvoice>> _sales(DateTime? from, DateTime? to) => db.customSelect(
        "SELECT * FROM sales_invoices WHERE status = '${DocStatus.active}' "
        'AND (? IS NULL OR date >= ?) AND (? IS NULL OR date < ?) ORDER BY date, id',
        variables: dateRangeVariables(from, to),
      ).map((r) => db.salesInvoices.map(r.data)).get();

  Future<List<ReturnDoc>> _returns(String kind, DateTime? from, DateTime? to) => db.customSelect(
        "SELECT * FROM returns WHERE status = '${DocStatus.active}' AND kind = ? "
        'AND (? IS NULL OR date >= ?) AND (? IS NULL OR date < ?) ORDER BY date, id',
        variables: [Variable.withString(kind), ...dateRangeVariables(from, to)],
      ).map((r) => db.returns.map(r.data)).get();

  Future<List<Expense>> _expenses(DateTime? from, DateTime? to) => db.customSelect(
        "SELECT * FROM expenses WHERE status = '${DocStatus.active}' "
        'AND (? IS NULL OR date >= ?) AND (? IS NULL OR date < ?)',
        variables: dateRangeVariables(from, to),
      ).map((r) => db.expenses.map(r.data)).get();

  Future<List<({String code, String name, String? category, String? unit, int stock, int minStock, int cost})>>
      _stockRows({int? categoryId}) async {
    final rows = await db.customSelect(
      '''
      SELECT p.code, p.name_ar, p.min_stock, p.cost_price, c.name_ar AS category, u.name_ar AS unit,
             COALESCE((SELECT SUM(m.qty) FROM stock_movements m WHERE m.product_id = p.id), 0) AS stock
      FROM products p
      LEFT JOIN categories c ON c.id = p.category_id
      LEFT JOIN units u ON u.id = p.unit_id
      WHERE p.is_active = 1 AND (? IS NULL OR p.category_id = ?)
      ORDER BY p.name_ar
      ''',
      variables: [Variable<int>(categoryId), Variable<int>(categoryId)],
    ).get();
    return [
      for (final r in rows)
        (
          code: r.read<String>('code'),
          name: r.read<String>('name_ar'),
          category: r.readNullable<String>('category'),
          unit: r.readNullable<String>('unit'),
          stock: r.read<int>('stock'),
          minStock: r.read<int>('min_stock'),
          cost: r.read<int>('cost_price'),
        ),
    ];
  }

  static DateTime _day(DateTime d) {
    final l = d.toLocal();
    return DateTime(l.year, l.month, l.day);
  }
}
