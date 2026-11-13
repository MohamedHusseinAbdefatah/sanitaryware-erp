// Renders PDF pages to PNG files for checking by eye.
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';
import 'package:sanitaryware_erp/core/pdf_import/pdf_reader.dart';

void main() {
  test('render', () async {
    PdfTextReader.useModule('${Directory.current.path}/build/windows/x64/runner/Release/pdfium.dll');
    final doc = await PdfDocument.openFile(Platform.environment['PDF']!);
    final out = Platform.environment['OUT']!;
    final scale = double.parse(Platform.environment['SCALE'] ?? '2');
    for (final p in Platform.environment['PAGES']!.split(',').map(int.parse)) {
      final page = doc.pages[p - 1];
      final w = (page.width * scale).round(), h = (page.height * scale).round();
      final r = await page.render(width: w, height: h, fullWidth: w.toDouble(), fullHeight: h.toDouble());
      if (r == null) continue;
      final im = img.Image.fromBytes(width: r.width, height: r.height, bytes: r.pixels.buffer, numChannels: 4, order: img.ChannelOrder.bgra);
      File('$out-p$p.png').writeAsBytesSync(img.encodePng(im));
      r.dispose();
    }
    await doc.dispose();
  });
}
