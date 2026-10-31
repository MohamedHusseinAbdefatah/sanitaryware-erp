import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// One table column. [numeric] columns are centred; text columns line up
/// on the right, where Arabic text starts.
class PdfColumn {
  const PdfColumn(this.title, {this.flex = 1, this.numeric = false});

  final String title;
  final double flex;
  final bool numeric;
}

/// A bordered table laid out right to left: [columns] and each row's cells
/// are given in reading order, and the first one is drawn on the right.
/// (pw.Table itself always draws its first column on the left.)
pw.Widget rtlTable({
  required List<PdfColumn> columns,
  required List<List<String>> rows,
  List<String>? footer,
  double fontSize = 9.5,
}) {
  final reversed = columns.reversed.toList();

  pw.Widget cell(String text, PdfColumn column, {bool bold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: pw.Text(
        text,
        textAlign: column.numeric ? pw.TextAlign.center : pw.TextAlign.right,
        style: pw.TextStyle(fontSize: fontSize, fontWeight: bold ? pw.FontWeight.bold : null),
      ),
    );
  }

  pw.TableRow row(List<String> cells, {bool bold = false, PdfColor? color}) {
    final r = cells.reversed.toList();
    return pw.TableRow(
      decoration: color == null ? null : pw.BoxDecoration(color: color),
      verticalAlignment: pw.TableCellVerticalAlignment.middle,
      children: [
        for (var i = 0; i < reversed.length; i++)
          cell(r[i], reversed[i], bold: bold),
      ],
    );
  }

  return pw.Table(
    border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
    columnWidths: {
      for (var i = 0; i < reversed.length; i++)
        i: pw.FlexColumnWidth(reversed[i].flex),
    },
    children: [
      row([for (final c in columns) c.title], bold: true, color: PdfColors.grey200),
      for (final cells in rows) row(cells),
      if (footer != null) row(footer, bold: true, color: PdfColors.grey100),
    ],
  );
}
