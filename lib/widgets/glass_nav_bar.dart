import 'dart:ui';

import 'package:flutter/material.dart';

import '../config/theme.dart';

/// One destination in a [GlassNavBar].
class GlassNavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const GlassNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}

/// A floating, frosted pill navigation bar.
///
/// The bar sits above the bottom edge rather than against it, so the page
/// scrolls under a translucent surface instead of stopping at an opaque strip.
/// The selected item is marked by a single pill that slides between slots —
/// one moving indicator reads as continuous, where a per-item highlight that
/// switches on and off reads as a flash.
///
/// Every slot is the same width and the layout never changes with selection,
/// which is what keeps the icons from shifting as tabs change.
class GlassNavBar extends StatelessWidget {
  final List<GlassNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  /// Horizontal inset from the screen edge.
  final double margin;

  const GlassNavBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.margin = 16,
  });

  static const _duration = Duration(milliseconds: 280);
  static const _curve = Curves.easeOutCubic;

  @override
  Widget build(BuildContext context) {
    final glass = GlassTokens.of(context);
    final primary = AppTheme.effectivePrimary;
    // Honour the OS "reduce motion" setting: the indicator still moves, it
    // just arrives immediately instead of travelling.
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final duration = reduceMotion ? Duration.zero : _duration;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        margin,
        0,
        margin,
        // Sit clear of the gesture bar on iPhone and of the navigation bar on
        // Android, with a floor so it still floats on a device with neither.
        12 + MediaQuery.paddingOf(context).bottom * 0.5,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(34),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            height: 68,
            decoration: BoxDecoration(
              color: glass.surface,
              borderRadius: BorderRadius.circular(34),
              border: Border.all(color: glass.border, width: 1),
              boxShadow: [
                BoxShadow(color: glass.shadow, blurRadius: 24, offset: const Offset(0, 8)),
              ],
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final slot = constraints.maxWidth / items.length;
                return Stack(
                  children: [
                    // The sliding indicator, behind the row so it never
                    // intercepts a tap meant for a tab.
                    AnimatedPositioned(
                      duration: duration,
                      curve: _curve,
                      left: slot * currentIndex,
                      top: 0,
                      bottom: 0,
                      width: slot,
                      child: Center(
                        child: AnimatedContainer(
                          duration: duration,
                          curve: _curve,
                          width: slot - 10,
                          height: 52,
                          decoration: BoxDecoration(
                            color: glass.activePill,
                            borderRadius: BorderRadius.circular(26),
                            boxShadow: [
                              BoxShadow(
                                color: primary.withValues(alpha: 0.28),
                                blurRadius: 18,
                                spreadRadius: -4,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        for (var i = 0; i < items.length; i++)
                          Expanded(
                            child: _NavSlot(
                              item: items[i],
                              selected: i == currentIndex,
                              duration: duration,
                              curve: _curve,
                              glass: glass,
                              primary: primary,
                              onTap: () => onTap(i),
                            ),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _NavSlot extends StatelessWidget {
  final GlassNavItem item;
  final bool selected;
  final Duration duration;
  final Curve curve;
  final GlassTokens glass;
  final Color primary;
  final VoidCallback onTap;

  const _NavSlot({
    required this.item,
    required this.selected,
    required this.duration,
    required this.curve,
    required this.glass,
    required this.primary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = selected ? primary : glass.idleIcon;

    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(26),
        splashColor: primary.withValues(alpha: 0.10),
        highlightColor: Colors.transparent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // The lift is a translation, not a size change: growing the icon
            // would reflow the column and nudge the label on every switch.
            AnimatedSlide(
              duration: duration,
              curve: curve,
              offset: Offset(0, selected ? -0.06 : 0),
              child: AnimatedScale(
                duration: duration,
                curve: curve,
                scale: selected ? 1.12 : 1.0,
                child: AnimatedSwitcher(
                  duration: duration,
                  transitionBuilder: (child, anim) =>
                      FadeTransition(opacity: anim, child: child),
                  child: Icon(
                    selected ? item.activeIcon : item.icon,
                    key: ValueKey(selected),
                    size: 22,
                    color: iconColor,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            AnimatedDefaultTextStyle(
              duration: duration,
              curve: curve,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.1,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? primary : glass.idleLabel,
              ),
              child: Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}
