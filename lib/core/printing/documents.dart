import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../dates.dart';
import '../money.dart';
import '../quantity.dart';
import '../reports/report_table.dart';
import '../services/purchase_service.dart';
import '../services/sales_service.dart';
import 'pdf_fonts.dart';
import 'pdf_widgets.dart';

/// The shop as it appears at the top of every printed page.
class PrintCompany {
  const PrintCompany({required this.name, this.address = '', this.phone = '', this.logo, this.printer});

  final String name;
  final String address;
  final String phone;

  /// PNG or JPEG bytes, if a logo has been chosen in Settings.
  final Uint8List? logo;

  /// The paper and printable area the printer reported, when printing. Its
  /// margins are kept so nothing at the foot of the page (signatures, date,
  /// page number) falls in the part the printer cannot reach. Null = A4.
  final PdfPageFormat? printer;

  PrintCompany forPrinter(PdfPageFormat format) =>
      PrintCompany(name: name, address: address, phone: phone, logo: logo, printer: format);
}

/// A label and its value as two separate runs. A date, number or code set
/// inside an Arabic sentence ("التاريخ: 2026/11/19 15:23") is reordered by
/// the PDF's bidi pass and can print scrambled; apart, each keeps its order.
pw.Widget _labelValue(String label, String value, {bool bold = false, bool ltr = true, double? fontSize}) {
  final style = pw.TextStyle(fontWeight: bold ? pw.FontWeight.bold : null, fontSize: fontSize);
  return pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
    pw.Text('$label:', style: style),
    pw.SizedBox(width: 4),
    pw.Text(value, style: style, textDirection: ltr ? pw.TextDirection.ltr : pw.TextDirection.rtl),
  ]);
}

/// A payment receipt: what a customer paid us or what we paid a supplier.
class ReceiptData {
  const ReceiptData({
    required this.number,
    required this.date,
    required this.received,
    required this.partyName,
    required this.amount,
    required this.method,
    this.chequeNo,
    this.bank,
    this.dueDate,
    this.forWhat,
    this.notes,
    this.cancelled = false,
  });

  final String number;
  final DateTime date;

  /// True when we received the money (receipt), false when we paid it.
  final bool received;
  final String partyName;
  final int amount;
  final String method;
  final String? chequeNo;
  final String? bank;
  final DateTime? dueDate;

  /// e.g. "فاتورة بيع S-000012" or "تحت الحساب".
  final String? forWhat;
  final String? notes;
  final bool cancelled;
}

String _methodLabel(String method) => switch (method) {
      PaymentMethod.bank => 'تحويل بنكي',
      PaymentMethod.cheque => 'شيك',
      _ => 'نقدي',
    };

/// A4 sales invoice: shop header, customer, items, totals, balance and
/// signature lines. A cancelled invoice prints with a "ملغاة" watermark.
Future<Uint8List> salesInvoicePdf(SalesInvoiceDetail d, PrintCompany company, PdfFonts fonts) {
  final inv = d.invoice;
  final rows = [
    for (var i = 0; i < d.lines.length; i++)
      [
        '${i + 1}',
        d.lines[i].productCode,
        d.lines[i].productName,
        formatQty(d.lines[i].item.qty),
        d.lines[i].unitName ?? '',
        formatMoney(d.lines[i].item.unitPrice),
        d.lines[i].item.discount == 0 ? '' : formatMoney(d.lines[i].item.discount),
        formatMoney(d.lines[i].item.lineTotal),
      ],
  ];
  return _document(
    fonts: fonts,
    company: company,
    title: 'فاتورة بيع',
    number: inv.number,
    date: inv.date,
    cancelled: inv.status == DocStatus.cancelled,
    body: [
      _partyBlock(
        'العميل',
        d.customer?.name ?? 'نقدي',
        phone: d.customer?.phone,
        address: d.customer?.address,
        extras: [
          if (d.customer?.taxNumber != null) _labelValue('الرقم الضريبي', d.customer!.taxNumber!),
          if (inv.dueDate != null) _labelValue('تاريخ الاستحقاق', formatDate(inv.dueDate!)),
        ],
      ),
      pw.SizedBox(height: 10),
      rtlTable(
        columns: const [
          PdfColumn('م', flex: 0.8, numeric: true),
          PdfColumn('الكود', flex: 1.4, numeric: true),
          PdfColumn('الصنف', flex: 3.6),
          PdfColumn('الكمية', flex: 1.2, numeric: true),
          PdfColumn('الوحدة', flex: 1.2, numeric: true),
          PdfColumn('السعر', flex: 1.3, numeric: true),
          PdfColumn('الخصم', flex: 1.1, numeric: true),
          PdfColumn('الإجمالي', flex: 1.5, numeric: true),
        ],
        rows: rows,
      ),
      pw.SizedBox(height: 10),
      _totals([
        ('المجموع', inv.subtotal, false),
        if (inv.discount != 0) ('خصم الفاتورة', inv.discount, false),
        if (inv.deliveryFee != 0) ('رسوم التوصيل', inv.deliveryFee, false),
        ('الإجمالي', inv.total, true),
        ('المدفوع', d.paid, false),
        ('المتبقي', inv.total - d.paid, true),
        if (d.customerBalance != null) ('رصيد العميل الحالي', d.customerBalance!, true),
      ]),
      if (inv.notes != null) ...[pw.SizedBox(height: 8), pw.Text('ملاحظات: ${inv.notes}')],
      pw.SizedBox(height: 30),
      _signatures([('المستلم', null), ('البائع', d.createdByName)]),
    ],
  );
}

Future<Uint8List> purchaseInvoicePdf(PurchaseInvoiceDetail d, PrintCompany company, PdfFonts fonts) {
  final inv = d.invoice;
  return _document(
    fonts: fonts,
    company: company,
    title: 'فاتورة شراء',
    number: inv.number,
    date: inv.date,
    cancelled: inv.status == DocStatus.cancelled,
    body: [
      _partyBlock(
        'المورد',
        d.supplier.name,
        phone: d.supplier.phone,
        extras: [if (inv.supplierInvoiceNo != null) _labelValue('رقم فاتورة المورد', inv.supplierInvoiceNo!)],
      ),
      pw.SizedBox(height: 10),
      rtlTable(
        columns: const [
          PdfColumn('م', flex: 0.8, numeric: true),
          PdfColumn('الكود', flex: 1.4, numeric: true),
          PdfColumn('الصنف', flex: 3.6),
          PdfColumn('الكمية', flex: 1.2, numeric: true),
          PdfColumn('الوحدة', flex: 1.2, numeric: true),
          PdfColumn('تكلفة الوحدة', flex: 1.4, numeric: true),
          PdfColumn('الإجمالي', flex: 1.5, numeric: true),
        ],
        rows: [
          for (var i = 0; i < d.lines.length; i++)
            [
              '${i + 1}',
              d.lines[i].productCode,
              d.lines[i].productName,
              formatQty(d.lines[i].item.qty),
              d.lines[i].unitName ?? '',
              formatMoney(d.lines[i].item.unitCost),
              formatMoney(d.lines[i].item.lineTotal),
            ],
        ],
      ),
      pw.SizedBox(height: 10),
      _totals([
        ('المجموع', inv.subtotal, false),
        if (inv.discount != 0) ('خصم الفاتورة', inv.discount, false),
        if (inv.vatAmount != 0) ('ضريبة القيمة المضافة', inv.vatAmount, false),
        ('الإجمالي', inv.total, true),
        ('المدفوع', d.paid, false),
        ('المتبقي', inv.total - d.paid, true),
      ]),
      if (inv.notes != null) ...[pw.SizedBox(height: 8), pw.Text('ملاحظات: ${inv.notes}')],
      pw.SizedBox(height: 30),
      _signatures([('المستلم', null), ('المورد', null)]),
    ],
  );
}

/// Half an A4 page is plenty, but A4 keeps one paper size in the printer.
Future<Uint8List> receiptPdf(ReceiptData r, PrintCompany company, PdfFonts fonts) {
  final rows = <(String, String)>[
    (r.received ? 'استلمنا من' : 'دفعنا إلى', r.partyName),
    ('مبلغ وقدره (جنيه)', formatMoney(r.amount)),
    ('طريقة الدفع', _methodLabel(r.method)),
    if (r.chequeNo != null) ('رقم الشيك', r.chequeNo!),
    if (r.bank != null) ('البنك', r.bank!),
    if (r.dueDate != null) ('تاريخ الاستحقاق', formatDate(r.dueDate!)),
    if (r.forWhat != null) ('وذلك مقابل', r.forWhat!),
    if (r.notes != null) ('ملاحظات', r.notes!),
  ];
  return _document(
    fonts: fonts,
    company: company,
    title: r.received ? 'إيصال استلام نقدية' : 'إيصال صرف نقدية',
    number: r.number,
    date: r.date,
    cancelled: r.cancelled,
    body: [
      pw.Container(
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey600, width: 0.5)),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            for (final (label, value) in rows)
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 4),
                child: pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.SizedBox(
                      width: 110,
                      child: pw.Text('$label:', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                    ),
                    pw.Expanded(
                      child: pw.Text(
                        value,
                        textDirection: PdfBidi.isLtr(value) ? pw.TextDirection.ltr : pw.TextDirection.rtl,
                        textAlign: pw.TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
      pw.SizedBox(height: 40),
      _signatures([(r.received ? 'المستلم عن المحل' : 'المستلم', null), ('المحاسب', null)]),
    ],
  );
}

/// Any report or statement as a printed table, with its totals row. Wide
/// tables print in landscape.
Future<Uint8List> tablePdf(
  ReportTable table,
  PrintCompany company,
  PdfFonts fonts, {
  DateTime? from,
  DateTime? to,
  List<String> footerLines = const [],
}) {
  final columns = [
    for (final c in table.columns)
      PdfColumn(c.title, flex: c.type == ColumnType.text ? 3 : 1.5, numeric: c.type != ColumnType.text),
  ];
  String cell(Object? v, ReportColumn c) => ReportTable.display(v, c.type);
  return _document(
    fonts: fonts,
    company: company,
    title: table.title,
    date: DateTime.now(),
    landscape: table.columns.length > 6,
    body: [
      if (from != null || to != null)
        pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
          _labelValue('الفترة: من', from == null ? '—' : formatDate(from)),
          pw.SizedBox(width: 8),
          _labelValue('إلى', to == null ? '—' : formatDate(to)),
        ]),
      if (table.subtitle != null) pw.Text(table.subtitle!, style: const pw.TextStyle(fontSize: 9)),
      pw.SizedBox(height: 8),
      rtlTable(
        columns: columns,
        rows: [
          for (final r in table.rows) [for (var i = 0; i < columns.length; i++) cell(r[i], table.columns[i])],
        ],
        footer: table.hasTotals
            ? [for (var i = 0; i < columns.length; i++) cell(table.totals[i], table.columns[i])]
            : null,
      ),
      for (final line in footerLines) ...[pw.SizedBox(height: 6), pw.Text(line)],
    ],
  );
}

Future<Uint8List> _document({
  required PdfFonts fonts,
  required PrintCompany company,
  required String title,
  required DateTime date,
  required List<pw.Widget> body,
  String? number,
  bool cancelled = false,
  bool landscape = false,
}) {
  final doc = pw.Document(theme: fonts.theme, title: number == null ? title : '$title $number');
  doc.addPage(
    pw.MultiPage(
      maxPages: 500,
      pageTheme: pw.PageTheme(
        pageFormat: _paper(company.printer, landscape),
        margin: _margins(company.printer),
        textDirection: pw.TextDirection.rtl,
        theme: fonts.theme,
        buildForeground: cancelled
            ? (_) => pw.Watermark.text(
                  'ملغاة',
                  style: pw.TextStyle(color: PdfColor.fromInt(0x40E53935), fontSize: 120, fontWeight: pw.FontWeight.bold),
                )
            : null,
      ),
      header: (context) => _header(company, title, number, date, firstPage: context.pageNumber == 1),
      footer: (context) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 6),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(company.name, style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
            pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
              pw.Text('صفحة', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
              pw.SizedBox(width: 3),
              pw.Text('${context.pageNumber} / ${context.pagesCount}',
                  textDirection: pw.TextDirection.ltr,
                  style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
            ]),
          ],
        ),
      ),
      build: (_) => body,
    ),
  );
  return doc.save();
}

pw.Widget _header(PrintCompany c, String title, String? number, DateTime date, {required bool firstPage}) {
  final docInfo = pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.end,
    children: [
      pw.Text(title, style: pw.TextStyle(fontSize: firstPage ? 18 : 12, fontWeight: pw.FontWeight.bold)),
      if (number != null) _labelValue('رقم', number),
      _labelValue('التاريخ', formatDateTime(date)),
    ],
  );
  if (!firstPage) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 8),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [pw.Text(c.name), docInfo]),
    );
  }
  return pw.Column(
    children: [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (c.logo != null)
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 10),
              child: pw.SizedBox(width: 64, height: 64, child: pw.Image(pw.MemoryImage(c.logo!), fit: pw.BoxFit.contain)),
            ),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(c.name.isEmpty ? ' ' : c.name, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
                if (c.address.isNotEmpty) pw.Text(c.address),
                if (c.phone.isNotEmpty) _labelValue('تليفون', c.phone),
              ],
            ),
          ),
          docInfo,
        ],
      ),
      pw.Divider(thickness: 1),
      pw.SizedBox(height: 4),
    ],
  );
}

pw.Widget _partyBlock(String label, String name,
    {String? phone, String? address, String? extra, List<pw.Widget> extras = const []}) {
  return pw.Container(
    padding: const pw.EdgeInsets.all(8),
    decoration: pw.BoxDecoration(color: PdfColors.grey100, border: pw.Border.all(color: PdfColors.grey400, width: 0.5)),
    child: pw.Wrap(
      spacing: 24,
      runSpacing: 4,
      children: [
        pw.Text('$label: $name', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        if (phone != null && phone.isNotEmpty) _labelValue('تليفون', phone),
        if (address != null && address.isNotEmpty) _labelValue('العنوان', address, ltr: false),
        if (extra != null && extra.isNotEmpty) pw.Text(extra),
        ...extras,
      ],
    ),
  );
}

/// Label/amount lines on the left of the page (the end, in RTL).
pw.Widget _totals(List<(String, int, bool)> lines) {
  return pw.Align(
    alignment: pw.Alignment.centerLeft,
    child: pw.SizedBox(
      width: 230,
      child: pw.Column(
        children: [
          for (final (label, amount, bold) in lines)
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 6),
              decoration: bold ? const pw.BoxDecoration(color: PdfColors.grey200) : null,
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(label, style: bold ? pw.TextStyle(fontWeight: pw.FontWeight.bold) : null),
                  pw.Text(formatMoney(amount),
                      textDirection: pw.TextDirection.ltr,
                      style: bold ? pw.TextStyle(fontWeight: pw.FontWeight.bold) : null),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

/// The signature block at the foot of a document: for each party, who
/// signs (and their name, on its own line), a line to sign on and a line for
/// the date. It is one piece: it moves whole to the next page rather than
/// being cut, and it sits inside the printable area (see [_margins]).
pw.Widget _signatures(List<(String role, String? name)> parties) {
  pw.Widget line(String label) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 14),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.SizedBox(width: 44, child: pw.Text('$label:', style: const pw.TextStyle(fontSize: 10))),
          pw.Expanded(
            child: pw.Container(
              height: 14,
              decoration: const pw.BoxDecoration(
                border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey700, width: 0.7)),
              ),
            ),
          ),
        ]),
      );
  return pw.Padding(
    padding: const pw.EdgeInsets.only(top: 18),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < parties.length; i++) ...[
          if (i > 0) pw.SizedBox(width: 36),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(parties[i].$1, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                if (parties[i].$2 != null)
                  pw.Text(parties[i].$2!, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
                line('التوقيع'),
                line('التاريخ'),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}

/// A4 (landscape for wide tables) unless the printer reports another paper.
PdfPageFormat _paper(PdfPageFormat? printer, bool landscape) {
  final base = printer == null ? PdfPageFormat.a4 : PdfPageFormat(printer.width, printer.height);
  return landscape ? base.landscape : base.portrait;
}

/// Our margins, or the printer's own where it cannot print as close to the
/// edge (many inkjets leave more at the bottom), plus a little to spare.
pw.EdgeInsets _margins(PdfPageFormat? printer) {
  double atLeast(double ours, double? theirs) =>
      theirs == null || theirs + 6 <= ours ? ours : theirs + 6;
  return pw.EdgeInsets.fromLTRB(
    atLeast(32, printer?.marginLeft),
    atLeast(28, printer?.marginTop),
    atLeast(32, printer?.marginRight),
    atLeast(36, printer?.marginBottom),
  );
}

/// True for text that reads left to right on its own: digits, Latin letters,
/// dates and codes, with no Arabic letter in it.
abstract final class PdfBidi {
  static final _arabic = RegExp('[\u0600-\u06FF]');
  static bool isLtr(String text) => text.isNotEmpty && !_arabic.hasMatch(text);
}
