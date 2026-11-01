// Builds the short Arabic user guide, docs/user_guide_ar.pdf, from the
// screenshots in docs/screenshots (make them first):
//
//   flutter test tool/docs/screenshots_test.dart
//   flutter test tool/docs/user_guide_test.dart
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:sanitaryware_erp/core/printing/pdf_fonts.dart';
import 'package:sanitaryware_erp/core/printing/pdf_widgets.dart';
import 'package:sanitaryware_erp/core/version.dart';

class _Section {
  const _Section(this.title, this.steps, this.screenshots, {this.who});

  final String title;
  final List<String> steps;
  final List<String> screenshots;

  /// Who can use it, when not everyone.
  final String? who;
}

const _sections = [
  _Section('تشغيل البرنامج وتسجيل الدخول', [
    'افتح البرنامج من أيقونة «إدارة الأدوات الصحية» على سطح المكتب.',
    'اكتب اسم المستخدم وكلمة المرور ثم اضغط Enter.',
    'المدير يرى كل الشاشات. الكاشير يرى البيع والعملاء والمدفوعات والمرتجعات فقط، ولا يرى سعر التكلفة.',
    'عند الانتهاء اضغط زر الخروج أسفل القائمة. عند إغلاق البرنامج تُحفظ نسخة احتياطية تلقائياً.',
  ], ['01_login']),
  _Section('لوحة التحكم', [
    'تعرض مبيعات اليوم، والمقبوض اليوم، والأصناف تحت حد الطلب، والشيكات المستحقة خلال أسبوع، وأكثر العملاء مديونية.',
    'اضغط أي مربع لفتح الشاشة الخاصة به.',
    'الشريط الأحمر يعني أن النسخة الاحتياطية الخارجية غير موجودة أو قديمة: عالجه فوراً من الإعدادات.',
  ], ['02_dashboard']),
  _Section('الأصناف والمخزون', [
    'ابحث بالكود أو الاسم. البحث لا يفرق بين (أ، إ، ا) ولا بين (ة، ه) ولا بين (ى، ي).',
    'الرصيد باللون الأحمر يعني أن الصنف وصل إلى حد الطلب.',
    'صنف جديد (للمدير): الكود، الاسم، الوحدة، أسعار القطاعي والجملة والمقاولين، حد الطلب، ورصيد أول المدة.',
    'الوحدات التي تقبل الكسور (مثل المتر) فقط تسمح بكميات مثل 12.5.',
    'من زر النقاط الثلاث بجانب الصنف: تعديل، تسوية رصيد (مع ذكر السبب)، وكارت الصنف بكل حركاته.',
  ], ['03_products']),
  _Section('فاتورة بيع جديدة', [
    'فواتير البيع ثم فاتورة جديدة.',
    'اختر العميل، أو اتركه فارغاً للبيع النقدي. السعر يتبع فئة العميل (قطاعي، جملة، مقاولين).',
    'اكتب كود أو اسم الصنف ثم Enter لإضافته، ثم اكتب الكمية. مفتاح F2 يرجعك لخانة البحث.',
    'يمكن تعديل السعر والخصم لكل سطر، ووضع خصم على الفاتورة كلها.',
    'المدفوع الآن: في البيع النقدي يُملأ بالإجمالي تلقائياً. مع العميل اكتب ما دفعه، والباقي يضاف إلى رصيده.',
    'للحفظ اضغط Ctrl+S',
    'للحفظ والطباعة معاً اضغط Ctrl+P',
    'تنبيهات: الكمية أكبر من المتاح، السعر أقل من التكلفة (للمدير)، وتجاوز حد الائتمان (الكاشير لا يستطيع التجاوز).',
  ], ['04_sale_entry']),
  _Section('عرض الفاتورة واستلام دفعة', [
    'من الفاتورة: طباعة، استلام دفعة، مرتجع بيع، وإلغاء الفاتورة (للمدير مع ذكر السبب).',
    'الفاتورة بعد حفظها لا تُعدل. الخطأ يُصحح بإلغائها وإدخالها من جديد، وتعود الكميات والأرصدة تلقائياً.',
    'استلام دفعة: تظهر الفاتورة والمبلغ المتبقي عليها. اختر نقدي أو تحويل بنكي أو شيك (رقم الشيك والبنك وتاريخ الاستحقاق).',
    'الدفعة بدون ربط بفاتورة تُسجل «تحت الحساب» وتخصم من رصيد العميل.',
  ], ['05_sale_view', '06_receive_payment']),
  _Section('العملاء وكشف الحساب', [
    'رصيد العميل يُحسب تلقائياً من الفواتير والمدفوعات والمرتجعات، ولا يُكتب يدوياً.',
    'من زر النقاط الثلاث بجانب العميل ثم كشف حساب: اختر الفترة، ثم طباعة أو تصدير Excel.',
    'الشيكات تحت التحصيل تظهر أسفل الكشف، ولا تُخصم من الرصيد حتى تُصرف.',
    'الموردون بنفس الطريقة (للمدير).',
  ], ['07_customers', '08_statement']),
  _Section('الشيكات', [
    'المدفوعات والشيكات ثم الشيكات: كل شيك وتاريخ استحقاقه، والمستحق اليوم أو قبله ملون.',
    'المدير يضغط زر النقاط الثلاث ثم تم الصرف، أو شيك مرتد (فيرجع المبلغ على العميل).',
  ], ['09_cheques']),
  _Section('المرتجعات', [
    'من الفاتورة ثم مرتجع بيع، أو من شاشة المرتجعات بكتابة رقم الفاتورة الأصلية.',
    'يظهر لكل صنف الكمية التي يمكن إرجاعها. اكتب الكمية المرتجعة فقط.',
    'المردود نقداً اختياري، والباقي يُخصم من رصيد العميل.',
    'مرتجع الشراء إلى المورد للمدير فقط.',
  ], ['10_return']),
  _Section('التقارير', [
    'اختر التقرير من القائمة، ثم الفترة (اليوم، هذا الشهر، ...).',
    'كل تقرير له إجمالي في آخره، وزر طباعة وزر تصدير Excel.',
    'تقرير الأرباح = صافي المبيعات − تكلفة البضاعة المباعة − المصروفات.',
  ], ['11_reports'], who: 'للمدير فقط'),
  _Section('الإعدادات والنسخ الاحتياطي', [
    'يحفظ البرنامج نسخة احتياطية عند كل إغلاق، ويحتفظ بآخر 10 نسخ.',
    'اختر مجلداً خارجياً (فلاشة أو مجلد سحابي) لتُنسخ إليه كل نسخة. البيانات على هذا الجهاز فقط.',
    'للاستعادة: اختر النسخة ثم استعادة. يحفظ البرنامج نسخة من الوضع الحالي أولاً، ثم يعيد التشغيل.',
    'من الإعدادات أيضاً: بيانات المحل والشعار، صفحة طباعة تجريبية، المستخدمون، الاستيراد من Excel، وسجل العمليات.',
  ], ['12_settings'], who: 'للمدير فقط'),
];

const _shortcuts = [
  ['Enter', 'إضافة الصنف المختار إلى الفاتورة'],
  ['F2', 'الرجوع إلى خانة البحث عن صنف'],
  ['Ctrl+S', 'حفظ الفاتورة أو المرتجع'],
  ['Ctrl+P', 'حفظ فاتورة البيع وطباعتها'],
];

const _emergency = [
  ('البرنامج يقول إن ملف البيانات به مشكلة', 'اختر آخر نسخة احتياطية سليمة ثم استعادة. الملف التالف يُحفظ في مجلد النسخ باسم يبدأ بكلمة damaged، فلا تحذفه وأرسله للمطور.'),
  ('أدخلت بيانات خطأ', 'المدير يلغي الفاتورة أو الدفعة مع ذكر السبب. للرجوع لحالة سابقة كاملة: الإعدادات ثم النسخ الاحتياطي ثم استعادة.'),
  ('الجهاز تعطل أو تغير', 'ثبّت البرنامج على الجهاز الجديد، أنشئ حساباً مؤقتاً، ثم الإعدادات ثم استعادة من ملف ثم آخر نسخة من الفلاشة.'),
  ('نسيت كلمة المرور', 'مدير آخر يغيرها من الإعدادات ثم المستخدمون. إن لم يوجد، تواصل مع المطور.'),
  ('الطباعة غير سليمة', 'الإعدادات ثم الطباعة ثم طباعة صفحة تجريبية، واختر الطابعة الصحيحة ومقاس A4.'),
];

void main() {
  test('build docs/user_guide_ar.pdf', () async {
    ByteData font(String name) => ByteData.sublistView(File('assets/fonts/$name').readAsBytesSync());
    final fonts = PdfFonts.fromBytes(regular: font('Cairo-Regular.ttf'), bold: font('Cairo-Bold.ttf'));

    // A PDF has no font fallback: a character Cairo lacks prints as a box.
    final glyphs = TtfParser(font('Cairo-Regular.ttf')).charToGlyphIndexMap;
    final allText = [
      for (final s in _sections) ...[s.title, ...s.steps, s.who ?? ''],
      for (final s in _shortcuts) ...s,
      for (final (a, b) in _emergency) ...[a, b],
    ].join();
    final missing = {for (final r in allText.runes) if (r > 32 && !glyphs.containsKey(r)) String.fromCharCode(r)};
    expect(missing, isEmpty, reason: 'Cairo has no glyph for: ${missing.join(' ')}');
    Uint8List shot(String name) => File('docs/screenshots/$name.png').readAsBytesSync();

    final bold = pw.TextStyle(fontWeight: pw.FontWeight.bold);
    final doc = pw.Document(theme: fonts.theme, title: 'دليل استخدام إدارة الأدوات الصحية');
    final pageTheme = pw.PageTheme(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 32, 36, 32),
      textDirection: pw.TextDirection.rtl,
      theme: fonts.theme,
    );

    // Cover.
    doc.addPage(pw.Page(
      pageTheme: pageTheme,
      build: (_) => pw.Column(
        mainAxisAlignment: pw.MainAxisAlignment.center,
        children: [
          pw.Text('إدارة الأدوات الصحية', style: pw.TextStyle(fontSize: 34, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          pw.Text('دليل الاستخدام المختصر', style: const pw.TextStyle(fontSize: 22)),
          pw.SizedBox(height: 4),
          pw.Text('الإصدار $appVersion'),
          pw.SizedBox(height: 40),
          pw.Container(
            width: 380,
            padding: const pw.EdgeInsets.all(14),
            decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey500)),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('المحتويات', style: bold),
                pw.SizedBox(height: 6),
                for (var i = 0; i < _sections.length; i++) pw.Text('${i + 1}. ${_sections[i].title}'),
                pw.Text('${_sections.length + 1}. اختصارات لوحة المفاتيح'),
                pw.Text('${_sections.length + 2}. إذا حدثت مشكلة'),
              ],
            ),
          ),
        ],
      ),
    ));

    doc.addPage(pw.MultiPage(
      pageTheme: pageTheme,
      maxPages: 100,
      footer: (context) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('دليل الاستخدام — الإصدار $appVersion', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
          pw.Text('صفحة ${context.pageNumber}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
        ],
      ),
      build: (_) => [
        for (var i = 0; i < _sections.length; i++) ...[
          // One section per page keeps each text next to its screenshot.
          if (i > 0) pw.NewPage(),
          pw.Header(
            level: 1,
            child: pw.Row(
              children: [
                pw.Text('${i + 1}. ${_sections[i].title}', style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
                if (_sections[i].who != null) ...[
                  pw.SizedBox(width: 10),
                  pw.Text('(${_sections[i].who})', style: const pw.TextStyle(color: PdfColors.grey700)),
                ],
              ],
            ),
          ),
          for (final step in _sections[i].steps)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 3),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [pw.Text('•  '), pw.Expanded(child: pw.Text(step))],
              ),
            ),
          pw.SizedBox(height: 8),
          for (final s in _sections[i].screenshots) ...[
            pw.Container(
              decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400, width: 0.5)),
              child: pw.Image(pw.MemoryImage(shot(s)), fit: pw.BoxFit.contain),
            ),
            pw.SizedBox(height: 10),
          ],
          pw.SizedBox(height: 6),
        ],
        pw.Header(
          level: 1,
          child: pw.Text('${_sections.length + 1}. اختصارات لوحة المفاتيح',
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
        ),
        rtlTable(
          columns: const [PdfColumn('المفتاح', flex: 1, numeric: true), PdfColumn('ما يفعله', flex: 4)],
          rows: _shortcuts,
          fontSize: 11,
        ),
        pw.NewPage(),
        pw.Header(
          level: 1,
          child: pw.Text('${_sections.length + 2}. إذا حدثت مشكلة',
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
        ),
        pw.Text('البيانات موجودة على هذا الجهاز فقط. النسخة على الفلاشة أو المجلد السحابي هي مسؤولية المحل.', style: bold),
        pw.SizedBox(height: 10),
        for (final (problem, fix) in _emergency)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 8),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [pw.Text(problem, style: bold), pw.Text(fix)],
            ),
          ),
        pw.SizedBox(height: 10),
        pw.Text('مكان البيانات:', style: bold),
        // A path reads left to right; inside Arabic text its symbols get moved.
        pw.Directionality(
          textDirection: pw.TextDirection.ltr,
          child: pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(r'%APPDATA%\com.erp\sanitaryware_erp\SanitarywareERP'),
          ),
        ),
        pw.SizedBox(height: 20),
        pw.Text('التواصل مع المطور: ................................   التليفون: ................................'),
      ],
    ));

    final bytes = await doc.save();
    await File('docs/user_guide_ar.pdf').writeAsBytes(bytes);
    expect(bytes.length, greaterThan(100000));
  });
}
