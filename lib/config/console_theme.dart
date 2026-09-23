import 'package:flutter/material.dart';

/// Design tokens for the platform surfaces: the web sign-in and the
/// super-admin console.
///
/// The school-facing app is teal. The platform operator's surfaces are indigo,
/// because they are a different product: one runs a field trip, the other runs
/// the service schools subscribe to. Seeing indigo means "you are administering
/// FieldTrip360 itself", which matters when the same person holds both kinds of
/// account.
///
/// Every value a console screen paints comes from here. An off-scale padding or
/// a one-off hex in a screen file is a bug, not a detail.

/// 4px base spacing scale. Nothing between these steps.
class Insets {
  Insets._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
  static const double huge = 64;
  static const double giant = 96;
}

/// Type scale on a 1.2 ratio — dense enough for tables, still readable.
class FontSizes {
  FontSizes._();
  static const double caption = 12;
  static const double body = 14;
  static const double bodyLg = 17;
  static const double title = 20;
  static const double heading = 24;
  static const double display = 29;
}

class Radii {
  Radii._();
  static const double base = 10;
  static const double large = 16;
  static const BorderRadius card = BorderRadius.all(Radius.circular(large));
  static const BorderRadius control = BorderRadius.all(Radius.circular(base));
}

/// Motion durations. Entering eases out, leaving eases in.
class Motion {
  Motion._();
  static const Duration state = Duration(milliseconds: 120);
  static const Duration transition = Duration(milliseconds: 200);
  static const Duration entrance = Duration(milliseconds: 320);
  static const Curve enter = Curves.easeOut;
  static const Curve exit = Curves.easeIn;
}

/// The indigo brand ramp used by the platform surfaces.
class Brand {
  Brand._();
  static const Color i50 = Color(0xFFEEF0FB);
  static const Color i100 = Color(0xFFD8DCF6);
  static const Color i200 = Color(0xFFB4BCEE);
  static const Color i400 = Color(0xFF5A67E0);
  static const Color i500 = Color(0xFF4450D6);

  /// Primary action colour. White text on this is ~8.4:1.
  static const Color i600 = Color(0xFF2F3BB3);
  static const Color i700 = Color(0xFF252E8E);
  static const Color i900 = Color(0xFF161B54);
}

/// A semantic status colour: a fill, a border and a foreground that read
/// correctly on the current background. Status is never carried by colour
/// alone — every badge that uses these also shows an icon and a word.
class StatusTone {
  final Color fg;
  final Color bg;
  final Color border;
  const StatusTone({required this.fg, required this.bg, required this.border});
}

/// Console surface tokens, one set per brightness.
class ConsoleTokens {
  final Color page;
  final Color surface;
  final Color surfaceMuted;
  final Color border;
  final Color borderStrong;
  final Color text;
  final Color textMuted;
  final Color textFaint;
  final Color brand;
  final Color brandHover;
  final Color onBrand;
  final Color sidebar;
  final Color sidebarText;
  final Color sidebarTextMuted;
  final Color sidebarActive;
  final Color focusRing;
  final List<BoxShadow> cardShadow;

  final StatusTone neutral;
  final StatusTone info;
  final StatusTone warning;
  final StatusTone success;
  final StatusTone danger;

  const ConsoleTokens({
    required this.page,
    required this.surface,
    required this.surfaceMuted,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.textMuted,
    required this.textFaint,
    required this.brand,
    required this.brandHover,
    required this.onBrand,
    required this.sidebar,
    required this.sidebarText,
    required this.sidebarTextMuted,
    required this.sidebarActive,
    required this.focusRing,
    required this.cardShadow,
    required this.neutral,
    required this.info,
    required this.warning,
    required this.success,
    required this.danger,
  });

  static const light = ConsoleTokens(
    page: Color(0xFFF6F7FB),
    surface: Colors.white,
    surfaceMuted: Color(0xFFF9FAFC),
    border: Color(0xFFE4E7F2),
    borderStrong: Color(0xFFC9CEE0),
    text: Color(0xFF1F2937),
    textMuted: Color(0xFF5B6478),
    textFaint: Color(0xFF8A93A6),
    brand: Brand.i600,
    brandHover: Brand.i700,
    onBrand: Colors.white,
    sidebar: Brand.i900,
    sidebarText: Colors.white,
    sidebarTextMuted: Color(0xB3FFFFFF),
    sidebarActive: Color(0x2EFFFFFF),
    focusRing: Brand.i500,
    cardShadow: [
      BoxShadow(color: Color(0x0F101828), blurRadius: 16, offset: Offset(0, 4)),
      BoxShadow(color: Color(0x0A101828), blurRadius: 2, offset: Offset(0, 1)),
    ],
    neutral: StatusTone(fg: Color(0xFF475467), bg: Color(0xFFF2F4F7), border: Color(0xFFD0D5DD)),
    info: StatusTone(fg: Color(0xFF252E8E), bg: Color(0xFFEEF0FB), border: Color(0xFFB4BCEE)),
    warning: StatusTone(fg: Color(0xFF92400E), bg: Color(0xFFFEF3C7), border: Color(0xFFFCD34D)),
    success: StatusTone(fg: Color(0xFF15803D), bg: Color(0xFFDCFCE7), border: Color(0xFF86EFAC)),
    danger: StatusTone(fg: Color(0xFFB42318), bg: Color(0xFFFEE4E2), border: Color(0xFFFDA29B)),
  );

  static const dark = ConsoleTokens(
    page: Color(0xFF0F1419),
    surface: Color(0xFF1A1F26),
    surfaceMuted: Color(0xFF151A20),
    border: Color(0xFF2A313B),
    borderStrong: Color(0xFF3B4453),
    text: Color(0xFFE5E7EB),
    textMuted: Color(0xFFA6AFBF),
    textFaint: Color(0xFF7C8699),
    brand: Brand.i400,
    brandHover: Brand.i500,
    onBrand: Colors.white,
    sidebar: Color(0xFF141A2E),
    sidebarText: Color(0xFFE8EAF6),
    sidebarTextMuted: Color(0xB3E8EAF6),
    sidebarActive: Color(0x33FFFFFF),
    focusRing: Brand.i400,
    cardShadow: [
      BoxShadow(color: Color(0x4D000000), blurRadius: 16, offset: Offset(0, 4)),
    ],
    neutral: StatusTone(fg: Color(0xFFCBD2DE), bg: Color(0xFF232A33), border: Color(0xFF3B4453)),
    info: StatusTone(fg: Color(0xFFB4BCEE), bg: Color(0xFF1E2447), border: Color(0xFF3A448C)),
    warning: StatusTone(fg: Color(0xFFFCD34D), bg: Color(0xFF3A2E10), border: Color(0xFF7C5E14)),
    success: StatusTone(fg: Color(0xFF86EFAC), bg: Color(0xFF12301F), border: Color(0xFF2F6B44)),
    danger: StatusTone(fg: Color(0xFFFDA29B), bg: Color(0xFF3A1B18), border: Color(0xFF8C2F28)),
  );

  static ConsoleTokens of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// Where the console layout changes, chosen from where the content breaks
/// rather than from device names.
class Breakpoints {
  Breakpoints._();

  /// Below this the sidebar collapses into a drawer.
  static const double sidebarCollapse = 1100;

  /// Below this the login drops its brand panel and stacks.
  static const double loginStack = 900;

  /// Below this, tables become stacked cards.
  static const double tableStack = 760;
}
