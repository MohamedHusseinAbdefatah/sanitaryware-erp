// Converts the supplier price lists in a folder into upload files, then
// checks every file with the app's own importer.
//
//   LISTS_SRC=<folder> LISTS_OUT=<folder> flutter test tool/lists/convert_test.dart
@Timeout(Duration(minutes: 60))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/pdf_import/pdf_reader.dart';
import 'package:sanitaryware_erp/core/services/price_list_import_service.dart';

import '../../test/support/fixture.dart';
import 'configs.dart';
import 'engine.dart';
import 'pdf_text.dart';
import 'writer.dart';

class Job {
  const Job(this.pdf, this.out, this.cfg, {this.withArabic = true});

  final String pdf;
  final String out;
  final Cfg cfg;
  final bool withArabic;
}

final jobs = <Job>[
  Job('Duravit Ceramic PL 50 June 2026.pdf', 'Duravit - Ceramics PL50 - June 2026', duravit),
  Job('Ceramic PL_51 August_2026.pdf', 'Duravit - Ceramics PL51 - August 2026', duravit),
  Job('Duravit Bathtubs PL_41 Jan_2026.pdf', 'Duravit - Bathtubs PL41 - January 2026', duravitBath),
];

void main() {
  test('convert', () async {
    PdfTextReader.useModule('${Directory.current.path}/build/windows/x64/runner/Release/pdfium.dll');
    final src = Platform.environment['LISTS_SRC']!;
    final out = Directory(Platform.environment['LISTS_OUT']!)..createSync(recursive: true);
    final only = Platform.environment['ONLY'];
    final report = StringBuffer();
    for (final j in jobs) {
      if (only != null && !j.out.contains(only)) continue;
      final pages = await readPdfWords(File('$src/${j.pdf}'));
      final raw = extract(pages, j.cfg);
      final left = orphans(pages, j.cfg, raw);
      final p = prepare(raw);
      final bytes = writeUpload(p, title: j.out, withArabic: j.withArabic);
      File('${out.path}/${j.out}.xlsx').writeAsBytesSync(bytes);

      // The app's importer must read every row, with nothing stopped.
      final shop = await Shop.open();
      final preview = await PriceListImportService(shop.db).preview(bytes, brandId: shop.brandId);
      await shop.close();
      final stopped = preview.rows.where((r) => !r.ok).toList();
      final priceCount = p.rows.fold(0, (s, r) => s + r.prices.length);
      report
        ..writeln('## ${j.out}')
        ..writeln('المصدر: ${j.pdf} — ${pages.length} صفحة — كلمات تحت نص مطبوع فوقها (مستبعدة): $overpainted — كلمات مخفية بلا حبر (مستبعدة): $invisible')
        ..writeln('أصناف: ${p.rows.length} — أسعار: $priceCount — أعمدة: ${p.labels.join('، ')}')
        ..writeln('المستورد يقرأ: ${preview.rows.length} سطر سعر، أوقف منها: ${stopped.length}'
            '${preview.missingColumns.isEmpty ? '' : ' — أعمدة ناقصة: ${preview.missingColumns}'}');
      for (final s in stopped.take(30)) {
        report.writeln('  أوقف: سطر ${s.rowNumber} ${s.code} — ${s.reviewReason}');
      }
      for (final n in p.notes) {
        report.writeln('  ملاحظة: $n');
      }
      for (final r in p.rows.where((r) => r.issues.isNotEmpty)) {
        report.writeln('  مراجعة: صفحة ${r.page} ${r.code}: ${r.issues.join('؛ ')}');
      }
      for (final o in left) {
        report.writeln('  لم يُقرأ: $o');
      }
      report.writeln();
      expect(preview.missingColumns, isEmpty, reason: j.out);
      expect(preview.rows.length, priceCount, reason: j.out);
    }
    File('${out.path}/_تقرير التحويل.txt').writeAsStringSync(report.toString());
  });
}
