import 'package:fieldtrip361/widgets/animated_tab_view.dart';
import 'package:fieldtrip361/widgets/glass_nav_bar.dart';
import 'package:fieldtrip361/widgets/glass_nav_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reproduces the layout the nav shell actually uses: a Column that gives a
/// tight height and a loose width. Every page rendered blank under it, because
/// the Stack sized itself to its zero-sized offstage children.
Widget _inNavShell(Widget child) => MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            const SizedBox(height: 20), // stands in for the emergency banner
            Expanded(child: child),
          ],
        ),
      ),
    );

void main() {
  group('AnimatedTabView', () {
    testWidgets('fills its parent even though every layer is positioned',
        (tester) async {
      await tester.pumpWidget(_inNavShell(
        const AnimatedTabView(
          index: 0,
          children: [
            ColoredBox(color: Color(0xFF00C4B4), child: Text('one')),
            ColoredBox(color: Color(0xFFFFB74D), child: Text('two')),
          ],
        ),
      ));

      final screen = tester.getSize(find.byType(Scaffold));
      final view = tester.getSize(find.byType(AnimatedTabView));
      expect(view.width, screen.width,
          reason: 'a zero-width view is what made every tab look blank');
      expect(view.height, greaterThan(0));
    });

    testWidgets('shows the selected page and hides the rest', (tester) async {
      await tester.pumpWidget(_inNavShell(
        const AnimatedTabView(
          index: 0,
          children: [Text('one'), Text('two'), Text('three')],
        ),
      ));

      // All three stay mounted — that is what preserves their state — but only
      // the selected one is on screen. skipOffstage tells the two apart.
      expect(find.text('one'), findsOneWidget);
      expect(find.text('two'), findsNothing);
      expect(find.text('two', skipOffstage: false), findsOneWidget);
      expect(find.text('three', skipOffstage: false), findsOneWidget);
    });

    testWidgets('keeps page state across a tab switch', (tester) async {
      Widget shell(int index) => _inNavShell(
            AnimatedTabView(
              index: index,
              children: const [_Counter(), Text('other')],
            ),
          );

      await tester.pumpWidget(shell(0));
      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();
      expect(find.text('count: 1'), findsOneWidget);

      await tester.pumpWidget(shell(1));
      await tester.pumpAndSettle();
      await tester.pumpWidget(shell(0));
      await tester.pumpAndSettle();

      expect(find.text('count: 1'), findsOneWidget,
          reason: 'switching tabs must not rebuild the page from scratch');
    });
  });

  group('nav shell', _shellTests);
}

/// The shell as the dashboards actually build it. Guards the layout end to
/// end: three nested Stacks sit between the scaffold and a page, and any one
/// of them collapsing hides the content while leaving the bar on screen.
void _shellTests() {
  testWidgets('GlassNavScaffold gives its pages the full screen', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: GlassNavScaffold(
        currentIndex: 0,
        onTap: (_) {},
        items: const [
          GlassNavItem(icon: Icons.route_outlined, activeIcon: Icons.route, label: 'Trips'),
          GlassNavItem(icon: Icons.person_outline, activeIcon: Icons.person, label: 'Profile'),
        ],
        pages: const [
          Scaffold(body: Center(child: Text('trips page'))),
          Scaffold(body: Center(child: Text('profile page'))),
        ],
      ),
    ));

    expect(find.text('trips page'), findsOneWidget);
    final page = tester.getSize(find.text('trips page'));
    expect(page.width, greaterThan(0),
        reason: 'the page rendered blank behind a correctly drawn nav bar');

    // The bar is drawn and reachable.
    expect(find.text('Trips'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
  });
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _n = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('count: $_n'),
        ElevatedButton(onPressed: () => setState(() => _n++), child: const Text('+')),
      ],
    );
  }
}
