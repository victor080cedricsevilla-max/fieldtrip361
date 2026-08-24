import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class _ThemeModeNotifier extends ValueNotifier<ThemeMode> {
  _ThemeModeNotifier() : super(ThemeMode.light);
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
  static void setMode(ThemeMode m) => mode.value = m;
  static void toggleMode() {
    mode.value = mode.value == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
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

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBg,
      primaryColor: primaryColor,
      textTheme: GoogleFonts.poppinsTextTheme(ThemeData.dark().textTheme).apply(
        bodyColor: darkText2,
        displayColor: darkText2,
      ),
      colorScheme: ColorScheme.dark(
        primary: primaryColor,
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
          borderSide: BorderSide(color: primaryColor, width: 2),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
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
