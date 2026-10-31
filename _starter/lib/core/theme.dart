import 'package:flutter/material.dart';

/// App theme. The Arabic font (Cairo) is added in Phase 1 by placing the font
/// files in assets/fonts/ and setting `fontFamily: 'Cairo'` here.
ThemeData buildTheme() {
  return ThemeData(
    useMaterial3: true,
    colorSchemeSeed: const Color(0xFF0E7C86),
    visualDensity: VisualDensity.compact,
  );
}
