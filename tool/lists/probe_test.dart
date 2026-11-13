// Runs one list through its configuration and writes what was read, for review.
@Timeout(Duration(minutes: 20))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/pdf_import/pdf_reader.dart';

import 'configs.dart';
import 'engine.dart';
import 'pdf_text.dart';

void main() {
  test('probe', () async {
    PdfTextReader.useModule('${Directory.current.path}/build/windows/x64/runner/Release/pdfium.dll');
    final file = File(Platform.environment['PDF']!);
    final cfg = switch (Platform.environment['CFG']) {
      'duravit' => duravit,
      'bath' => duravitBath,
      _ => throw ArgumentError(Platform.environment['CFG']),
    };
    final pages = await readPdfWords(file);
    final rows = extract(pages, cfg);
    final b = StringBuffer('rows ${rows.length}  issues ${rows.where((r) => r.issues.isNotEmpty).length}\n');
    final labels = <String, int>{};
    for (final r in rows) {
      for (final l in r.prices.keys) {
        labels[l] = (labels[l] ?? 0) + 1;
      }
    }
    b.writeln('labels $labels');
    for (final r in rows) {
      b.writeln('p${r.page}\t${r.code}\t${r.prices}\t${r.nameEn}\t${r.nameAr}\t${r.issues.join('; ')}');
    }
    b.writeln('---- orphans');
    orphans(pages, cfg, rows).forEach(b.writeln);
    File(Platform.environment['OUT']!).writeAsStringSync(b.toString());
  });
}
