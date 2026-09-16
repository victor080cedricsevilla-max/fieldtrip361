import 'package:fieldtrip361/views/auth/terms_agreement_box.dart';
import 'package:fieldtrip361/views/auth/terms_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hosts the panel the way the sign-up form does: inside a scrolling page, so
/// the test also covers the nested-scroll case that a phone hits.
Widget _host({
  required bool accepted,
  required ValueChanged<bool> onAcceptedChanged,
}) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(30),
          child: TermsAgreementBox(
            accepted: accepted,
            onAcceptedChanged: onAcceptedChanged,
          ),
        ),
      ),
    );

Finder get _panelScrollable => find.descendant(
      of: find.byType(TermsAgreementBox),
      matching: find.byType(Scrollable),
    );

Checkbox _checkbox(WidgetTester tester) =>
    tester.widget<Checkbox>(find.byType(Checkbox));

/// Drags the notice to its very bottom. `scrollUntilVisible` stops as soon as
/// the last block is on screen, which is a little short of the end.
Future<void> _readToEnd(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text(kTermsClosing),
    300,
    scrollable: _panelScrollable,
  );
  await tester.drag(_panelScrollable, const Offset(0, -400));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the tick box is locked until the notice has been scrolled',
      (tester) async {
    var accepted = false;
    await tester.pumpWidget(
      _host(accepted: false, onAcceptedChanged: (v) => accepted = v),
    );

    expect(_checkbox(tester).onChanged, isNull);
    expect(find.textContaining('Scroll through the whole notice'), findsOneWidget);

    // Tapping early must not agree to anything on the reader's behalf.
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(accepted, isFalse);
  });

  testWidgets('reaching the end unlocks the tick box', (tester) async {
    var accepted = false;
    await tester.pumpWidget(
      _host(accepted: false, onAcceptedChanged: (v) => accepted = v),
    );

    await _readToEnd(tester);

    expect(_checkbox(tester).onChanged, isNotNull);
    expect(find.textContaining('You have reached the end'), findsOneWidget);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(accepted, isTrue);
  });

  testWidgets('tapping the locked row points the reader back at the notice',
      (tester) async {
    await tester.pumpWidget(_host(accepted: false, onAcceptedChanged: (_) {}));

    await tester.tap(find.textContaining('I have read and agree'));
    await tester.pump();

    final hint = tester.widget<Text>(
      find.textContaining('Scroll through the whole notice'),
    );
    expect(hint.style?.fontWeight, FontWeight.w700);
  });

  testWidgets('the whole notice is rendered, heading by heading',
      (tester) async {
    await tester.pumpWidget(_host(accepted: false, onAcceptedChanged: (_) {}));

    // Every section must be reachable by scrolling — a heading that never
    // renders is a clause nobody can consent to.
    for (final section in kTermsSections) {
      await tester.scrollUntilVisible(
        find.text(section.heading),
        300,
        scrollable: _panelScrollable,
      );
      expect(find.text(section.heading), findsOneWidget);
    }
  });
}
