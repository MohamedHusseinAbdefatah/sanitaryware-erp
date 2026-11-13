@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sanitaryware_erp/core/pdf_import/pdf_reader.dart';

void main() {
  test('rects', () async {
    PdfTextReader.useModule('${Directory.current.path}/build/windows/x64/runner/Release/pdfium.dll');
    final doc = await PdfDocument.openFile(Platform.environment['PDF']!);
    final t = await doc.pages[int.parse(Platform.environment['PAGE']!) - 1].loadText();
    final find = Platform.environment['FIND']!;
    final at = t.fullText.indexOf(find);
    final b = StringBuffer('at $at\n');
    for (final f in t.fragments) {
      for (var k = 0; k < f.text.length; k++) {
        final i = f.index + k;
        if (i < at - 3 || i > at + find.length + 40) continue;
        final r = f.charRects[k];
        b.writeln('$i ${f.text[k]} ${f.text.codeUnitAt(k).toRadixString(16)} ${r.left.toStringAsFixed(2)} ${r.right.toStringAsFixed(2)}');
      }
    }
    File(Platform.environment['OUT']!).writeAsStringSync(b.toString());
  });
}
