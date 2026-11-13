@Timeout(Duration(minutes: 20))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanitaryware_erp/core/pdf_import/pdf_reader.dart';

import 'pdf_text.dart';

void main() {
  test('ft dump', () async {
    PdfTextReader.useModule('${Directory.current.path}/build/windows/x64/runner/Release/pdfium.dll');
    final src = Directory(Platform.environment['LISTS_SRC']!);
    final out = Platform.environment['LISTS_OUT']!;
    for (final f in src.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.pdf'))) {
      final name = f.uri.pathSegments.last;
      if (name.contains('atalogue') || name.contains('كتالوج') || name.contains('Instalux') || name.contains('دليل')) continue;
      final pages = await readPdfWords(f);
      final b = StringBuffer();
      for (var i = 0; i < pages.length; i++) {
        b.writeln('===== PAGE ${i + 1}');
        pages[i].forEach(b.writeln);
      }
      File('$out/${name.replaceAll('.pdf', '')}.txt').writeAsStringSync(b.toString());
    }
  });
}
