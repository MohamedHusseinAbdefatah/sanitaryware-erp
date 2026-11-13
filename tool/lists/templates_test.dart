// Writes the upload templates handed to the client, each with a sheet that
// explains every column, then fills a copy with sample rows and checks it with
// the app's own importer.
//
//   TEMPLATES_OUT=<folder> flutter test tool/lists/templates_test.dart
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/services/catalog_service.dart';
import 'package:sanitaryware_erp/core/services/expense_plan_service.dart';
import 'package:sanitaryware_erp/core/services/import_service.dart';
import 'package:sanitaryware_erp/core/services/price_list_import_service.dart';

import '../../test/support/fixture.dart';

/// One column: header, required?, what to write, an example.
typedef Col = (String header, String need, String what, String example);

class Template {
  const Template(this.file, this.sheet, this.where, this.cols, this.samples, {this.notes = const []});

  final String file;
  final String sheet;
  final String where;
  final List<Col> cols;
  final List<List<Object?>> samples;
  final List<String> notes;
}

const _req = 'مطلوب';
const _opt = 'اختياري';

final _codeCol = ('كود الشركة', 'مطلوب إن وُجد',
    'كود المصنع كما في قائمة الشركة، حرفياً بالمسافات والنقاط. اكتبه كنص (عمود منسق "نص") حتى لا تضيع الأصفار في أوله.',
    '0050680000');
final _masterCols = <Col>[
  ('التصنيف', _opt, 'للأصناف الجديدة فقط: التصنيف الرئيسي. يُنشأ إن لم يكن موجوداً.', 'أطقم حمامات'),
  ('التصنيف الفرعي', _opt, 'للأصناف الجديدة فقط.', 'قواعد'),
  ('السلسلة', _opt, 'اسم الموديل / السلسلة.', 'D-Neo'),
  ('المقاسات', _opt, 'كما في القائمة.', '650 x 370 mm'),
  ('التشطيب', _opt, 'لامع، مطفي، كروم...', 'لامع'),
  ('الوحدة', _opt, 'من وحدات البرنامج: قطعة، كرتونة، طقم، متر. فارغ = قطعة.', 'قطعة'),
  ('الباركود', _opt, 'كنص.', '4021534567890'),
];

final templates = <Template>[
  Template(
    'نموذج 1 - قائمة أسعار (سعر واحد لكل صف).xlsx',
    'قائمة الأسعار',
    'قوائم الأسعار ← استيراد قائمة كاملة (إصدار جديد) — اختر المورد والماركة أولاً',
    [
      _codeCol,
      ('الاسم', 'مطلوب (هو أو الاسم بالعربي)', 'اسم الصنف كما في قائمة الشركة (غالباً إنجليزي).', 'D-Neo washbasin 650 mm'),
      ('الاسم بالعربي', _opt, 'الاسم العربي. يُستخدم اسماً للصنف الجديد، ويكمّل الاسم العربي لصنف موجود بلا اسم عربي.', 'حوض دي نيو 65 سم'),
      ('اللون', _opt, 'لون هذا السعر. صنف له سعران بلونين = صفان بنفس الكود، لكل صف لونه.', 'أبيض'),
      ('السعر', _req, 'سعر القائمة بالجنيه كرقم فقط، بدون "ج" أو عملة. 2,400 و 2400 مقبولان، و 50,25 تعني خمسين وربع.', '2400'),
      ('عدد الكرتونة', _opt, 'عدد القطع في الكرتونة، رقم صحيح.', '6'),
      ..._masterCols,
    ],
    [
      ['2366650000', 'D-Neo washbasin 650 mm', 'حوض دي نيو 65 سم', 'أبيض', 7850, 1, 'أحواض', 'أحواض معلقة', 'D-Neo', '650 x 480 mm', 'لامع', 'قطعة', ''],
      ['2366650000', 'D-Neo washbasin 650 mm', 'حوض دي نيو 65 سم', 'أسود', '8,900', 1, 'أحواض', 'أحواض معلقة', 'D-Neo', '650 x 480 mm', 'مطفي', 'قطعة', ''],
      ['', 'خلاط حوض أرموس موديل 10', 'خلاط حوض أرموس موديل 10', '', '1250,50', 12, '', '', '', '', '', '', ''],
    ],
    notes: [
      'صف واحد لكل سعر. إن كان للصنف أكثر من لون بأسعار مختلفة فاكتب صفاً لكل لون بنفس الكود، أو استخدم النموذج 2.',
      'لا تكرر نفس الكود بنفس اللون في الملف: يتوقف الصف للمراجعة ولا يُخمَّن أيهما الصحيح.',
      'القوائم بدون أكواد (مثل أرموس والأصيل): اترك كود الشركة فارغاً، ويُتعرف على الصنف بالاسم حرفياً، فاكتب الاسم بنفس الطريقة في كل مرة.',
      'كل ملف يُرفع يصبح إصداراً جديداً من القائمة بتاريخ سريان؛ الإصدارات القديمة تبقى في السجل.',
    ],
  ),
  Template(
    'نموذج 2 - قائمة أسعار (عمود سعر لكل لون).xlsx',
    'قائمة الأسعار',
    'قوائم الأسعار ← استيراد قائمة كاملة (إصدار جديد) — اختر المورد والماركة أولاً',
    [
      _codeCol,
      ('الاسم', 'مطلوب (هو أو الاسم بالعربي)', 'اسم الصنف كما في قائمة الشركة.', 'Starck 3 toilet'),
      ('الاسم بالعربي', _opt, 'الاسم العربي.', 'قاعدة ستارك 3'),
      ('سعر أبيض', 'عمود سعر واحد على الأقل',
          'كل عمود عنوانه "سعر " ثم اسم اللون. أضف أو احذف أعمدة الألوان حسب القائمة (سعر برجامون، سعر ألوان، سعر كروم...).', '5200'),
      ('سعر برجامون', _opt, 'خانة فارغة = الصنف لا يُصنع بهذا اللون؛ لا يُسجل له سعر.', '5650'),
      ('سعر ألوان', _opt, 'نفس القاعدة.', ''),
      ('عدد الكرتونة', _opt, 'رقم صحيح.', '1'),
      ..._masterCols,
    ],
    [
      ['2128090000', 'Starck 3 toilet', 'قاعدة ستارك 3', 5200, 5650, null, 1, '', '', '', '', '', '', ''],
      ['0050680000', 'Shelf 600 mm', 'رف 60 سم', 980, null, '1,150', null, '', '', '', '', '', '', ''],
    ],
    notes: [
      'اسم اللون في العنوان هو نفسه لون الصنف في البرنامج، فاكتبه بنفس الطريقة في كل القوائم (أبيض وليس ابيض مرة وWhite مرة).',
      'استخدم عموداً واحداً باسم "السعر" بدلاً من أعمدة الألوان إذا كان للصنف سعر واحد.',
    ],
  ),
  Template(
    'نموذج 3 - الأصناف ورصيد أول المدة.xlsx',
    'الأصناف',
    'الإعدادات ← الاستيراد ← الأصناف (للمدير فقط) — مرة واحدة عند بدء العمل',
    [
      ('الكود', _req, 'كود الصنف عندك في المحل (الكود الداخلي). لا يتكرر، ولا يكون موجوداً في البرنامج من قبل. اكتبه كنص.', 'DR-1001'),
      ('كود الشركة', _opt, 'كود المصنع، حتى تُربط به أسعار قوائم الشركة فيما بعد.', '2366650000'),
      ('اسم الصنف', _req, 'الاسم العربي للصنف.', 'حوض دي نيو 65 سم أبيض'),
      ('التصنيف', _opt, 'يُنشأ إن لم يكن موجوداً.', 'أحواض'),
      ('الماركة', _opt, 'تُنشأ إن لم تكن موجودة. اكتبها بنفس الطريقة دائماً.', 'Duravit'),
      ('الوحدة', _opt, 'قطعة، كرتونة، طقم، متر. فارغ = قطعة. المتر وحده يقبل الكسور.', 'قطعة'),
      ('اللون', _opt, 'لون الصنف.', 'أبيض'),
      ('حد الطلب', _opt, 'الكمية التي يُنبَّه عندها لإعادة الطلب.', '2'),
      ('رصيد أول المدة', _opt, 'الكمية الموجودة فعلاً في المخزن يوم البدء.', '5'),
      ('تكلفة رصيد أول المدة', 'مطلوب إذا كتبت رصيداً',
          'تكلفة شراء القطعة الواحدة الفعلية (ليست سعر القائمة ولا سعر البيع). لا يفترض البرنامج تكلفة من عنده.', '6280'),
    ],
    [
      ['DR-1001', '2366650000', 'حوض دي نيو 65 سم أبيض', 'أحواض', 'Duravit', 'قطعة', 'أبيض', 2, 5, 6280],
      ['PL-2001', '', 'ماسورة 4 بوصة', 'سباكة', 'بلازا', 'متر', '', 20, '12.5', 85],
    ],
    notes: [
      'هذا الملف للبداية فقط: الأصناف الجديدة فيما بعد تأتي من قوائم الأسعار (النموذج 1 و2) أو تُضاف من شاشة الأصناف.',
      'صف فيه خطأ لا يُحفظ، ويظهر سببه في المعاينة؛ صحّحه في الملف وارفعه مرة أخرى.',
    ],
  ),
  Template(
    'نموذج 4 - العملاء.xlsx',
    'العملاء',
    'الإعدادات ← الاستيراد ← العملاء (للمدير فقط)',
    [
      ('اسم العميل', _req, 'لا يتكرر، ولا يكون موجوداً في البرنامج من قبل.', 'م. أحمد سامي'),
      ('التليفون', _opt, 'اكتبه كنص حتى يبقى الصفر في أوله (البرنامج يعيده إن ضاع).', '01001234567'),
      ('العنوان', _opt, '', 'المعادي - القاهرة'),
      ('رصيد أول المدة', _opt, 'ما على العميل لك يوم البدء بالجنيه. اكتبه سالباً إذا كان له عندك (دفع مقدماً).', '15000'),
      ('حد الائتمان', _opt, 'أقصى مبلغ آجل مسموح له. فارغ = بلا حد.', '50000'),
      ('فئة العميل', _opt, 'من فئات البرنامج: قطاعي، جملة، مقاولين، أو فئة أضفتها. فارغ = قطاعي.', 'مقاولين'),
    ],
    [
      ['م. أحمد سامي', '01001234567', 'المعادي - القاهرة', 15000, 50000, 'مقاولين'],
      ['معرض النور', '', '', '-2500', '', 'جملة'],
    ],
  ),
  Template(
    'نموذج 5 - الموردون.xlsx',
    'الموردون',
    'الإعدادات ← الاستيراد ← الموردون (للمدير فقط)',
    [
      ('اسم المورد', _req, 'لا يتكرر، ولا يكون موجوداً في البرنامج من قبل.', 'الشركة المصرية للأدوات الصحية'),
      ('التليفون', _opt, 'كنص.', '0223456789'),
      ('العنوان', _opt, '', 'العاشر من رمضان'),
      ('رصيد أول المدة', _opt, 'ما عليك للمورد يوم البدء بالجنيه. سالب إذا كان لك عنده (دفعة مقدمة).', '120000'),
    ],
    [
      ['الشركة المصرية للأدوات الصحية', '0223456789', 'العاشر من رمضان', 120000],
    ],
  ),
  Template(
    'نموذج 6 - المصروفات.xlsx',
    'المصروفات',
    'المصروفات ← استيراد من Excel',
    [
      ('التاريخ', _req, 'يوم المصروف: 2026/01/31 أو 31/01/2026، أو خلية تاريخ في Excel. لا يُقبل تاريخ في المستقبل.', '2026/01/31'),
      ('البند', _req, 'بند المصروف. يُنشأ إن لم يكن موجوداً، فاكتبه بنفس الطريقة دائماً.', 'إيجار'),
      ('المبلغ', _req, 'بالجنيه، أكبر من صفر.', '15000'),
      ('الطريقة', _opt, 'نقدي، أو بنك / تحويل. فارغ = نقدي.', 'نقدي'),
      ('البيان', _opt, 'وصف قصير.', 'إيجار يناير'),
    ],
    [
      ['2026/01/31', 'إيجار', 15000, 'نقدي', 'إيجار يناير'],
      ['05/02/2026', 'كهرباء', '1,850', 'تحويل بنكي', ''],
    ],
    notes: ['مصروف بنفس التاريخ والبند والمبلغ مسجل من قبل يُعلَّم مكرراً ولا يُسجل مرتين.'],
  ),
];

const _general = [
  'لا تغيّر عناوين الأعمدة ولا تحذف الصف الأول. يمكنك ترتيب الأعمدة كما تشاء أو حذف عمود اختياري لا تحتاجه.',
  'البيانات في أول ورقة من الملف فقط. ورقة "طريقة الملء" للشرح ولا تُقرأ.',
  'لا خلايا مدمجة، ولا صفوف عناوين أو مجاميع بين البيانات، ولا معادلات تشير لملفات أخرى.',
  'احفظ الملف بصيغة Excel ‏(.xlsx). ملفات ‎.xls القديمة و‎.csv لا تُقبل: افتحها واحفظها باسم ‎.xlsx.',
  'قبل الحفظ النهائي يعرض البرنامج معاينة لكل صف: يُستورد، صنف جديد، أو متوقف للمراجعة مع السبب. لا شيء يُحفظ قبل أن توافق.',
];

CellValue? _cell(Object? v) => switch (v) {
      null => null,
      int i => IntCellValue(i),
      double d => DoubleCellValue(d),
      _ => TextCellValue('$v'),
    };

List<int> _write(Template t, {required bool withSamples}) {
  final excel = Excel.createExcel();
  excel.rename(excel.getDefaultSheet()!, t.sheet);
  final data = excel[t.sheet]..isRTL = true;
  final head = CellStyle(bold: true, backgroundColorHex: ExcelColor.fromHexString('#DDEBF7'));
  data.appendRow([for (final c in t.cols) TextCellValue(c.$1)]);
  for (var i = 0; i < t.cols.length; i++) {
    data.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0)).cellStyle = head;
    data.setColumnWidth(i, t.cols[i].$1.startsWith('الاسم') || t.cols[i].$1.startsWith('اسم') ? 40 : 18);
  }
  if (withSamples) {
    for (final s in t.samples) {
      data.appendRow([for (final v in s) _cell(v)]);
    }
  }

  final help = excel['طريقة الملء']..isRTL = true;
  help.appendRow([TextCellValue(t.file.replaceAll('.xlsx', ''))]);
  help.appendRow([TextCellValue('أين يُرفع: ${t.where}')]);
  help.appendRow([]);
  help.appendRow([for (final h in ['العمود', 'مطلوب؟', 'ماذا تكتب', 'مثال']) TextCellValue(h)]);
  for (var i = 0; i < 4; i++) {
    help.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 3)).cellStyle = head;
  }
  for (final c in t.cols) {
    help.appendRow([TextCellValue(c.$1), TextCellValue(c.$2), TextCellValue(c.$3), TextCellValue(c.$4)]);
  }
  help.appendRow([]);
  help.appendRow([TextCellValue('مثال مملوء:')]);
  help.appendRow([for (final c in t.cols) TextCellValue(c.$1)]);
  for (final s in t.samples) {
    help.appendRow([for (final v in s) v == null ? null : TextCellValue('$v')]);
  }
  help.appendRow([]);
  help.appendRow([TextCellValue('قواعد مهمة:')]);
  for (final n in [...t.notes, ..._general]) {
    help.appendRow([TextCellValue('• $n')]);
  }
  help.setColumnWidth(0, 24);
  help.setColumnWidth(1, 22);
  help.setColumnWidth(2, 90);
  help.setColumnWidth(3, 26);
  return excel.encode()!;
}

void main() {
  test('templates', () async {
    final out = Directory(Platform.environment['TEMPLATES_OUT']!)..createSync(recursive: true);
    for (final t in templates) {
      File('${out.path}/${t.file}').writeAsBytesSync(_write(t, withSamples: false));

      // The same template with its sample rows must pass the app's importer.
      final bytes = _write(t, withSamples: true);
      final shop = await Shop.open();
      await CatalogService(shop.db).seedDefaultUnits();
      final String problems;
      if (t.file.contains('قائمة أسعار')) {
        final p = await PriceListImportService(shop.db).preview(bytes, brandId: shop.brandId);
        expect(p.missingColumns, isEmpty, reason: t.file);
        problems = p.rows.where((r) => !r.ok).map((r) => '${r.rowNumber}: ${r.reviewReason}').join(' | ');
        final expected = t.samples.fold(0, (s, r) => s + (t.file.contains('لكل لون') ? r.sublist(3, 6).where((v) => v != null).length : 1));
        expect(p.rows.length, expected, reason: t.file);
      } else if (t.file.contains('المصروفات')) {
        final rows = await ExpensePlanService(shop.db).preview(bytes);
        problems = rows.where((r) => !r.ok).map((r) => r.problems.join('، ')).join(' | ');
        expect(rows.length, t.samples.length, reason: t.file);
      } else {
        final kind = t.file.contains('الأصناف')
            ? ImportKind.products
            : t.file.contains('العملاء')
                ? ImportKind.customers
                : ImportKind.suppliers;
        final p = await ImportService(shop.db).preview(kind, bytes);
        expect(p.missingColumns, isEmpty, reason: t.file);
        problems = p.rows.where((r) => !r.ok).map((r) => '${r.rowNumber}: ${r.errors.join('، ')}').join(' | ');
        expect(p.rows.length, t.samples.length, reason: t.file);
      }
      await shop.close();
      expect(problems, isEmpty, reason: t.file);
      // ignore: avoid_print
      print('OK ${t.file}');
    }
  });
}
