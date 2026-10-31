import '../dates.dart';
import '../money.dart';
import '../quantity.dart';

enum ColumnType {
  text,

  /// Piastres.
  money,

  /// Thousandths of a unit.
  qty,
  count,
  date,
}

class ReportColumn {
  const ReportColumn(this.title, this.type, {this.sum = false});

  final String title;
  final ColumnType type;

  /// Add this column up in the totals row.
  final bool sum;
}

/// What every report returns: the screen shows it, Excel exports it, and
/// tests compare its numbers with hand calculations.
class ReportTable {
  ReportTable({required this.title, required this.columns, required this.rows, this.subtitle});

  final String title;
  final String? subtitle;
  final List<ReportColumn> columns;

  /// Raw values: String for text, int for money/qty/count, DateTime for date.
  final List<List<Object?>> rows;

  bool get hasTotals => columns.any((c) => c.sum);

  /// "الإجمالي" in the first column, sums under summed columns.
  List<Object?> get totals => [
        for (var i = 0; i < columns.length; i++)
          columns[i].sum
              ? rows.fold<int>(0, (s, r) => s + ((r[i] as int?) ?? 0))
              : (i == 0 ? 'الإجمالي' : null),
      ];

  /// Total of the column titled [title] (for tests and summaries).
  int total(String title) {
    final i = columns.indexWhere((c) => c.title == title);
    return rows.fold<int>(0, (s, r) => s + ((r[i] as int?) ?? 0));
  }

  /// One value as the screen shows it.
  static String display(Object? value, ColumnType type) {
    if (value == null) return '';
    return switch (type) {
      ColumnType.money => formatMoney(value as int),
      ColumnType.qty => formatQty(value as int),
      ColumnType.date => formatDate(value as DateTime),
      ColumnType.count => '$value',
      ColumnType.text => '$value',
    };
  }
}
