import 'package:flutter/material.dart';

import 'animated_tab_view.dart';
import 'glass_emergency_button.dart';
import 'glass_nav_bar.dart';

/// The shell every tabbed dashboard sits in.
///
/// Student, teacher and parent each had their own copy of the same scaffold,
/// nav bar and emergency button. One shell means a change to the navigation
/// lands in all three at once, and none of them can drift.
///
/// The bar floats over the page rather than taking a slot below it, so the
/// content scrolls beneath the frosted surface. That is what makes the blur
/// visible — over a fixed strip of background there is nothing to frost. Pages
/// that scroll should leave [bottomInset] of padding at the end of their list
/// so the final row is not left under the bar.
class GlassNavScaffold extends StatelessWidget {
  final List<Widget> pages;
  final List<GlassNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  /// Pinned above the pages, below the bar — the emergency banner lives here.
  final Widget? banner;

  /// Shown centred just above the nav bar.
  final Widget? floatingAction;

  const GlassNavScaffold({
    super.key,
    required this.pages,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.banner,
    this.floatingAction,
  });

  /// Clearance a scrolling page should leave at its bottom for the floating bar.
  static const double bottomInset = 96;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The bar is drawn inside the body so pages can run underneath it.
      extendBody: true,
      body: GlassBackdrop(
        child: Stack(
          children: [
            Positioned.fill(
              child: Column(
                children: [
                  if (banner != null) banner!,
                  Expanded(
                    child: AnimatedTabView(index: currentIndex, children: pages),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (floatingAction != null) floatingAction!,
                    GlassNavBar(
                      items: items,
                      currentIndex: currentIndex,
                      onTap: onTap,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
