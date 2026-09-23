import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../config/console_theme.dart';

/// The indigo panel beside the web sign-in and application forms.
///
/// The decoration is a set of concentric arcs sweeping out from the mark —
/// routes fanning out from a school, which is what the product does. It is
/// drawn rather than imported so it scales to any panel size without a raster
/// asset, and it sits at low contrast so it never competes with the heading.
class BrandPanel extends StatelessWidget {
  final String headline;
  final String supporting;
  final List<String> points;

  const BrandPanel({
    super.key,
    required this.headline,
    required this.supporting,
    this.points = const [],
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        // Deep slate, not teal: a full-bleed panel in the action colour would
        // shout over the form beside it, and leave the primary button with
        // nothing to stand out against.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Brand.i900, Color(0xFF1B2733)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          const Positioned.fill(
            child: CustomPaint(painter: _ArcPainter()),
          ),
          Padding(
            padding: const EdgeInsets.all(Insets.xxxl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const BrandLockup(onDark: true),
                const Spacer(),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        headline,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 42,
                          height: 1.12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -1.2,
                        ),
                      ),
                      const SizedBox(height: Insets.lg),
                      Text(
                        supporting,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.82),
                          fontSize: FontSizes.bodyLg,
                          height: 1.6,
                        ),
                      ),
                      if (points.isNotEmpty) ...[
                        const SizedBox(height: Insets.xl),
                        ...points.map(
                          (p) => Padding(
                            padding: const EdgeInsets.only(bottom: Insets.md),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Icon(
                                    Icons.check_circle_outline_rounded,
                                    size: 18,
                                    color: Colors.white.withValues(alpha: 0.75),
                                  ),
                                ),
                                const SizedBox(width: Insets.md),
                                Expanded(
                                  child: Text(
                                    p,
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.82),
                                      fontSize: FontSizes.body,
                                      height: 1.55,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  '© ${DateTime.now().year} FieldTrip360',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: FontSizes.caption,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The FieldTrip360 mark and wordmark, top-left of every entry screen.
///
/// The real logo rather than a stand-in glyph: this is the first thing a
/// registrar sees, and it should be the same mark that is on the phone app.
class BrandLockup extends StatelessWidget {
  final bool onDark;
  final double size;

  const BrandLockup({super.key, this.onDark = false, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final fg = onDark ? Colors.white : t.text;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          padding: EdgeInsets.all(size * 0.16),
          decoration: BoxDecoration(
            color: onDark ? Colors.white.withValues(alpha: 0.12) : Brand.i50,
            borderRadius: BorderRadius.circular(Radii.base),
          ),
          child: Image.asset(
            'assets/icon/ft360_logo.png',
            fit: BoxFit.contain,
            // A missing asset must not take the sign-in screen down with it.
            errorBuilder: (_, __, ___) => Icon(
              Icons.route_rounded,
              color: onDark ? Colors.white : Brand.i600,
              size: size * 0.55,
            ),
          ),
        ),
        const SizedBox(width: Insets.md),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: 'FieldTrip',
                style: TextStyle(color: fg, fontWeight: FontWeight.w700),
              ),
              TextSpan(
                text: '360',
                style: TextStyle(
                  color: onDark ? Brand.accent : Brand.i600,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          style: const TextStyle(fontSize: FontSizes.title, letterSpacing: -0.4),
        ),
      ],
    );
  }
}

class _ArcPainter extends CustomPainter {
  const _ArcPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = Colors.white.withValues(alpha: 0.13);

    // Arcs radiate from a point off the top-left, so the sweep reads as
    // movement across the panel rather than as a target.
    final origin = Offset(size.width * 0.16, size.height * 0.12);
    for (int i = 1; i <= 7; i++) {
      final radius = size.shortestSide * (0.30 + i * 0.17);
      canvas.drawArc(
        Rect.fromCircle(center: origin, radius: radius),
        math.pi * 0.02,
        math.pi * 0.62,
        false,
        paint,
      );
    }

    final soft = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.white.withValues(alpha: 0.05);
    canvas.drawCircle(
      Offset(size.width * 0.92, size.height * 0.86),
      size.shortestSide * 0.28,
      soft,
    );
  }

  @override
  bool shouldRepaint(covariant _ArcPainter oldDelegate) => false;
}
