import 'package:flutter/material.dart';

/// App theme. Cairo is bundled in assets/fonts/ and also embedded in PDFs,
/// so the screen and the printed page look the same.
ThemeData buildTheme() {
  return ThemeData(
    useMaterial3: true,
    colorSchemeSeed: const Color(0xFF0E7C86),
    visualDensity: VisualDensity.compact,
    fontFamily: 'Cairo',
  );
}
