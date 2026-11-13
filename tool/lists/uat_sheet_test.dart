// UAT_JSON=<uat.json> UAT_OUT=<xlsx>: the acceptance checklist as a workbook
// to tick during the demo, one sheet for the blueprint match and one for the
// test cases.
library;

import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uat sheet', () {
    final d = jsonDecode(File(Platform.environment['UAT_JSON']!).readAsStringSync()) as Map<String, dynamic>;
    final excel = Excel.createExcel();
    final head = CellStyle(bold: true, backgroundColorHex: ExcelColor.fromHexString('#DDEBF7'), textWrapping: TextWrapping.WrapText);
    final wrap = CellStyle(textWrapping: TextWrapping.WrapText, verticalAlign: VerticalAlign.Top);
    void rows(Sheet s, List<String> h, List<List<String>> body, List<double> widths) {
      s.isRTL = true;
      s.appendRow([for (final x in h) TextCellValue(x)]);
      for (var i = 0; i < h.length; i++) {
        s.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0)).cellStyle = head;
        s.setColumnWidth(i, widths[i]);
      }
      for (final (r, b) in body.indexed) {
        s.appendRow([for (final x in b) TextCellValue(x)]);
        for (var i = 0; i < b.length; i++) {
          s.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: r + 1)).cellStyle = wrap;
        }
      }
    }

    const status = {'done': 'مكتمل', 'partial': 'جزئي', 'missing': 'غير موجود', 'excluded': 'مستبعد باتفاق'};
    excel.rename(excel.getDefaultSheet()!, 'حالات الاختبار');
    final cases = <List<String>>[];
    for (final m in d['modules'] as List) {
      for (final (i, c) in (m['cases'] as List).indexed) {
        cases.add([
          '${m['id']}-${'${i + 1}'.padLeft(2, '0')}',
          m['name'] as String,
          c['t'] as String,
          c['s'] as String,
          c['e'] as String,
          '',
          '',
          c['a'] == null ? '' : 'test/core/${c['a']}.dart',
        ]);
      }
    }
    rows(excel['حالات الاختبار'], ['الرقم', 'الموديول', 'الحالة', 'الخطوات', 'النتيجة المتوقعة', 'النتيجة (نجح / فشل)', 'ملاحظات العميل', 'اختبار آلي'],
        cases, [10, 22, 22, 45, 50, 14, 30, 30]);
    rows(excel['المطابقة مع الوثيقة'], ['البند', 'المتطلب', 'الحالة', 'ما يقدمه البرنامج', 'الناقص أو المختلف'], [
      for (final g in d['gaps'] as List)
        [g['sec'] as String, g['title'] as String, status[g['status']]!, g['has'] as String, g['gap'] as String]
    ], [8, 36, 14, 60, 50]);
    rows(excel['السيناريو المتكامل'], ['الخطوة', 'ماذا نفعل', 'ماذا نرى'], [
      for (final s in d['e2e'] as List) [s['step'] as String, s['do'] as String, s['see'] as String]
    ], [16, 60, 60]);
    rows(excel['السيناريوهات'], ['الموديول', 'السيناريو', 'الخطوة'], [
      for (final m in d['modules'] as List)
        for (final (i, s) in ((m['story'] as Map)['steps'] as List).indexed)
          [i == 0 ? m['name'] as String : '', i == 0 ? (m['story'] as Map)['title'] as String : '', '${i + 1}. $s']
    ], [26, 24, 90]);
    File(Platform.environment['UAT_OUT']!).writeAsBytesSync(excel.encode()!);
    expect(cases.length, greaterThan(90));
  });
}
