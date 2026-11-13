@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sanitaryware_erp/core/pdf_import/pdf_reader.dart';

// PDF=<file> OUT=<txt>: the full text of every page.
void main() {
  test('alltext', () async {
    PdfTextReader.useModule('${Directory.current.path}/build/windows/x64/runner/Release/pdfium.dll');
    final doc = await PdfDocument.openFile(Platform.environment['PDF']!);
    final b = StringBuffer();
    for (final (i, p) in doc.pages.indexed) {
      b.writeln('===== page ${i + 1}');
      b.writeln((await p.loadText()).fullText);
    }
    File(Platform.environment['OUT']!).writeAsStringSync(b.toString());
    await doc.dispose();
  });
}
