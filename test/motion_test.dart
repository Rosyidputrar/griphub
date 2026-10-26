import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/ui/message_views.dart';
import 'package:griphub_agent/ui/theme.dart';

void main() {
  Widget app(Widget child, {required bool reduced}) => MaterialApp(
    theme: ThemeData(extensions: const [Palette.dark]),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(body: child),
    ),
  );

  testWidgets('Motion.of is instant when the system removes animations', (tester) async {
    late Duration on, off;
    await tester.pumpWidget(app(Builder(builder: (c) {
      off = Motion.of(c, Motion.normal);
      return const SizedBox();
    }), reduced: true));
    await tester.pumpWidget(app(Builder(builder: (c) {
      on = Motion.of(c, Motion.normal);
      return const SizedBox();
    }), reduced: false));
    expect(off, Duration.zero);
    expect(on, Motion.normal);
  });

  testWidgets('the activity line keeps still with animations off', (tester) async {
    await tester.pumpWidget(app(const AgentActivity(label: 'Running bash…'), reduced: true));
    // A repeating animation would never settle.
    await tester.pumpAndSettle();
    expect(find.text('Running bash…'), findsOneWidget);
  });

  testWidgets('the activity line pulses otherwise', (tester) async {
    await tester.pumpWidget(app(const AgentActivity(label: 'Thinking…'), reduced: false));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.hasRunningAnimations, isTrue);
  });
}
