import 'package:excel/excel.dart';

import '../dates.dart';
import 'report_table.dart';

/// A report as an .xlsx file: right-to-left sheet, title and date range on
/// top, then the table and its totals. Amounts are real numbers in pounds
/// and quantities in units, so the client can add them up in Excel.
List<int> reportToExcel(ReportTable table, {DateTime? from, DateTime? to, String? companyName}) {
  final excel = Excel.createExcel();
  const sheetName = 'التقرير';
  excel.rename(excel.getDefaultSheet()!, sheetName);
  final sheet = excel[sheetName];
  sheet.isRTL = true;

  if (companyName != null && companyName.isNotEmpty) sheet.appendRow([TextCellValue(companyName)]);
  sheet.appendRow([TextCellValue(table.title)]);
  if (from != null || to != null) {
    sheet.appendRow([
      TextCellValue('من ${from == null ? '—' : formatDate(from)} إلى ${to == null ? '—' : formatDate(to)}'),
    ]);
  }
  if (table.subtitle != null) sheet.appendRow([TextCellValue(table.subtitle!)]);
  sheet.appendRow(const []);

  sheet.appendRow([for (final c in table.columns) TextCellValue(c.title)]);
  for (final row in table.rows) {
    sheet.appendRow([for (var i = 0; i < table.columns.length; i++) _cell(row[i], table.columns[i].type)]);
  }
  if (table.hasTotals) {
    final totals = table.totals;
    sheet.appendRow([for (var i = 0; i < table.columns.length; i++) _cell(totals[i], table.columns[i].type)]);
  }
  for (var i = 0; i < table.columns.length; i++) {
    sheet.setColumnWidth(i, table.columns[i].type == ColumnType.text ? 30 : 16);
  }
  return excel.encode()!;
}

CellValue? _cell(Object? value, ColumnType type) {
  if (value == null) return null;
  if (value is String) return TextCellValue(value);
  return switch (type) {
    ColumnType.money => DoubleCellValue((value as int) / 100),
    ColumnType.qty => DoubleCellValue((value as int) / 1000),
    ColumnType.count => IntCellValue(value as int),
    ColumnType.date => () {
        final d = (value as DateTime).toLocal();
        return DateCellValue(year: d.year, month: d.month, day: d.day);
      }(),
    ColumnType.text => TextCellValue('$value'),
  };
}
