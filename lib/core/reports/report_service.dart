import 'package:drift/drift.dart';

import '../db/database.dart';
import '../quantity.dart';
import '../services/balance_service.dart';
import '../services/doc_types.dart';
import '../services/query_helpers.dart';
import '../services/settings_service.dart';
import '../services/stock_price_service.dart';
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
  stockByPrice('المخزون بالسعر القديم والجديد', byCategory: true),
  stockByPlace('المخزون حسب المكان', byCategory: true),
  purchasePlan('تخطيط الشراء'),
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
    this.days = const [],
    this.monthSales = 0,
    this.lastMonthSales = 0,
    this.monthInvoices = 0,
    this.monthGrossProfit = 0,
    this.stockValue = 0,
    this.receivables = 0,
    this.payables = 0,
    this.lowStock = const [],
    this.topProducts = const [],
    this.pendingPriceLists = 0,
    this.reviewRows = 0,
    this.unknownPriceStock = 0,
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

  /// Sales per day for the last 14 days, oldest first.
  final List<(DateTime day, int total)> days;

  /// This month so far, and the whole of last month.
  final int monthSales;
  final int lastMonthSales;
  final int monthInvoices;

  /// This month: net sales less the FIFO cost of goods sold, before expenses.
  final int monthGrossProfit;

  /// Stock at actual FIFO cost.
  final int stockValue;
  final int receivables;
  final int payables;

  /// Up to five items at or under their minimum: name, stock, minimum.
  final List<(String name, int stock, int min)> lowStock;

  /// Up to five best sellers this month by net value.
  final List<(String name, int value)> topProducts;
  final int pendingPriceLists;
  final int reviewRows;

  /// Products with stock whose price list is not known.
  final int unknownPriceStock;
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
      ReportKind.stockByPrice => stockByPrice(categoryId: categoryId),
      ReportKind.stockByPlace => stockByPlace(categoryId: categoryId),
      ReportKind.purchasePlan => purchasePlan(),
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
    final owing = await customersOwing();
    final debtors = owing.rows.take(5);
    final days = <(DateTime, int)>[];
    final from14 = today.subtract(const Duration(days: 13));
    final last14 = await _sales(from14, today);
    for (var k = 0; k < 14; k++) {
      final d = from14.add(Duration(days: k));
      days.add((d, last14.where((i) => _day(i.date) == d).fold<int>(0, (s, i) => s + i.total)));
    }
    final monthStart = DateTime(today.year, today.month);
    final lastMonthStart = DateTime(today.year, today.month - 1);
    final month = await _sales(monthStart, today);
    final lastMonth = await _sales(lastMonthStart, monthStart.subtract(const Duration(days: 1)));
    final profitRows = (await profit(from: monthStart, to: today)).rows;
    final gross = profitRows.firstWhere((r) => r[0] == 'مجمل الربح')[1] as int;
    final stockValueRow = await db.customSelect(
      'SELECT COALESCE(SUM((qty_remaining * unit_cost + 500) / 1000), 0) AS v FROM cost_layers WHERE qty_remaining > 0',
    ).getSingle();
    final suppliers = (await supplierBalances()).rows;
    final low = (await lowStock()).rows;
    final top = (await salesByProduct(from: monthStart, to: today)).rows;
    final pendingLists = await db.customSelect(
      "SELECT COUNT(*) AS n FROM price_lists WHERE status = 'pending_review'",
    ).getSingle();
    final review = await db.customSelect(
      "SELECT COUNT(*) AS n FROM price_list_items WHERE status = 'review'",
    ).getSingle();
    final unknown = (await StockPriceService(db).summaries()).values.where((s) => s.unknown > 0).length;
    return DashboardSummary(
      days: days,
      monthSales: month.fold(0, (s, i) => s + i.total),
      lastMonthSales: lastMonth.fold(0, (s, i) => s + i.total),
      monthInvoices: month.length,
      monthGrossProfit: gross,
      stockValue: stockValueRow.read<int>('v'),
      receivables: owing.rows.fold(0, (s, r) => s + (r[2] as int)),
      payables: suppliers.fold(0, (s, r) => s + ((r[2] as int) > 0 ? r[2] as int : 0)),
      lowStock: [for (final r in low.take(5)) (r[1] as String, r[2] as int, r[3] as int)],
      topProducts: [for (final r in top.take(5)) (r[1] as String, r[6] as int)],
      pendingPriceLists: pendingLists.read<int>('n'),
      reviewRows: review.read<int>('n'),
      unknownPriceStock: unknown,
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
      x[1] += i.netTotal;
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
      subtitle: 'القيم بعد توزيع خصم الفاتورة على السطور',
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
      if (ids.contains(i.invoiceId)) cost += i.costTotal;
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

  /// Stock on hand valued from the cost layers (what was really paid for
  /// the units still here). Any stock without a layer (negative-stock
  /// history, very old data) is priced at the product's average cost.
  /// Products at zero or below are left out.
  Future<ReportTable> stockValuation({int? categoryId}) async {
    final rows = (await _stockRows(categoryId: categoryId)).where((r) => r.stock > 0).toList();
    final layers = await db.select(db.costLayers).get();
    final byProduct = <int, List<CostLayer>>{};
    for (final l in layers) {
      if (l.qtyRemaining > 0) (byProduct[l.productId] ??= []).add(l);
    }
    final out = <List<Object?>>[];
    for (final r in rows) {
      var value = 0;
      var layered = 0;
      for (final l in byProduct[r.productId] ?? const <CostLayer>[]) {
        if (layered >= r.stock) break;
        final take = l.qtyRemaining > r.stock - layered ? r.stock - layered : l.qtyRemaining;
        value += lineAmount(take, l.unitCost);
        layered += take;
      }
      if (layered < r.stock) value += lineAmount(r.stock - layered, r.cost);
      // Average of what is on the shelf now, per whole unit.
      final avg = (value * qtyScale + r.stock ~/ 2) ~/ r.stock;
      out.add([r.code, r.name, r.stock, avg, value]);
    }
    return ReportTable(
      title: ReportKind.stockValuation.title,
      columns: const [
        ReportColumn('الكود', ColumnType.text),
        ReportColumn('الصنف', ColumnType.text),
        ReportColumn('الرصيد', ColumnType.qty),
        ReportColumn('متوسط التكلفة', ColumnType.money),
        ReportColumn('القيمة', ColumnType.money, sum: true),
      ],
      rows: out,
    );
  }

  /// How much of each item is at the old price and at the new price.
  Future<ReportTable> stockByPrice({int? categoryId}) async {
    final rows = (await _stockRows(categoryId: categoryId)).where((r) => r.stock > 0).toList();
    final service = StockPriceService(db);
    final out = <List<Object?>>[];
    for (final r in rows) {
      for (final l in await service.breakdown(r.productId)) {
        out.add([
          r.code,
          r.name,
          l.kind.label,
          l.versionLabel ?? '—',
          l.listPrice,
          l.currentPrice,
          l.qty,
          l.value,
        ]);
      }
    }
    return ReportTable(
      title: ReportKind.stockByPrice.title,
      columns: const [
        ReportColumn('الكود', ColumnType.text),
        ReportColumn('الصنف', ColumnType.text),
        ReportColumn('الحالة', ColumnType.text),
        ReportColumn('القائمة', ColumnType.text),
        ReportColumn('سعر القائمة', ColumnType.money),
        ReportColumn('السعر الحالي', ColumnType.money),
        ReportColumn('الكمية', ColumnType.qty),
        ReportColumn('التكلفة الفعلية', ColumnType.money, sum: true),
      ],
      rows: out,
    );
  }

  /// Each item's quantity in each place, with what can be sold.
  Future<ReportTable> stockByPlace({int? categoryId}) async {
    final rows = (await _stockRows(categoryId: categoryId)).where((r) => r.stock != 0).toList();
    final places = await db.select(db.locations).get();
    final stock = StockService(db);
    final out = <List<Object?>>[];
    for (final r in rows) {
      for (final l in places) {
        final q = await stock.currentStock(r.productId, locationId: l.id);
        if (q == 0) continue;
        final held = await (db.select(db.costLayers)
              ..where((c) =>
                  c.productId.equals(r.productId) & c.locationId.equals(l.id) & c.qtyRemaining.isBiggerThanValue(0)))
            .get();
        out.add([
          r.code,
          r.name,
          l.name,
          l.isSellable ? 'للبيع' : 'للعرض فقط',
          q,
          held.fold<int>(0, (s, c) => s + lineAmount(c.qtyRemaining, c.unitCost)),
        ]);
      }
    }
    return ReportTable(
      title: ReportKind.stockByPlace.title,
      columns: const [
        ReportColumn('الكود', ColumnType.text),
        ReportColumn('الصنف', ColumnType.text),
        ReportColumn('المكان', ColumnType.text),
        ReportColumn('النوع', ColumnType.text),
        ReportColumn('الكمية', ColumnType.qty),
        ReportColumn('القيمة بالتكلفة', ColumnType.money, sum: true),
      ],
      rows: out,
    );
  }

  /// What to order: for every item, the minimum level plus what is promised
  /// to customers, less what is on the shelf and what is already on order.
  /// Quantities are rounded up to whole units. Shows the supplier it was
  /// last bought from, and the estimated cost at the current cost price.
  Future<ReportTable> purchasePlan() async {
    final rows = await _stockRows();
    final now = DateTime.now();

    final reservedBy = <int, int>{};
    for (final r in await (db.select(db.reservations)..where((t) => t.status.equals('active'))).get()) {
      if (r.expiresAt == null || r.expiresAt!.isAfter(now)) {
        reservedBy[r.productId] = (reservedBy[r.productId] ?? 0) + r.qty;
      }
    }

    final onOrderBy = <int, int>{};
    final openOrders = await (db.select(db.purchaseOrders)
          ..where((t) => t.status.isIn(['approved', 'partly_received'])))
        .get();
    if (openOrders.isNotEmpty) {
      final lines = await (db.select(db.purchaseOrderLines)
            ..where((t) => t.orderId.isIn([for (final o in openOrders) o.id])))
          .get();
      for (final l in lines) {
        final left = l.qty - l.qtyReceived;
        if (left > 0) onOrderBy[l.productId] = (onOrderBy[l.productId] ?? 0) + left;
      }
    }

    // Last supplier per product: the newest active purchase invoice with it.
    final lastSupplier = <int, String>{};
    final bought = await db.customSelect(
      '''
      SELECT i.product_id AS pid, s.name AS supplier
      FROM purchase_invoice_items i
      JOIN purchase_invoices pi ON pi.id = i.invoice_id AND pi.status = '${DocStatus.active}'
      JOIN suppliers s ON s.id = pi.supplier_id
      ORDER BY pi.date ASC, pi.id ASC
      ''',
    ).get();
    for (final r in bought) {
      lastSupplier[r.read<int>('pid')] = r.read<String>('supplier');
    }

    final out = <List<Object?>>[];
    for (final r in rows) {
      final reserved = reservedBy[r.productId] ?? 0;
      final onOrder = onOrderBy[r.productId] ?? 0;
      final need = r.minStock + reserved - r.stock - onOrder;
      if (need <= 0) continue;
      // Round up to whole units.
      final order = ((need + qtyScale - 1) ~/ qtyScale) * qtyScale;
      out.add([
        r.code,
        r.name,
        r.stock,
        reserved,
        onOrder,
        r.minStock,
        order,
        lastSupplier[r.productId] ?? '',
        lineAmount(order, r.cost),
      ]);
    }
    out.sort((a, b) => (a[1] as String).compareTo(b[1] as String));
    return ReportTable(
      title: ReportKind.purchasePlan.title,
      columns: const [
        ReportColumn('الكود', ColumnType.text),
        ReportColumn('الصنف', ColumnType.text),
        ReportColumn('الرصيد', ColumnType.qty),
        ReportColumn('محجوز', ColumnType.qty),
        ReportColumn('على أوامر الشراء', ColumnType.qty),
        ReportColumn('حد الطلب', ColumnType.qty),
        ReportColumn('الكمية المقترحة', ColumnType.qty),
        ReportColumn('آخر مورد', ColumnType.text),
        ReportColumn('التكلفة التقديرية', ColumnType.money, sum: true),
      ],
      rows: out,
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

  Future<List<({int productId, String code, String name, String? category, String? unit, int stock, int minStock, int cost})>>
      _stockRows({int? categoryId}) async {
    final rows = await db.customSelect(
      '''
      SELECT p.id AS pid, p.code, p.name_ar, p.min_stock, c.name_ar AS category, u.name_ar AS unit,
             COALESCE((SELECT SUM(m.qty) FROM stock_movements m WHERE m.product_id = p.id), 0) AS stock,
             COALESCE((SELECT l.unit_cost FROM cost_layers l WHERE l.product_id = p.id
                       ORDER BY l.received_at DESC, l.id DESC LIMIT 1), 0) AS last_cost
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
          productId: r.read<int>('pid'),
          code: r.read<String>('code'),
          name: r.read<String>('name_ar'),
          category: r.readNullable<String>('category'),
          unit: r.readNullable<String>('unit'),
          stock: r.read<int>('stock'),
          minStock: r.read<int>('min_stock'),
          cost: r.read<int>('last_cost'),
        ),
    ];
  }

  static DateTime _day(DateTime d) {
    final l = d.toLocal();
    return DateTime(l.year, l.month, l.day);
  }
}
