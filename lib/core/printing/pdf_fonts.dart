import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

/// Cairo, embedded in every PDF so Arabic prints the same on any printer.
class PdfFonts {
  PdfFonts({required this.regular, required this.bold});

  /// Builds from raw font files (tests load them from disk).
  PdfFonts.fromBytes({required ByteData regular, required ByteData bold})
      : regular = pw.Font.ttf(regular),
        bold = pw.Font.ttf(bold);

  final pw.Font regular;
  final pw.Font bold;

  static PdfFonts? _cache;

  static Future<PdfFonts> load() async {
    return _cache ??= PdfFonts.fromBytes(
      regular: await rootBundle.load('assets/fonts/Cairo-Regular.ttf'),
      bold: await rootBundle.load('assets/fonts/Cairo-Bold.ttf'),
    );
  }

  pw.ThemeData get theme => pw.ThemeData.withFont(base: regular, bold: bold);
}
