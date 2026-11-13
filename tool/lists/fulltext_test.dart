@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sanitaryware_erp/core/pdf_import/pdf_reader.dart';

void main() {
  test('fulltext', () async {
    PdfTextReader.useModule('${Directory.current.path}/build/windows/x64/runner/Release/pdfium.dll');
    final f = File(Platform.environment['PDF']!);
    final page = int.parse(Platform.environment['PAGE']!);
    final doc = await PdfDocument.openFile(f.path);
    final t = await doc.pages[page - 1].loadText();
    final b = StringBuffer();
    var shown = 0;
    for (final f in t.fragments) {
     for (var k = 0; k < f.text.length; k++) {
      if (shown++ > 140) break;
      final r = f.charRects[k];
      final i = f.index + k;
      b.writeln('${t.fullText.codeUnitAt(i).toRadixString(16)} ${t.fullText[i]} ${r.left.toStringAsFixed(1)} ${r.right.toStringAsFixed(1)} ${r.top.toStringAsFixed(1)} ${r.bottom.toStringAsFixed(1)}');
     }
    }
    File(Platform.environment['OUT']!).writeAsStringSync(b.toString());
    await doc.dispose();
  });
}
