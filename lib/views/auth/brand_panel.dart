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
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Brand.i600, Brand.i700],
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
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(Radii.base),
                      ),
                      child: const Icon(Icons.route_rounded,
                          color: Colors.white, size: 25),
                    ),
                    const SizedBox(width: Insets.md),
                    const Text(
                      'FieldTrip360',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: FontSizes.title,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                      ),
                    ),
                  ],
                ),
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
