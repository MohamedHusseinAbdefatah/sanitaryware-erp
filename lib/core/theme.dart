import 'package:flutter/material.dart';

/// The app's colours. Teal is the colour of the app icon.
abstract final class AppColors {
  static const brand = Color(0xFF0E7C86);
  static const brandDark = Color(0xFF0B3B40);
  static const canvas = Color(0xFFF2F5F6);
  static const surface = Colors.white;
  static const border = Color(0xFFDCE4E6);
  static const zebra = Color(0xFFF8FAFB);
  static const ink = Color(0xFF16292C);
  static const muted = Color(0xFF5C7175);

  // Sidebar
  static const sideText = Color(0xFFB9CFD2);
  static const sideSelected = Color(0x26FFFFFF);
  static const sideAccent = Color(0xFF7FD4DA);

  // Meaning
  static const good = Color(0xFF1E7D4F);
  static const goodBg = Color(0xFFE2F4EA);
  static const warn = Color(0xFF9A6200);
  static const warnBg = Color(0xFFFCF0D2);
  static const bad = Color(0xFFB3261E);
  static const badBg = Color(0xFFFBE4E1);
  static const info = Color(0xFF1F5FA8);
  static const infoBg = Color(0xFFE3EDFA);
}

/// App theme. Cairo is bundled in assets/fonts/ and also embedded in PDFs,
/// so the screen and the printed page look the same.
ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.brand,
    primary: AppColors.brand,
    surface: AppColors.surface,
    onSurface: AppColors.ink,
  );
  const radius = BorderRadius.all(Radius.circular(8));
  final outline = OutlineInputBorder(borderRadius: radius, borderSide: const BorderSide(color: AppColors.border));
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    visualDensity: VisualDensity.compact,
    fontFamily: 'Cairo',
    scaffoldBackgroundColor: AppColors.canvas,
  );
  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: AppColors.ink),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: AppColors.ink),
      titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: AppColors.ink),
    ),
    cardTheme: const CardThemeData(
      elevation: 0,
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: AppColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: AppColors.surface,
      border: outline,
      enabledBorder: outline,
      focusedBorder: outline.copyWith(borderSide: const BorderSide(color: AppColors.brand, width: 1.6)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const RoundedRectangleBorder(borderRadius: radius),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        textStyle: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const RoundedRectangleBorder(borderRadius: radius),
        side: const BorderSide(color: AppColors.border),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: const RoundedRectangleBorder(borderRadius: radius)),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border, space: 1, thickness: 1),
    popupMenuTheme: const PopupMenuThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
    ),
    tabBarTheme: const TabBarThemeData(
      labelStyle: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700),
      dividerColor: AppColors.border,
    ),
    dataTableTheme: const DataTableThemeData(
      headingTextStyle: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700, color: AppColors.muted),
    ),
    chipTheme: const ChipThemeData(
      side: BorderSide(color: AppColors.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 400)),
    listTileTheme: const ListTileThemeData(iconColor: AppColors.muted),
  );
}

/// A small coloured label for a status: active, cancelled, pending...
class StatusPill extends StatelessWidget {
  const StatusPill(this.text, {super.key, this.color = AppColors.info, this.background = AppColors.infoBg});

  const StatusPill.good(this.text, {super.key})
      : color = AppColors.good,
        background = AppColors.goodBg;
  const StatusPill.warn(this.text, {super.key})
      : color = AppColors.warn,
        background = AppColors.warnBg;
  const StatusPill.bad(this.text, {super.key})
      : color = AppColors.bad,
        background = AppColors.badBg;

  final String text;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}
