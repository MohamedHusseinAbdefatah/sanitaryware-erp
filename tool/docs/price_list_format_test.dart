// Builds what to give the shop so its staff prepare price lists the program
// reads without trouble:
//
//   docs/price_list_format_ar.pdf                    the rules, in Arabic
//   docs/templates/price_list_one_price.xlsx         one price per row
//   docs/templates/price_list_price_per_colour.xlsx  one price column per colour
//
// Both templates are read back with the real importer before the PDF is
// written, so what the guide shows is what the program accepts.
//
//   flutter test tool/docs/price_list_format_test.dart
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:sanitaryware_erp/core/db/database.dart';
import 'package:sanitaryware_erp/core/printing/pdf_fonts.dart';
import 'package:sanitaryware_erp/core/printing/pdf_widgets.dart';
import 'package:sanitaryware_erp/core/services/catalog_service.dart';
import 'package:sanitaryware_erp/core/services/price_list_import_service.dart';
import 'package:sanitaryware_erp/core/version.dart';

/// Sample rows: made-up codes and prices, to show the shape only.
const _onePriceHeaders = ['كود الشركة', 'الاسم', 'اللون', 'السعر', 'عدد الكرتونة', 'التصنيف', 'السلسلة', 'المقاسات'];
const _onePriceRows = [
  ['0123-A', 'حوض معلق 60 سم', 'أبيض', 2450, 1, 'أحواض', 'Connect', '60x45'],
  ['0123-B', 'حوض معلق 60 سم', 'أسود', 2890, 1, 'أحواض', 'Connect', '60x45'],
  ['00457', 'خلاط حوض', '', 1875.5, '', 'خلاطات', 'Ceraflex', ''],
  ['T-3290', 'قاعدة معلقة', 'أبيض', 5200, '', 'قواعد', 'Tesi', '53x36'],
];
const _perColourHeaders = ['كود الشركة', 'الاسم', 'سعر أبيض', 'سعر برجامون', 'التصنيف', 'السلسلة'];
const _perColourRows = [
  ['T-3290', 'قاعدة معلقة', 5200, 5650, 'قواعد', 'Tesi'],
  ['T-3291', 'غطاء قاعدة بطيء الغلق', 1800, '', 'قواعد', 'Tesi'],
  ['E-7701', 'حوض بقاعدة', 3100, 3400, 'أحواض', 'Eurovit'],
];

List<int> _sheet(List<String> headers, List<List<Object>> rows) {
  final excel = Excel.createExcel();
  excel.rename(excel.getDefaultSheet()!, 'قائمة الأسعار');
  final sheet = excel['قائمة الأسعار'];
  sheet.isRTL = true;
  sheet.appendRow([for (final h in headers) TextCellValue(h)]);
  for (final r in rows) {
    sheet.appendRow([
      for (var i = 0; i < r.length; i++)
        switch (r[i]) {
          // The maker's code is always text, so 00457 keeps its zeros.
          final String s when i == 0 => TextCellValue(s),
          '' => null,
          final int n => IntCellValue(n),
          final double d => DoubleCellValue(d),
          final v => TextCellValue('$v'),
        },
    ]);
  }
  for (var i = 0; i < headers.length; i++) {
    sheet.setColumnWidth(i, headers[i] == 'الاسم' ? 30 : 15);
  }
  return excel.encode()!;
}

/// The columns, as the importer reads them.
const _columns = [
  ['كود الشركة', 'مطلوب إن كان في القائمة', 'كود المصنع كما هو في قائمة المورد. يُحفظ كنص فتبقى الأصفار والشرطات: 00457 ليس 457. اجعل العمود من نوع "نص" في Excel قبل لصق الأكواد. الأسماء المقبولة أيضاً: الكود، كود المورد، كود المصنع، code، model.', '0123-A'],
  ['الاسم', 'مطلوب للأصناف الجديدة', 'اسم الصنف كما يريد المحل أن يراه. إذا لم يوجد كود في القائمة كلها، يُطابق البرنامج بالاسم داخل الماركة. يقبل أيضاً: اسم الصنف، name.', 'حوض معلق 60 سم'],
  ['السعر', 'مطلوب', 'سعر القائمة الرسمي قبل أي خصم، رقم فقط بدون "ج.م". يقبل الكسور (1875.50) والفاصلة (2,400). يقبل أيضاً: سعر القائمة، price.', '2450'],
  ['اللون', 'اختياري', 'لون الصنف أو نوعه إن كان للكود الواحد أكثر من لون. يقبل أيضاً: color، variant.', 'أبيض'],
  ['سعر أبيض، سعر برجامون، ...', 'بدل عمود السعر', 'عمود لكل لون، اسمه "سعر" ثم اللون. كل لون يصبح سطراً بسعره. الخانة الفارغة تعني أن الصنف غير متوفر بهذا اللون.', '5200'],
  ['عدد الكرتونة', 'اختياري', 'عدد القطع داخل الكرتونة إن وُجد في القائمة. يقبل أيضاً: التعبئة.', '4'],
  ['التصنيف، التصنيف الفرعي، السلسلة، الوصف، المقاسات، التشطيب، الوحدة، الباركود، المواصفات الفنية', 'اختياري', 'تُستخدم لإنشاء الأصناف الجديدة فقط، ولا تغير بيانات صنف موجود. التصنيف غير الموجود يُنشأ تلقائياً.', 'أحواض'],
];

const _rules = [
  'ملف Excel بصيغة xlsx. أو ملف PDF من المورد بشرط أن يكون نصاً يمكن تحديده ونسخه، وليس صورة ممسوحة ضوئياً.',
  'ملف واحد لكل ماركة. الماركة تُختار في البرنامج عند الرفع ولا تُكتب في الملف.',
  'الصف الأول هو أسماء الأعمدة، والأصناف تبدأ من الصف الثاني مباشرة. لا تضع عنواناً أو شعاراً أو صفوفاً فارغة فوق أسماء الأعمدة.',
  'ورقة واحدة: البرنامج يقرأ أول ورقة فيها بيانات فقط. إذا كانت القائمة على عدة أوراق، انسخها في ورقة واحدة أو ارفع كل ورقة كملف.',
  'الأسعار هي أسعار القائمة قبل خصم المورد. خصم المورد لكل ماركة يُسجل مرة واحدة في البرنامج (سياسات الشراء) ويُطبق تلقائياً على كل فاتورة شراء.',
  'ترتيب الأعمدة لا يهم. أي عمود باسم آخر (ملاحظات، صورة، ...) يتجاهله البرنامج.',
  'لا تُدمج الخلايا ولا تُكتب الأسعار كنص مثل "2,450 ج.م".',
];

const _stops = [
  'كود مكرر في نفس الملف بسعرين مختلفين.',
  'سعر فارغ أو غير صحيح.',
  'صنف جديد بدون اسم.',
  'كود موجود بلون آخر ولا يمكن معرفة المقصود.',
];

const _update = [
  'عند وصول قائمة جديدة أو زيادة في الأسعار (مثلاً 10%) ارفع الملف الجديد كاملاً.',
  'اختر نفس الماركة، ثم اضغط زر نوع القائمة الموجود تحت خانة "نوع القائمة". يظهر سطر أزرق: "إصدار جديد"، والقائمة القديمة تتوقف من تاريخ السريان وتبقى في السجل.',
  'خصومات الموردين تنتقل للإصدار الجديد تلقائياً بنفس النسب، وخصومات البيع لفئات العملاء لا ترتبط بالقائمة فتبقى كما هي.',
  'إذا ظهر تحذير أحمر "قائمة منفصلة جديدة" فأنت كتبت نوعاً جديداً: استخدمه فقط لقائمة مختلفة فعلاً لنفس الماركة (مثلاً بانيوهات وحدها)، وليس لتحديث الأسعار.',
];

const _steps = [
  'قوائم الأسعار ثم "استيراد قائمة كاملة" (أو "استيراد من PDF").',
  'اختر الماركة، ثم نوع القائمة، واكتب اسماً للقائمة (مثال: Ideal Standard يوليو 2026).',
  'حدد تاريخ السريان وحالة الضريبة (شامل، غير شامل، أو غير متحقق منها).',
  'اختر الملف. يظهر عدد الأصناف المعروفة التي يضاف سعرها، والجديدة التي تأخذ رقم صنف، والمتوقفة للمراجعة.',
  'اضغط "حفظ الإصدار". الصفوف المتوقفة تُراجع من تبويب "قيد المراجعة" ولا يُخمن لها أي سعر.',
];

const _checklist = [
  'الصف الأول أسماء الأعمدة، ولا شيء فوقه.',
  'عمود كود الشركة من نوع نص، والأكواد بأصفارها.',
  'عمود السعر أرقام فقط، وهو سعر القائمة قبل الخصم.',
  'كل الأصناف في ورقة واحدة.',
  'الملف لماركة واحدة.',
];

void main() {
  test('build the price list templates and docs/price_list_format_ar.pdf', () async {
    // 1. The templates, checked with the real importer.
    final one = _sheet(_onePriceHeaders, _onePriceRows);
    final perColour = _sheet(_perColourHeaders, _perColourRows);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final brand = await CatalogService(db).saveBrand(name: 'ماركة');
    final importer = PriceListImportService(db);
    final p1 = await importer.preview(one, brandId: brand);
    expect(p1.missingColumns, isEmpty);
    expect(p1.reviewCount, 0, reason: p1.rows.where((r) => !r.ok).map((r) => r.reviewReason).join('; '));
    expect(p1.createCount, _onePriceRows.length);
    expect(p1.rows.firstWhere((r) => r.name == 'خلاط حوض').code, '00457');
    final p2 = await importer.preview(perColour, brandId: brand);
    expect(p2.missingColumns, isEmpty);
    expect(p2.reviewCount, 0, reason: p2.rows.where((r) => !r.ok).map((r) => r.reviewReason).join('; '));
    expect(p2.createCount, 5, reason: 'two colours each, but the cover has no Pergamon price');
    await Directory('docs/templates').create(recursive: true);
    await File('docs/templates/price_list_one_price.xlsx').writeAsBytes(one);
    await File('docs/templates/price_list_price_per_colour.xlsx').writeAsBytes(perColour);

    // 2. The guide.
    ByteData font(String name) => ByteData.sublistView(File('assets/fonts/$name').readAsBytesSync());
    final fonts = PdfFonts.fromBytes(regular: font('Cairo-Regular.ttf'), bold: font('Cairo-Bold.ttf'));
    final glyphs = TtfParser(font('Cairo-Regular.ttf')).charToGlyphIndexMap;
    final allText = [
      for (final r in _columns) ...r,
      ..._rules, ..._stops, ..._update, ..._steps, ..._checklist,
      for (final r in [..._onePriceRows, ..._perColourRows]) for (final c in r) '$c',
    ].join();
    final missingGlyphs = {for (final r in allText.runes) if (r > 32 && !glyphs.containsKey(r)) String.fromCharCode(r)};
    expect(missingGlyphs, isEmpty, reason: 'Cairo has no glyph for: ${missingGlyphs.join(' ')}');

    const teal = PdfColor.fromInt(0xFF0E7C86);
    const dark = PdfColor.fromInt(0xFF0B3B40);
    const grey = PdfColor.fromInt(0xFF5C7175);
    const soft = PdfColor.fromInt(0xFFF2F5F6);
    const warn = PdfColor.fromInt(0xFFB3261E);
    final bold = pw.TextStyle(fontWeight: pw.FontWeight.bold);
    pw.Widget heading(String text) => pw.Container(
          margin: const pw.EdgeInsets.only(top: 10, bottom: 8),
          padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          color: dark,
          child: pw.Text(text, style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
        );
    pw.Widget bullet(String text, {PdfColor color = teal, String mark = '•'}) => pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(width: 16, child: pw.Text(mark, style: pw.TextStyle(color: color, fontWeight: pw.FontWeight.bold))),
              pw.Expanded(child: pw.Text(text)),
            ],
          ),
        );
    pw.Widget sample(String title, List<String> headers, List<List<Object>> rows) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(title, style: bold),
            pw.SizedBox(height: 4),
            rtlTable(
              columns: [for (final h in headers) PdfColumn(h, flex: h == 'الاسم' ? 2.2 : 1)],
              rows: [
                for (final r in rows) [for (final c in r) '$c'],
              ],
              fontSize: 8.5,
            ),
          ],
        );

    final doc = pw.Document(theme: fonts.theme, title: 'تجهيز قائمة الأسعار للرفع');
    doc.addPage(pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(36, 30, 36, 30),
        textDirection: pw.TextDirection.rtl,
        theme: fonts.theme,
      ),
      footer: (c) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('تجهيز قائمة الأسعار - الإصدار $appVersion', style: const pw.TextStyle(fontSize: 8, color: grey)),
          pw.Text('صفحة ${c.pageNumber} من ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: grey)),
        ],
      ),
      build: (_) => [
        pw.Container(width: 50, height: 5, color: teal),
        pw.SizedBox(height: 8),
        pw.Text('تجهيز قائمة الأسعار للرفع على البرنامج',
            style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold, color: dark)),
        pw.Text('لمن يجهز ملفات الموردين في المحل. مع هذا الملف نموذجان جاهزان من Excel.',
            style: const pw.TextStyle(color: grey)),
        pw.SizedBox(height: 6),
        pw.Container(
          padding: const pw.EdgeInsets.all(8),
          color: soft,
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('النموذجان', style: bold),
            pw.Text('نموذج 1 - سعر واحد لكل سطر، مع عمود اللون إن وُجد.'),
            pw.Text('نموذج 2 - عمود سعر لكل لون، مثل قوائم Ideal Standard.'),
            pw.Text('امسح صفوف المثال واترك الصف الأول كما هو، ثم الصق أصناف المورد تحته.'),
          ]),
        ),
        heading('1. القواعد الأساسية'),
        for (final r in _rules) bullet(r),
        heading('2. الأعمدة'),
        rtlTable(
          columns: const [
            PdfColumn('اسم العمود', flex: 1.5),
            PdfColumn('مطلوب؟', flex: 1),
            PdfColumn('الشرح', flex: 4),
            PdfColumn('مثال', flex: 1),
          ],
          rows: [for (final r in _columns) r],
          fontSize: 9,
        ),
        heading('3. شكل الملف'),
        sample('نموذج 1: سعر واحد لكل سطر', _onePriceHeaders, _onePriceRows),
        pw.SizedBox(height: 10),
        sample('نموذج 2: عمود سعر لكل لون', _perColourHeaders, _perColourRows),
        pw.SizedBox(height: 4),
        pw.Text('في النموذج 2 يصبح كل لون سطراً بسعره. غطاء القاعدة ليس له سعر برجامون فلا يُضاف بهذا اللون.',
            style: const pw.TextStyle(fontSize: 9, color: grey)),
        pw.Text('الأكواد والأسعار في النموذجين أمثلة للشكل فقط.', style: const pw.TextStyle(fontSize: 9, color: grey)),
        heading('4. ما يتوقف للمراجعة ولا يُخمن'),
        for (final s in _stops) bullet(s, color: warn),
        pw.Text('باقي الملف يُحفظ عادي، والصفوف المتوقفة تظهر برقم صفها في تبويب "قيد المراجعة".'),
        heading('5. تحديث الأسعار'),
        for (final u in _update) bullet(u),
        heading('6. خطوات الرفع في البرنامج'),
        for (var i = 0; i < _steps.length; i++) bullet(_steps[i], mark: '${i + 1}.'),
        heading('7. قبل إرسال الملف'),
        for (final c in _checklist)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 5),
            child: pw.Row(children: [
              pw.Container(width: 11, height: 11, decoration: pw.BoxDecoration(border: pw.Border.all(color: dark))),
              pw.SizedBox(width: 8),
              pw.Expanded(child: pw.Text(c)),
            ]),
          ),
      ],
    ));
    final bytes = await doc.save();
    await File('docs/price_list_format_ar.pdf').writeAsBytes(bytes);
    expect(bytes.length, greaterThan(20000));
  });
}
