import 'package:drift/drift.dart';

import '../db/database.dart';

/// What a customer or supplier did: for the lists' columns and sorting.
class PartyActivity {
  const PartyActivity({this.count = 0, this.total = 0, this.thisYear = 0, this.last});

  /// Active invoices.
  final int count;
  final int total;
  final int thisYear;
  final DateTime? last;

  static const none = PartyActivity();
}

/// Activity figures for the customer and supplier lists, kept live.
class DirectoryService {
  DirectoryService(this.db);

  final AppDatabase db;

  Stream<Map<int, PartyActivity>> _watch(String table, String partyColumn, Set<ResultSetImplementation> reads) {
    final yearStart = DateTime(DateTime.now().year).millisecondsSinceEpoch ~/ 1000;
    return db
        .customSelect(
          'SELECT $partyColumn AS p, COUNT(*) AS n, COALESCE(SUM(total), 0) AS t, '
          'COALESCE(SUM(CASE WHEN date >= ? THEN total ELSE 0 END), 0) AS y, MAX(date) AS d '
          "FROM $table WHERE status = 'active' AND $partyColumn IS NOT NULL GROUP BY $partyColumn",
          variables: [Variable.withInt(yearStart)],
          readsFrom: reads,
        )
        .watch()
        .map((rows) => {
              for (final r in rows)
                r.read<int>('p'): PartyActivity(
                  count: r.read<int>('n'),
                  total: r.read<int>('t'),
                  thisYear: r.read<int>('y'),
                  last: r.read<int?>('d') == null ? null : DateTime.fromMillisecondsSinceEpoch(r.read<int>('d') * 1000),
                ),
            });
  }

  /// The products sold most (by number of invoices) in the last [days].
  Future<List<int>> topSoldProducts({int limit = 24, int days = 120}) async {
    final since = DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch ~/ 1000;
    final rows = await db.customSelect(
      'SELECT i.product_id AS p, COUNT(*) AS n FROM sales_invoice_items i '
      'JOIN sales_invoices s ON s.id = i.invoice_id '
      "WHERE s.status = 'active' AND s.date >= ? GROUP BY i.product_id ORDER BY n DESC LIMIT ?",
      variables: [Variable.withInt(since), Variable.withInt(limit)],
    ).get();
    return [for (final r in rows) r.read<int>('p')];
  }

  Stream<Map<int, PartyActivity>> watchCustomerActivity() =>
      _watch('sales_invoices', 'customer_id', {db.salesInvoices});

  Stream<Map<int, PartyActivity>> watchSupplierActivity() =>
      _watch('purchase_invoices', 'supplier_id', {db.purchaseInvoices});
}
