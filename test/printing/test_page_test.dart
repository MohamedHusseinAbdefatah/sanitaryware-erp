import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:sanitaryware_erp/core/printing/pdf_fonts.dart';
import 'package:sanitaryware_erp/core/printing/test_page.dart';
import 'package:sanitaryware_erp/core/services/settings_service.dart';

ByteData _font(String name) =>
    ByteData.sublistView(File('assets/fonts/$name').readAsBytesSync());

void main() {
  test('Cairo has the Arabic shapes the PDF writer needs', () {
    // The pdf package joins Arabic letters by switching to the "presentation
    // form" characters (U+FB50-U+FEFF), so the font must contain them.
    for (final name in ['Cairo-Regular.ttf', 'Cairo-Bold.ttf']) {
      final glyphs = TtfParser(_font(name)).charToGlyphIndexMap;
      const needed = {
        0x0627: 'ا', 0xFE8D: 'ﺍ isolated alef', 0xFE91: 'ﺑ initial beh',
        0xFE92: 'ﺒ medial beh', 0xFE90: 'ﺐ final beh', 0xFEFB: 'ﻻ lam-alef',
        0xFEEC: 'ﻬ medial heh', 0xFEF4: 'ﻴ medial yeh', 0x0661: '١',
        0x0041: 'A', 0x0030: '0', 0x002C: ',',
      };
      for (final entry in needed.entries) {
        expect(glyphs.containsKey(entry.key), isTrue,
            reason: '$name is missing ${entry.value}');
      }
    }
  });

  test('the test page builds a one-page PDF', () async {
    final fonts = PdfFonts.fromBytes(
      regular: _font('Cairo-Regular.ttf'),
      bold: _font('Cairo-Bold.ttf'),
    );
    final bytes = await buildTestPage(
      fonts: fonts,
      company: const CompanyInfo(
        name: 'معرض النيل للأدوات الصحية',
        address: 'شارع الجمهورية، المنصورة',
        phone: '01001234567',
      ),
      printedAt: DateTime(2026, 10, 31, 18, 5),
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');

    // Set PDF_OUT to a file path to look at the result.
    final out = Platform.environment['PDF_OUT'];
    if (out != null) File(out).writeAsBytesSync(bytes);
  });
}
