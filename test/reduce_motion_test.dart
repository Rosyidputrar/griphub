// "Reduce animations" (Settings, Appearance): on by default on a phone Android marks as low on memory, as ArchiveTune
// does; with it on, pages and sheets take no time and nothing moves in between. The user's own choice wins.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/ui/predictive_back.dart';
import 'package:griphub_agent/ui/sheet.dart';
import 'package:griphub_agent/ui/theme.dart';

void main() {
  final look = Appearance.instance;
  setUp(() {
    look
      ..reduceMotion = null
      ..lowRamDevice = false;
  });
  tearDown(() {
    look
      ..reduceMotion = null
      ..lowRamDevice = false;
  });

  test('the default follows the phone; the user\'s choice wins either way', () {
    expect(look.animationsOff, isFalse);
    look.setLowRamDevice();
    expect(look.animationsOff, isTrue, reason: 'a low-memory phone starts with animations off');
    look.reduceMotion = false;
    expect(look.animationsOff, isFalse, reason: 'turned back on by the user');
    look
      ..lowRamDevice = false
      ..reduceMotion = true;
    expect(look.animationsOff, isTrue);
  });

  test('the page builder takes no time when animations are off', () {
    expect(const SmoothPageTransitions(instant: true).transitionDuration, Duration.zero);
    expect(const SmoothPageTransitions(instant: true).reverseTransitionDuration, Duration.zero);
    look.reduceMotion = true;
    final b = buildTheme(Brightness.light).pageTransitionsTheme.builders[TargetPlatform.android]!;
    expect(b.transitionDuration, Duration.zero);
    look.reduceMotion = null;
    final on = buildTheme(Brightness.light).pageTransitionsTheme.builders[TargetPlatform.android]!;
    expect(on.transitionDuration, const Duration(milliseconds: 250));
  });

  Future<BuildContext> app(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: look.animationsOff),
          child: child!,
        ),
        home: Builder(
          builder: (c) {
            ctx = c;
            return const Scaffold(body: Text('home'));
          },
        ),
      ),
    );
    return ctx;
  }

  testWidgets('with it on, a page is there on the next frame and gone on the next', (tester) async {
    look.reduceMotion = true;
    final ctx = await app(tester);
    Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Center(child: Text('page')))));
    await tester.pump();
    await tester.pump();
    expect(tester.getCenter(find.text('page')).dx, 400, reason: 'in place, no slide');
    expect(find.text('home'), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
    Navigator.of(tester.element(find.text('page'))).pop();
    await tester.pump();
    await tester.pump();
    expect(find.text('page'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('with it on, a sheet appears and goes at once', (tester) async {
    look.reduceMotion = true;
    final ctx = await app(tester);
    showSheet<void>(context: ctx, builder: (_) => const SizedBox(height: 200, child: Text('sheet')));
    await tester.pump();
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.getRect(find.byType(BottomSheet)).bottom, 600);
    Navigator.of(tester.element(find.text('sheet'))).pop();
    await tester.pump();
    await tester.pump();
    expect(find.text('sheet'), findsNothing);
  });

  testWidgets('with it off, a page still slides (the default)', (tester) async {
    final ctx = await app(tester);
    Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Center(child: Text('page')))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getCenter(find.text('page')).dx, greaterThan(400));
    await tester.pumpAndSettle();
  });
}
