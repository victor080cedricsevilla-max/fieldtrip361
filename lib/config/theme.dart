import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ThemeModeNotifier extends ValueNotifier<ThemeMode> {
  _ThemeModeNotifier() : super(ThemeMode.light);
}

/// Colours for the frosted surfaces — the nav bar, the emergency button.
///
/// Glass reads as glass only when the tint, the border and the glow move
/// together, and each of the three needs a different value per brightness.
/// Grouping them means a widget picks one token set instead of branching on
/// brightness at every colour it paints.
class GlassTokens {
  final Color surface; // translucent fill behind the blur
  final Color border;
  final Color shadow;
  final Color activePill; // the sliding indicator behind the selected tab
  final Color activeGlow;
  final Color idleIcon;
  final Color idleLabel;

  const GlassTokens({
    required this.surface,
    required this.border,
    required this.shadow,
    required this.activePill,
    required this.activeGlow,
    required this.idleIcon,
    required this.idleLabel,
  });

  /// Dark glass: a light film over a dark ground, lifted by a soft white edge.
  static const dark = GlassTokens(
    surface: Color(0xCC141A20),
    border: Color(0x24FFFFFF),
    shadow: Color(0x80000000),
    activePill: Color(0x1FFFFFFF),
    activeGlow: Color(0x40000000),
    idleIcon: Color(0x8AFFFFFF),
    idleLabel: Color(0x70FFFFFF),
  );

  /// Light glass: a white film, with the depth carried by the shadow instead
  /// of the border — a bright edge on a bright page reads as nothing at all.
  static const light = GlassTokens(
    surface: Color(0xD9FFFFFF),
    border: Color(0x14000000),
    shadow: Color(0x1F000000),
    activePill: Color(0x0D000000),
    activeGlow: Color(0x1A000000),
    idleIcon: Color(0x8A2C3E50),
    idleLabel: Color(0x702C3E50),
  );

  static GlassTokens of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

class _ColorNotifier extends ValueNotifier<Color> {
  _ColorNotifier() : super(const Color(0xFF00C4B4));
}

class AppTheme {
  // --- STATIC COLORS (non-primary, always constant) ---
  static const Color secondaryColor = Color(0xFF2C3E50);
  static const Color accentColor = Color(0xFFFFB74D);
  static const Color background = Colors.white;
  static const Color errorColor = Color(0xFFEF4444);
  static const Color darkText = Color(0xFF1F2937);
  static const Color darkBg = Color(0xFF0F1419);
  static const Color darkSurface = Color(0xFF1A1F26);
  static const Color darkSurfaceHigh = Color(0xFF242B33);
  static const Color darkText2 = Color(0xFFE5E7EB);

  // --- PRIMARY COLOR ---
  /// Compile-time default -- used everywhere `const` is required.
  static const Color primaryColor = Color(0xFF00C4B4);

  /// Runtime dynamic color -- the theme and all non-const widgets use this.
  static final _ColorNotifier primaryColorNotifier = _ColorNotifier();

  /// The effective primary color at runtime (may differ from the const default).
  static Color get effectivePrimary => primaryColorNotifier.value;

  /// Update the dynamic theme color.
  /// Auto-darkens if lightness > 0.65 so white text stays readable.
  static void setPrimaryColor(Color color) {
    final hsl = HSLColor.fromColor(color);
    primaryColorNotifier.value =
        hsl.lightness > 0.65 ? hsl.withLightness(0.38).toColor() : color;
  }

  /// Listenable theme mode.
  static final _ThemeModeNotifier mode = _ThemeModeNotifier();

  static const _modeKey = 'themeMode';

  /// Sets the mode and remembers it, so the choice survives a restart.
  ///
  /// The notifier is updated first: the preference write is a disk round trip,
  /// and the user should not watch the app repaint a beat after their tap.
  static Future<void> setMode(ThemeMode m) async {
    mode.value = m;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_modeKey, m.name);
    } catch (_) {
      // A device that cannot persist still gets the theme it asked for; it
      // just forgets on the next launch.
    }
  }

  /// Restores the saved mode. Call once before the first frame.
  static Future<void> loadSavedMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_modeKey);
      if (saved == null) return;
      mode.value = ThemeMode.values.firstWhere(
        (m) => m.name == saved,
        orElse: () => ThemeMode.light,
      );
    } catch (_) {/* keep the default */}
  }

  static void toggleMode() {
    setMode(mode.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
  }

  static ThemeData get lightTheme => lightThemeWithColor(effectivePrimary);

  static ThemeData lightThemeWithColor(Color primary) {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: background,
      primaryColor: primary,

      textTheme: GoogleFonts.poppinsTextTheme().apply(
        bodyColor: darkText,
        displayColor: secondaryColor,
      ),

      colorScheme: ColorScheme.light(
        primary: primary,
        secondary: secondaryColor,
        error: errorColor,
        surface: background,
        onSurface: darkText,
        onPrimary: Colors.white,
      ),

      appBarTheme: AppBarTheme(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        iconTheme: const IconThemeData(color: secondaryColor),
        titleTextStyle: GoogleFonts.poppins(
          color: secondaryColor,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.grey[50],
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        labelStyle: TextStyle(color: Colors.grey[600]),
        hintStyle: TextStyle(color: Colors.grey[400]),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: errorColor, width: 1.5),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 2,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          textStyle: GoogleFonts.poppins(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),

      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 2,
        shadowColor: Colors.black.withValues(alpha: 0.1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: GoogleFonts.poppins(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: darkText,
        ),
      ),

      datePickerTheme: DatePickerThemeData(
        backgroundColor: Colors.white,
        headerBackgroundColor: primary,
        headerForegroundColor: Colors.white,
        dayStyle: GoogleFonts.poppins(),
      ),

      timePickerTheme: TimePickerThemeData(
        backgroundColor: Colors.white,
        dialHandColor: primary,
        dialBackgroundColor: primary.withValues(alpha: 0.1),
        dialTextColor: WidgetStateColor.resolveWith((states) =>
            states.contains(WidgetState.selected) ? Colors.white : secondaryColor),
        dayPeriodTextColor: WidgetStateColor.resolveWith((states) =>
            states.contains(WidgetState.selected) ? Colors.white : secondaryColor),
        dayPeriodColor: WidgetStateColor.resolveWith((states) =>
            states.contains(WidgetState.selected) ? primary : Colors.grey.shade200),
        hourMinuteTextColor: WidgetStateColor.resolveWith((states) =>
            states.contains(WidgetState.selected) ? Colors.white : primary),
        hourMinuteColor: WidgetStateColor.resolveWith((states) =>
            states.contains(WidgetState.selected) ? primary : primary.withValues(alpha: 0.1)),
        hourMinuteTextStyle: GoogleFonts.poppins(fontSize: 40, fontWeight: FontWeight.bold),
        helpTextStyle: GoogleFonts.poppins(color: secondaryColor),
      ),
    );
  }

  static ThemeData get darkTheme => darkThemeWithColor(effectivePrimary);

  static ThemeData darkThemeWithColor(Color primary) {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBg,
      primaryColor: primary,
      textTheme: GoogleFonts.poppinsTextTheme(ThemeData.dark().textTheme).apply(
        bodyColor: darkText2,
        displayColor: darkText2,
      ),
      colorScheme: ColorScheme.dark(
        primary: primary,
        secondary: accentColor,
        error: errorColor,
        surface: darkSurface,
        onSurface: darkText2,
        onPrimary: Colors.white,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: darkSurface,
        elevation: 0,
        centerTitle: false,
        iconTheme: const IconThemeData(color: darkText2),
        titleTextStyle: GoogleFonts.poppins(
          color: darkText2,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkSurfaceHigh,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        labelStyle: const TextStyle(color: Color(0xFF9CA3AF)),
        hintStyle: const TextStyle(color: Color(0xFF6B7280)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF374151)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF374151)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: primary, width: 2),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          textStyle: GoogleFonts.poppins(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: GoogleFonts.poppins(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: darkText2,
        ),
      ),
      dividerColor: const Color(0xFF374151),
    );
  }
}
