import 'dart:io';

import 'package:pdfrx/pdfrx.dart';

import 'pdf_layout.dart';

/// The text of one page, as lines.
class PdfPageLines {
  const PdfPageLines(this.number, this.lines, this.characterCount);

  /// 1-based.
  final int number;
  final List<PdfLine> lines;
  final int characterCount;
}

/// Reads the text of a PDF with PDFium (through pdfrx). A scanned page has
/// no text at all: it is a picture, and nothing can be read from it safely.
class PdfTextReader {
  const PdfTextReader();

  /// When running outside the app (tests), points at a pdfium.dll on disk.
  static void useModule(String path) => Pdfrx.pdfiumModulePath = path;

  Future<List<PdfPageLines>> read(File file, {Set<int>? pages}) async {
    final doc = await PdfDocument.openFile(file.path);
    try {
      final out = <PdfPageLines>[];
      for (var i = 0; i < doc.pages.length; i++) {
        if (pages != null && !pages.contains(i + 1)) continue;
        final text = await doc.pages[i].loadText();
        final chars = <PdfChar>[];
        for (final f in text.fragments) {
          final rects = f.charRects;
          for (var k = 0; k < f.text.length && k < rects.length; k++) {
            final r = rects[k];
            chars.add(PdfChar(f.text[k], r.left, r.top, r.right, r.bottom));
          }
        }
        out.add(PdfPageLines(i + 1, layoutLines(chars), chars.where((c) => c.text.trim().isNotEmpty).length));
      }
      return out;
    } finally {
      await doc.dispose();
    }
  }

  Future<int> pageCount(File file) async {
    final doc = await PdfDocument.openFile(file.path);
    try {
      return doc.pages.length;
    } finally {
      await doc.dispose();
    }
  }
}
