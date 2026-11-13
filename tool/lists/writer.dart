// Writes extracted rows as an upload file in the app's price list format.
import 'package:excel/excel.dart';

import 'engine.dart';

/// "24,645" -> 24645, "50,00" -> 50.00, "1.250" stays as printed decimals.
num? priceValue(String t) {
  final s = t.trim();
  if (RegExp(r'^\d+,\d{2}$').hasMatch(s)) return double.parse(s.replaceFirst(',', '.'));
  final n = s.replaceAll(',', '');
  return num.tryParse(n);
}

class Prepared {
  Prepared(this.rows, this.labels, this.notes);

  final List<Row> rows;
  final List<String> labels;
  final List<String> notes;
}

/// Merges rows printed twice and gives each code one row: the same code at
/// different prices (made-to-size items) gets its size added to the code.
Prepared prepare(List<Row> raw) {
  final notes = <String>[];
  final out = <Row>[];
  final byCode = <String, List<Row>>{};
  for (final r in raw) {
    final key = r.code.isEmpty ? 'name:${r.name}' : r.code.replaceAll(' ', '').toUpperCase();
    final same = byCode[key] ?? [];
    // Printed again under another series: the same prices where both have
    // them. One product, with every colour price it was printed with.
    final dup = same.where((o) => _compatible(o, r)).firstOrNull;
    if (dup != null) {
      for (final e in r.prices.entries) {
        dup.prices.putIfAbsent(e.key, () => e.value);
      }
      continue;
    }
    if (same.isNotEmpty) {
      final size = RegExp(r'(\d{2,4})\s*mm\.?$').firstMatch(r.nameEn)?.group(1) ??
          RegExp(r'(\d{2,4})\s*(سم|مم)').firstMatch(r.nameAr)?.group(1);
      final firstSize = RegExp(r'(\d{2,4})\s*mm\.?$').firstMatch(same.first.nameEn)?.group(1) ??
          RegExp(r'(\d{2,4})\s*(سم|مم)').firstMatch(same.first.nameAr)?.group(1);
      if (size != null && firstSize != null && size != firstSize) {
        if (!same.first.code.endsWith(' $firstSize') && r.code.isNotEmpty) same.first.code = '${same.first.code} $firstSize';
        r.code = '${r.code} $size';
        notes.add('الكود $key مطبوع لأكثر من مقاس بأسعار مختلفة: أضيف المقاس للكود (${r.code})');
      } else {
        r.code = r.code.isEmpty ? '' : '${r.code} (${same.length + 1})';
        r.issues.add('نفس الكود مطبوع بسعر مختلف في صفحة ${same.first.page}');
        notes.add('الكود $key مطبوع مرتين بسعرين مختلفين (صفحة ${same.first.page} و ${r.page}) — راجعه');
      }
    }
    byCode[key] = [...same, r];
    out.add(r);
  }
  final labels = <String>[];
  for (final r in out) {
    for (final l in r.prices.keys) {
      if (!labels.contains(l)) labels.add(l);
    }
  }
  return Prepared(out, labels, notes);
}

/// Same prices wherever both rows have a price for the same colour.
bool _compatible(Row a, Row b) {
  var shared = 0;
  for (final e in a.prices.entries) {
    final other = b.prices[e.key];
    if (other == null) continue;
    if (priceValue(other) != priceValue(e.value)) return false;
    shared++;
  }
  return shared > 0;
}

/// The upload file. One price column when the list has one price; else one
/// "سعر <لون>" column per colour, and "السعر" for the plain price.
List<int> writeUpload(Prepared p, {required String title, bool withArabic = true}) {
  final excel = Excel.createExcel();
  const sheetName = 'قائمة الأسعار';
  excel.rename(excel.getDefaultSheet()!, sheetName);
  final sheet = excel[sheetName];
  sheet.isRTL = true;
  final single = p.labels.length <= 1;
  final priceHeaders = single ? ['السعر'] : [for (final l in p.labels) l == 'السعر' ? 'السعر' : 'سعر $l'];
  final hasPack = p.rows.any((r) => (r.pack ?? '').isNotEmpty);
  final hasEn = p.rows.any((r) => r.nameEn.isNotEmpty);
  final headers = [
    'كود الشركة',
    if (hasEn) 'الاسم',
    if (withArabic || !hasEn) 'الاسم بالعربي',
    ...priceHeaders,
    if (hasPack) 'عدد الكرتونة',
    'صفحة المصدر',
  ];
  sheet.appendRow([for (final h in headers) TextCellValue(h)]);
  for (final r in p.rows) {
    CellValue? price(String label) {
      final v = priceValue(r.prices[label] ?? '');
      if (v == null) return null;
      return v is int ? IntCellValue(v) : DoubleCellValue(v.toDouble());
    }

    sheet.appendRow([
      TextCellValue(r.code),
      if (hasEn) TextCellValue(r.nameEn),
      if (withArabic || !hasEn) TextCellValue(r.nameAr),
      if (single) price(p.labels.isEmpty ? 'السعر' : p.labels.single) else for (final l in p.labels) price(l),
      if (hasPack) (r.pack ?? '').isEmpty ? null : IntCellValue(int.parse(r.pack!)),
      IntCellValue(r.page),
    ]);
  }
  for (var i = 0; i < headers.length; i++) {
    sheet.setColumnWidth(i, headers[i].startsWith('الاسم') ? 60 : 16);
  }
  return excel.encode()!;
}
