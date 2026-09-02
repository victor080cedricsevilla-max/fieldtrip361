import 'dart:ui';

import 'package:flutter/material.dart';

import '../config/theme.dart';

/// The floating emergency action, styled as red glass.
///
/// It shares the frosted language of the nav bar but keeps its own colour: an
/// emergency control that blends in has failed at the only job it has. The red
/// stays fully saturated in both themes and only the surrounding glow shifts,
/// because a red softened for a light background stops reading as an alarm.
class GlassEmergencyButton extends StatefulWidget {
  final VoidCallback onPressed;
  final String label;
  final IconData icon;

  const GlassEmergencyButton({
    super.key,
    required this.onPressed,
    this.label = 'Emergency',
    this.icon = Icons.emergency_rounded,
  });

  @override
  State<GlassEmergencyButton> createState() => _GlassEmergencyButtonState();
}

class _GlassEmergencyButtonState extends State<GlassEmergencyButton>
    with SingleTickerProviderStateMixin {
  static const _red = Color(0xFFEF4444);
  static const _redDeep = Color(0xFFB91C1C);

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat(reverse: true);

  bool _pressed = false;

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          scale: _pressed ? 0.94 : 1.0,
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (context, child) {
              // A slow breath rather than a flash. The glow is the only thing
              // that moves, so the button never changes size on the page.
              final t = reduceMotion ? 0.0 : _pulse.value;
              return Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: _red.withValues(alpha: (dark ? 0.42 : 0.30) + t * 0.14),
                      blurRadius: 22 + t * 10,
                      spreadRadius: t * 2,
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: dark ? 0.45 : 0.16),
                      blurRadius: 14,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: child,
              );
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(30),
                    // Translucent enough to read as glass, opaque enough that
                    // whatever scrolls underneath cannot wash the red out.
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        _red.withValues(alpha: dark ? 0.82 : 0.92),
                        _redDeep.withValues(alpha: dark ? 0.78 : 0.90),
                      ],
                    ),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: dark ? 0.28 : 0.45),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.icon, color: Colors.white, size: 20),
                      const SizedBox(width: 9),
                      Text(
                        widget.label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared page background for the glass shell.
///
/// The blur needs something behind it — over a flat scaffold colour a frosted
/// surface is indistinguishable from a solid one. This lays down a soft tint
/// of the theme colour at the bottom of the page for the bar to pick up.
class GlassBackdrop extends StatelessWidget {
  final Widget child;

  const GlassBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final primary = AppTheme.effectivePrimary;

    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 190,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    primary.withValues(alpha: 0),
                    primary.withValues(alpha: dark ? 0.10 : 0.07),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
