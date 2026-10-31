import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../dates.dart';
import '../money.dart';
import '../quantity.dart';
import '../services/settings_service.dart';
import 'pdf_fonts.dart';
import 'pdf_widgets.dart';

class _SampleLine {
  const _SampleLine(this.name, this.code, this.qty, this.unitPrice);
  final String name;
  final String code;
  final int qty;
  final int unitPrice;
}

// Chosen to catch the usual Arabic printing problems: a long name that must
// wrap, Latin model codes inside Arabic text, and a fractional quantity.
const _lines = [
  _SampleLine('خلاط حوض جروهي', 'GROHE-23328', 2000, 125000),
  _SampleLine('مواسير بولي بروبلين ٢٥ مم (بالمتر)', 'PPR-25', 12500, 3500),
  _SampleLine(
    'طقم حمام كامل (حوض + قاعدة + خزان) لون أبيض، موديل إيطالي فاخر مع جميع الملحقات والتركيبات',
    'IDEAL-E0012',
    1000,
    875000,
  ),
];

/// A one-page A4 PDF that proves Arabic fonts, right-to-left layout and
/// number formatting print correctly before any real template is built.
Future<Uint8List> buildTestPage({
  required PdfFonts fonts,
  required CompanyInfo company,
  required DateTime printedAt,
}) {
  final rows = <List<String>>[];
  var total = 0;
  for (var i = 0; i < _lines.length; i++) {
    final l = _lines[i];
    final amount = lineAmount(l.qty, l.unitPrice);
    total += amount;
    rows.add([
      '${i + 1}',
      l.name,
      l.code,
      formatQty(l.qty),
      formatMoney(l.unitPrice),
      formatMoney(amount),
    ]);
  }

  final doc = pw.Document(theme: fonts.theme, title: 'صفحة اختبار الطباعة');
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      textDirection: pw.TextDirection.rtl,
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text(
            company.name.isEmpty ? 'اسم المحل' : company.name,
            style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
          ),
          if (company.address.isNotEmpty) pw.Text(company.address),
          if (company.phone.isNotEmpty) pw.Text('تليفون: ${company.phone}'),
          pw.Divider(),
          pw.SizedBox(height: 8),
          pw.Text(
            'صفحة اختبار الطباعة',
            style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            'إذا ظهرت الحروف العربية متصلة ومقروءة، والجدول يبدأ من اليمين، '
            'والأرقام والأكواد الإنجليزية في أماكنها الصحيحة، فالطباعة تعمل بشكل سليم.',
          ),
          pw.SizedBox(height: 16),
          rtlTable(
            columns: const [
              PdfColumn('م', flex: 0.5, numeric: true),
              PdfColumn('الصنف', flex: 3.5),
              // Wide enough that an 11-character model code stays on one line.
              PdfColumn('الكود', flex: 2.1, numeric: true),
              PdfColumn('الكمية', flex: 1, numeric: true),
              PdfColumn('السعر', flex: 1.3, numeric: true),
              PdfColumn('الإجمالي', flex: 1.4, numeric: true),
            ],
            rows: rows,
            footer: ['', 'الإجمالي', '', '', '', formatMoney(total)],
          ),
          pw.SizedBox(height: 16),
          pw.Text('رقم الفاتورة: S-000123 — الموديل: Grohe BauEdge 23328'),
          pw.Text('أرقام بالشكل الغربي في كل البرنامج: 0123456789'),
          pw.Text(
            'خط عريض للعناوين والإجماليات',
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
          pw.Spacer(),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('التوقيع: ....................'),
              pw.Text('تاريخ الطباعة: ${formatDateTime(printedAt)}'),
            ],
          ),
        ],
      ),
    ),
  );
  return doc.save();
}
