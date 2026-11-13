// Dumps the text lines of every PDF in a folder (for building upload files).
@Timeout(Duration(minutes: 20))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/pdf_import/pdf_reader.dart';
import 'package:sanitaryware_erp/core/pdf_import/price_table.dart';

void main() {
  test('dump', () async {
    PdfTextReader.useModule('${Directory.current.path}/build/windows/x64/runner/Release/pdfium.dll');
    final src = Directory(Platform.environment['LISTS_SRC']!);
    final out = Directory(Platform.environment['LISTS_OUT']!);
    final summary = StringBuffer();
    for (final f in src.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.pdf'))) {
      final name = f.uri.pathSegments.last;
      try {
        const reader = PdfTextReader();
        final n = await reader.pageCount(f);
        final catalogue = name.toLowerCase().contains('catalogue') || name.contains('كتالوج');
        final pages = await reader.read(f, pages: catalogue ? {for (var i = 1; i <= 4; i++) i} : null);
        final b = StringBuffer();
        for (final p in pages) {
          b.writeln('===== PAGE ${p.number} chars ${p.characterCount}');
          for (final l in p.lines) {
            b.writeln(l.words.map((w) => '${w.text}@${w.left.round()}').join('  '));
          }
        }
        File('${out.path}/${name.replaceAll('.pdf', '')}.txt').writeAsStringSync(b.toString());
        final t = extractPriceTable(pages);
        summary.writeln('$name | pages $n | read ${pages.length} | scanned ${t.scannedPages.length} | rows ${t.rows.length} '
            '| issues ${t.rows.where((r) => r.issue != null).length} | cols ${t.columns.map((c) => '${c.label}:${c.count}').join(', ')}');
      } catch (e) {
        summary.writeln('$name | ERROR $e');
      }
    }
    File('${out.path}/_summary.txt').writeAsStringSync(summary.toString());
  });
}
