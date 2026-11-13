@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/pdf_import/pdf_reader.dart';

import 'pdf_text.dart';

void main() {
  test('page words', () async {
    PdfTextReader.useModule('${Directory.current.path}/build/windows/x64/runner/Release/pdfium.dll');
    final p = int.parse(Platform.environment['PAGE']!);
    final pages = await readPdfWords(File(Platform.environment['PDF']!), pages: {p});
    final b = StringBuffer('overpainted $overpainted invisible $invisible\n');
    for (final l in pages[p - 1]) {
      b.writeln(l.words.map((w) => '${w.text}@${w.left.round()}#${w.order}').join('  '));
    }
    File(Platform.environment['OUT']!).writeAsStringSync(b.toString());
  });
}
