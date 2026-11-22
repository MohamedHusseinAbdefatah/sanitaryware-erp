import 'package:flutter/material.dart';

/// The app's colours. Teal is the colour of the app icon. Every screen takes
/// its colours from here, so the whole program keeps one look.
abstract final class AppColors {
  // Brand
  static const brand = Color(0xFF0E7C86);
  static const brandDark = Color(0xFF0A2F34);
  static const brandSoft = Color(0xFFE3F2F3);

  // Surfaces and lines
  static const canvas = Color(0xFFF3F6F7);
  static const surface = Colors.white;
  static const border = Color(0xFFDDE5E7);
  static const borderStrong = Color(0xFFC3D0D3);
  static const zebra = Color(0xFFF8FAFB);
  static const hover = Color(0x0D0E7C86);

  // Text
  static const ink = Color(0xFF14272B);
  static const muted = Color(0xFF5A6F73);
  static const subtle = Color(0xFF8A9B9E);

  // Sidebar
  static const sideText = Color(0xFFB4CBCE);
  static const sideSelected = Color(0x24FFFFFF);
  static const sideHover = Color(0x12FFFFFF);
  static const sideAccent = Color(0xFF7FD4DA);
  static const sideDivider = Color(0x1AFFFFFF);

  // Meaning
  static const good = Color(0xFF1E7D4F);
  static const goodBg = Color(0xFFE2F4EA);
  static const warn = Color(0xFF9A6200);
  static const warnBg = Color(0xFFFCF0D2);
  static const bad = Color(0xFFB3261E);
  static const badBg = Color(0xFFFBE4E1);
  static const info = Color(0xFF1F5FA8);
  static const infoBg = Color(0xFFE3EDFA);
  static const neutral = Color(0xFF5A6F73);
  static const neutralBg = Color(0xFFEDF1F2);

  /// Series colours for charts, in order; distinct and readable on white.
  static const chart = [
    Color(0xFF0E7C86),
    Color(0xFF1F5FA8),
    Color(0xFFD9822B),
    Color(0xFF7A4FB5),
    Color(0xFF2E7D4F),
    Color(0xFFA23B5B),
  ];
}

/// Spacing steps. Pages use [xl] at their edges, cards [lg] inside, and
/// related fields [sm]–[md] apart.
abstract final class AppSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Corner radii: fields and buttons [md], cards [lg], dialogs [xl].
abstract final class AppRadius {
  static const double sm = 6;
  static const double md = 8;
  static const double lg = 12;
  static const double xl = 16;
  static const double pill = 999;

  static const smAll = BorderRadius.all(Radius.circular(sm));
  static const mdAll = BorderRadius.all(Radius.circular(md));
  static const lgAll = BorderRadius.all(Radius.circular(lg));
  static const xlAll = BorderRadius.all(Radius.circular(xl));
}

/// Soft shadows: cards lie flat with a border; things that float (menus,
/// the search box, toasts) get [raised].
abstract final class AppShadows {
  static const card = [BoxShadow(color: Color(0x0A0B2A2E), blurRadius: 10, offset: Offset(0, 2))];
  static const raised = [BoxShadow(color: Color(0x1F0B2A2E), blurRadius: 24, offset: Offset(0, 8))];
}

/// How long things move. Short, so the program feels quick.
abstract final class AppMotion {
  static const fast = Duration(milliseconds: 120);
  static const normal = Duration(milliseconds: 200);
}

/// Scrolling for the whole program. On the desktop every list, table and
/// long form gets a scrollbar that is always shown, wide enough to grab, and
/// on the RIGHT edge even though the layout is right-to-left (Flutter would
/// put it on the left); a horizontal bar sits at the bottom. The mouse
/// wheel, the bar and keyboard all scroll.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  static bool _desktop(BuildContext context) => switch (Theme.of(context).platform) {
        TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS => true,
        _ => false,
      };

  @override
  Widget buildScrollbar(BuildContext context, Widget child, ScrollableDetails details) {
    if (!_desktop(context)) return super.buildScrollbar(context, child, details);
    final vertical = axisDirectionToAxis(details.direction) == Axis.vertical;
    return Scrollbar(
      controller: details.controller,
      thumbVisibility: true,
      trackVisibility: vertical,
      interactive: true,
      scrollbarOrientation: vertical ? ScrollbarOrientation.right : ScrollbarOrientation.bottom,
      child: child,
    );
  }
}

/// App theme. Cairo is bundled in assets/fonts/ and also embedded in PDFs,
/// so the screen and the printed page look the same. Every component takes
/// its shape, colour and spacing from the tokens above.
ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.brand,
    primary: AppColors.brand,
    surface: AppColors.surface,
    onSurface: AppColors.ink,
    error: AppColors.bad,
  ).copyWith(
    outline: AppColors.borderStrong,
    outlineVariant: AppColors.border,
    secondaryContainer: AppColors.brandSoft,
    onSecondaryContainer: AppColors.brandDark,
  );
  const radius = AppRadius.mdAll;
  final outline = OutlineInputBorder(borderRadius: radius, borderSide: const BorderSide(color: AppColors.border));
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    visualDensity: VisualDensity.compact,
    fontFamily: 'Cairo',
    scaffoldBackgroundColor: AppColors.canvas,
  );
  const bold = FontWeight.w700;
  // A clear ring around whatever the keyboard is on.
  final focusRing = WidgetStateProperty.resolveWith<BorderSide?>(
    (s) => s.contains(WidgetState.focused) ? const BorderSide(color: AppColors.brand, width: 2) : null,
  );
  return base.copyWith(
    textTheme: base.textTheme
        .copyWith(
          headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, color: AppColors.ink),
          titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: bold, color: AppColors.ink),
          titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: bold, color: AppColors.ink),
          titleSmall: base.textTheme.titleSmall?.copyWith(fontWeight: bold, color: AppColors.ink),
          labelLarge: base.textTheme.labelLarge?.copyWith(fontWeight: bold),
        )
        .apply(bodyColor: AppColors.ink, displayColor: AppColors.ink),
    hoverColor: AppColors.hover,
    focusColor: AppColors.brand.withValues(alpha: 0.16),
    cardTheme: const CardThemeData(
      elevation: 0,
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.lgAll, side: BorderSide(color: AppColors.border)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: AppColors.surface,
      hoverColor: AppColors.zebra,
      border: outline,
      enabledBorder: outline,
      disabledBorder: outline.copyWith(borderSide: const BorderSide(color: AppColors.neutralBg)),
      focusedBorder: outline.copyWith(borderSide: const BorderSide(color: AppColors.brand, width: 1.8)),
      errorBorder: outline.copyWith(borderSide: const BorderSide(color: AppColors.bad)),
      focusedErrorBorder: outline.copyWith(borderSide: const BorderSide(color: AppColors.bad, width: 1.8)),
      labelStyle: const TextStyle(color: AppColors.muted),
      floatingLabelStyle: WidgetStateTextStyle.resolveWith((s) => TextStyle(
            color: s.contains(WidgetState.error)
                ? AppColors.bad
                : (s.contains(WidgetState.focused) ? AppColors.brand : AppColors.muted),
            fontWeight: bold,
          )),
      hintStyle: const TextStyle(color: AppColors.subtle),
      helperStyle: const TextStyle(color: AppColors.muted, fontSize: 12),
      errorStyle: const TextStyle(color: AppColors.bad, fontSize: 12, fontWeight: FontWeight.w600),
      prefixIconColor: AppColors.muted,
      suffixIconColor: AppColors.muted,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const RoundedRectangleBorder(borderRadius: radius),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        minimumSize: const Size(64, 42),
        textStyle: const TextStyle(fontFamily: 'Cairo', fontWeight: bold),
      ).copyWith(side: focusRing),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: radius),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: const TextStyle(fontFamily: 'Cairo', fontWeight: bold),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const RoundedRectangleBorder(borderRadius: radius),
        foregroundColor: AppColors.ink,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        textStyle: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600),
      ).copyWith(
        side: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused)
            ? const BorderSide(color: AppColors.brand, width: 2)
            : BorderSide(color: s.contains(WidgetState.disabled) ? AppColors.neutralBg : AppColors.borderStrong)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: const RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600),
      ).copyWith(side: focusRing),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(40, 40)).copyWith(side: focusRing),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: AppColors.brandSoft,
        selectedForegroundColor: AppColors.brandDark,
        side: const BorderSide(color: AppColors.borderStrong),
        shape: const RoundedRectangleBorder(borderRadius: radius),
        textStyle: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w600),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.xlAll),
      titleTextStyle: TextStyle(fontFamily: 'Cairo', fontSize: 19, fontWeight: FontWeight.w800, color: AppColors.ink),
      actionsPadding: EdgeInsetsDirectional.fromSTEB(24, 8, 24, 20),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border, space: 1, thickness: 1),
    popupMenuTheme: const PopupMenuThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        side: BorderSide(color: AppColors.border),
      ),
      textStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.ink, fontSize: 14),
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(AppColors.surface),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          side: BorderSide(color: AppColors.border),
        )),
      ),
    ),
    dropdownMenuTheme: const DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(AppColors.surface),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    tabBarTheme: const TabBarThemeData(
      labelStyle: TextStyle(fontFamily: 'Cairo', fontWeight: bold),
      unselectedLabelStyle: TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w500),
      labelColor: AppColors.brand,
      unselectedLabelColor: AppColors.muted,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: AppColors.border,
    ),
    dataTableTheme: const DataTableThemeData(
      headingTextStyle: TextStyle(fontFamily: 'Cairo', fontWeight: bold, color: AppColors.muted),
      headingRowColor: WidgetStatePropertyAll(AppColors.canvas),
      dividerThickness: 1,
    ),
    chipTheme: const ChipThemeData(
      side: BorderSide(color: AppColors.border),
      selectedColor: AppColors.brandSoft,
      secondarySelectedColor: AppColors.brandSoft,
      labelStyle: TextStyle(fontFamily: 'Cairo', color: AppColors.ink),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4))),
      side: const BorderSide(color: AppColors.borderStrong, width: 1.6),
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.brand : null),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.brand : null),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? AppColors.brand : AppColors.muted),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.brand,
      linearTrackColor: AppColors.neutralBg,
      circularTrackColor: Colors.transparent,
    ),
    badgeTheme: const BadgeThemeData(backgroundColor: AppColors.bad, textColor: Colors.white),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: AppColors.brandDark,
      indicatorColor: AppColors.sideSelected,
    ),
    drawerTheme: const DrawerThemeData(backgroundColor: AppColors.brandDark, surfaceTintColor: Colors.transparent),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
      iconColor: AppColors.brand,
      collapsedIconColor: AppColors.muted,
    ),
    datePickerTheme: const DatePickerThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: AppColors.brand,
      headerForegroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.xlAll),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.brandDark,
      contentTextStyle: TextStyle(fontFamily: 'Cairo', color: Colors.white, fontSize: 14),
      actionTextColor: AppColors.sideAccent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
    ),
    // A scrollbar that is easy to see and to grab (see AppScrollBehavior).
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.dragged) ? 12.0 : 10.0),
      radius: const Radius.circular(6),
      minThumbLength: 48,
      crossAxisMargin: 2,
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.dragged) || s.contains(WidgetState.hovered)
            ? AppColors.brand
            : AppColors.brand.withValues(alpha: 0.55),
      ),
      trackColor: const WidgetStatePropertyAll(AppColors.canvas),
      trackBorderColor: const WidgetStatePropertyAll(AppColors.border),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 400),
      textStyle: TextStyle(fontFamily: 'Cairo', color: Colors.white, fontSize: 12.5),
      decoration: BoxDecoration(color: AppColors.brandDark, borderRadius: AppRadius.smAll),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.muted,
      selectedColor: AppColors.brand,
      selectedTileColor: AppColors.brandSoft,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
    ),
  );
}

/// What a status means, which decides its colour.
enum Tone { good, warn, bad, info, neutral, brand }

Color toneColor(Tone t) => switch (t) {
      Tone.good => AppColors.good,
      Tone.warn => AppColors.warn,
      Tone.bad => AppColors.bad,
      Tone.info => AppColors.info,
      Tone.neutral => AppColors.neutral,
      Tone.brand => AppColors.brand,
    };

Color toneBackground(Tone t) => switch (t) {
      Tone.good => AppColors.goodBg,
      Tone.warn => AppColors.warnBg,
      Tone.bad => AppColors.badBg,
      Tone.info => AppColors.infoBg,
      Tone.neutral => AppColors.neutralBg,
      Tone.brand => AppColors.brandSoft,
    };

/// A small coloured label for a status: active, cancelled, pending... A dot
/// before the word means it is never told by colour alone.
class StatusPill extends StatelessWidget {
  const StatusPill(this.text, {super.key, this.color = AppColors.info, this.background = AppColors.infoBg, this.icon});

  const StatusPill.good(this.text, {super.key, this.icon})
      : color = AppColors.good,
        background = AppColors.goodBg;
  const StatusPill.warn(this.text, {super.key, this.icon})
      : color = AppColors.warn,
        background = AppColors.warnBg;
  const StatusPill.bad(this.text, {super.key, this.icon})
      : color = AppColors.bad,
        background = AppColors.badBg;
  const StatusPill.neutral(this.text, {super.key, this.icon})
      : color = AppColors.neutral,
        background = AppColors.neutralBg;

  StatusPill.tone(this.text, Tone tone, {super.key, this.icon})
      : color = toneColor(tone),
        background = toneBackground(tone);

  final String text;
  final Color color;
  final Color background;

  /// Shown instead of the dot.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(8, 2, 10, 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      // A Wrap, not a Row: in a narrow column the label wraps like plain
      // text instead of overflowing.
      child: Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (icon != null)
            Icon(icon, size: 13, color: color)
          else
            Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
        ],
      ),
    );
  }
}

/// The maker's model number as a tag beside a product's name, so it is seen
/// first (people ask for a product by its model). Nothing when empty.
class ModelTag extends StatelessWidget {
  const ModelTag(this.modelNo, {super.key, this.large = false});

  final String? modelNo;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final m = (modelNo ?? '').trim();
    if (m.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 10 : 6, vertical: large ? 3 : 1),
      decoration: BoxDecoration(
        color: AppColors.brand.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.brand.withValues(alpha: 0.35)),
      ),
      child: Text(
        'موديل $m',
        style: TextStyle(color: AppColors.brand, fontWeight: FontWeight.w800, fontSize: large ? 14 : 11.5),
      ),
    );
  }
}
