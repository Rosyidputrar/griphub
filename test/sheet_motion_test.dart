// Bottom sheet motion after ArchiveTune: springs with no bounce (400 to settle, 200 to close with Back), a fling past
// 250 physical px/s, the nearest resting place otherwise, and a list that scrolls to its top before the sheet follows.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/ui/predictive_back.dart';
import 'package:griphub_agent/ui/sheet.dart';

Future<void> _send(WidgetTester tester, String method, [Map<String, dynamic>? args]) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
    (_) {},
  );
}

Map<String, dynamic> _event(double progress) => {
  'touchOffset': <double>[390 - progress * 300, 300],
  'progress': progress,
  'swipeEdge': 1,
};

late BuildContext _ctx;

/// An 800 × 600 screen at [dpr] physical pixels per logical one.
Future<void> _app(WidgetTester tester, {bool reduced = false, double dpr = 1}) async {
  tester.view
    ..devicePixelRatio = dpr
    ..physicalSize = Size(800 * dpr, 600 * dpr);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: reduced);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  tester.binding.addObserver(PredictiveBack.instance);
  addTearDown(() => tester.binding.removeObserver(PredictiveBack.instance));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(bottomSheetTheme: const BottomSheetThemeData(showDragHandle: true)),
      navigatorObservers: [PredictiveBack.instance],
      home: Builder(
        builder: (context) {
          _ctx = context;
          return const Scaffold(body: Text('page'));
        },
      ),
    ),
  );
}

Future<T?> _plain<T>(WidgetTester tester) {
  final f = showSheet<T>(
    context: _ctx,
    isScrollControlled: true,
    builder: (_) => const SizedBox(height: 300, child: Center(child: Text('sheet'))),
  );
  return f;
}

double _top(WidgetTester tester) => tester.getTopLeft(find.byKey(const Key('body'))).dy;

/// A sheet with a 40-row list, opening at half the room and growing to all of it.
Future<void> _list(WidgetTester tester) async {
  showSheet<void>(
    context: _ctx,
    isScrollControlled: true,
    builder: (_) => SheetExtent(
      initial: 0.5,
      builder: (context, scroll) => ListView.builder(
        key: const Key('body'),
        controller: scroll,
        itemCount: 40,
        itemBuilder: (_, i) => SizedBox(height: 50, child: Text('row $i')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('the springs are ArchiveTune\'s: critically damped, 400 and 200', () {
    for (final (d, k) in [(SheetMotion.normal, 400.0), (SheetMotion.soft, 200.0)]) {
      expect(d.mass, 1);
      expect(d.stiffness, k);
      expect(d.damping, closeTo(2 * math.sqrt(d.mass * k), 1e-9), reason: 'critically damped: no bounce');
      // Never past the end.
      final sim = SheetMotion.spring(d, 0, 1, 0, 0.001);
      var peak = 0.0;
      for (var t = 0.0; t < 3; t += 0.004) {
        peak = peak > sim.x(t) ? peak : sim.x(t);
      }
      expect(peak, lessThanOrEqualTo(1 + 1e-9));
      expect(sim, isA<SpringSimulation>());
    }
    // The softer one takes longer.
    double settle(SpringDescription d) {
      final sim = SheetMotion.spring(d, 1, 0, 0, 0.001);
      var t = 0.0;
      while (!sim.isDone(t)) {
        t += 0.001;
      }
      return t;
    }

    expect(settle(SheetMotion.soft), greaterThan(settle(SheetMotion.normal)));
  });

  test('the folded and unfolded crossfade', () {
    expect(SheetMotion.unfoldedAlpha(0), 0);
    expect(SheetMotion.unfoldedAlpha(0.25), 0);
    expect(SheetMotion.unfoldedAlpha(0.375), closeTo(0.5, 1e-9));
    expect(SheetMotion.unfoldedAlpha(0.5), 1);
    expect(SheetMotion.foldedAlpha(0), 1);
    expect(SheetMotion.foldedAlpha(0.125), closeTo(0.5, 1e-9));
    expect(SheetMotion.foldedAlpha(0.25), 0);
  });

  testWidgets('opens with a spring that never overshoots, and lands exactly', (tester) async {
    await _app(tester);
    _plain<void>(tester);
    await tester.pump();
    final rest = 600 - 300 - kMinInteractiveDimension;
    // Frame by frame, the sheet's top never goes above where it rests.
    var highest = 600.0;
    var frames = 0;
    while (tester.binding.hasScheduledFrame && frames < 200) {
      await tester.pump(const Duration(milliseconds: 8));
      final top = tester.getRect(find.byType(BottomSheet)).top;
      highest = math.min(highest, top);
      frames++;
    }
    expect(frames, lessThan(200), reason: 'settles');
    expect(frames, greaterThan(10), reason: 'it moves, rather than appearing');
    expect(tester.getRect(find.byType(BottomSheet)).top, rest, reason: 'lands exactly');
    expect(highest, greaterThanOrEqualTo(rest), reason: 'no bounce above');
  });

  testWidgets('a slow drag let go past half its height stays; under half closes', (tester) async {
    await _app(tester);
    _plain<void>(tester);
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    final top = tester.getRect(sheet).top;
    final h = 600 - top;
    // Slowly, 40% of the way down: back up.
    final g = await tester.startGesture(tester.getCenter(find.text('sheet')));
    for (var i = 0; i < 20; i++) {
      await g.moveBy(Offset(0, h * 0.4 / 20));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 200)); // still, so no speed
    await g.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(sheet).top, top);
    // Slowly, 60%: closes.
    final g2 = await tester.startGesture(tester.getCenter(find.text('sheet')));
    for (var i = 0; i < 20; i++) {
      await g2.moveBy(Offset(0, h * 0.6 / 20));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 200));
    await g2.up();
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsNothing);
  });

  testWidgets('a light flick down closes it, even a short one; a flick up does not', (tester) async {
    await _app(tester);
    _plain<void>(tester);
    await tester.pumpAndSettle();
    // Flutter needs 700 px/s or over half the height; ArchiveTune 250 physical px/s from anywhere. 300 px/s for 30 px
    // (a tenth of the height) closes only by the speed rule.
    await tester.fling(find.text('sheet'), const Offset(0, -40), 300);
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsOneWidget);
    await tester.fling(find.text('sheet'), const Offset(0, 30), 300);
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsNothing);
  });

  testWidgets('under 250 physical px/s it is not a fling: the nearest resting place', (tester) async {
    await _app(tester);
    _plain<void>(tester);
    await tester.pumpAndSettle();
    await tester.fling(find.text('sheet'), const Offset(0, 30), 200);
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsOneWidget);
  });

  testWidgets('the speed is in physical pixels: on a 3x screen 100 logical px/s is a fling', (tester) async {
    await _app(tester, dpr: 3);
    _plain<void>(tester);
    await tester.pumpAndSettle();
    await tester.fling(find.text('sheet'), const Offset(0, 30), 100);
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsNothing, reason: '300 physical px/s');
  });

  testWidgets('a fling hands its speed to the spring: no stop and restart', (tester) async {
    await _app(tester);
    _plain<void>(tester);
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    // 60 px down in 60 ms (1000 px/s), the time on each move as a finger reports it.
    final g = await tester.startGesture(tester.getCenter(find.text('sheet')));
    for (var i = 1; i <= 6; i++) {
      await g.moveBy(const Offset(0, 10), timeStamp: Duration(milliseconds: 10 * i));
      await tester.pump(const Duration(milliseconds: 10));
    }
    final atRelease = tester.getRect(sheet).top;
    await g.up(timeStamp: const Duration(milliseconds: 60));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    final next = tester.getRect(sheet).top;
    // About 1000 px/s down: the first frame after release moves on by several pixels, in the same direction.
    expect(next - atRelease, greaterThan(5));
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsNothing);
  });

  testWidgets('Back closes with the softer spring', (tester) async {
    await _app(tester);
    _plain<void>(tester);
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    final top = tester.getRect(sheet).top;
    Navigator.of(tester.element(find.text('sheet'))).maybePop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16)); // the spring's first frame: its clock starts here
    await tester.pump(const Duration(milliseconds: 100));
    final moved = tester.getRect(sheet).top - top;
    // Soft spring from rest after 100 ms: x = 1 - (1 + ωt)e^(-ωt), ω = √200.
    const w = 14.142135623730951;
    final expected = (600 - top) * (1 - (1 + w * 0.1) * 0.24311673443421403);
    expect(moved, closeTo(expected, 3));
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsNothing);
  });

  testWidgets('a predictive back moves it from where it rests, and cancelling springs it back', (tester) async {
    await _app(tester);
    _plain<void>(tester);
    await tester.pumpAndSettle();
    final sheet = find.byType(BottomSheet);
    final top = tester.getRect(sheet).top;
    await _send(tester, 'startBackGesture', _event(0));
    await tester.pump();
    expect(tester.getRect(sheet).top, closeTo(top, 0.5), reason: 'no jump at the start');
    await _send(tester, 'updateBackGestureProgress', _event(1));
    await tester.pump();
    final moved = tester.getRect(sheet).top;
    expect(moved, greaterThan(top + 20));
    expect(moved, lessThan(600 - 50), reason: 'part of the way');
    await _send(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();
    expect(tester.getRect(sheet).top, top);
    expect(tester.state<NavigatorState>(find.byType(Navigator).first).userGestureInProgress, isFalse);
    await _send(tester, 'startBackGesture', _event(0));
    await _send(tester, 'updateBackGestureProgress', _event(0.5));
    await tester.pump();
    await _send(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsNothing);
  });

  testWidgets('a sheet that refuses to close (PopScope) springs back from a drag', (tester) async {
    await _app(tester);
    var asked = 0;
    showSheet<void>(
      context: _ctx,
      isScrollControlled: true,
      builder: (_) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) => asked++,
        child: const SizedBox(height: 300, child: Center(child: Text('sheet'))),
      ),
    );
    await tester.pumpAndSettle();
    final top = tester.getRect(find.byType(BottomSheet)).top;
    await tester.fling(find.text('sheet'), const Offset(0, 200), 1500);
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsOneWidget);
    expect(tester.getRect(find.byType(BottomSheet)).top, top);
    expect(asked, 1, reason: 'told, as a Back would');
  });

  group('a list inside', () {
    testWidgets('pulled up, the sheet grows first, then the list scrolls', (tester) async {
      await _app(tester);
      await _list(tester);
      final half = _top(tester);
      expect(find.text('row 0'), findsOneWidget);
      // A slow pull up by 100 (under half-way to the top): the sheet follows, and goes back to its first height.
      final g = await tester.startGesture(tester.getCenter(find.text('row 2')));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(0, -12));
        await tester.pump(const Duration(milliseconds: 40));
      }
      final grown = _top(tester);
      expect(grown, lessThan(half - 50), reason: 'the sheet came up with the finger');
      expect(tester.getTopLeft(find.text('row 0')).dy, grown, reason: 'the list did not scroll');
      await g.up();
      await tester.pumpAndSettle();
      expect(_top(tester), closeTo(half, 0.5), reason: 'nearest resting place');
      // Past half-way: it goes all the way up.
      final g2 = await tester.startGesture(tester.getCenter(find.text('row 2')));
      for (var i = 0; i < 20; i++) {
        await g2.moveBy(const Offset(0, -10));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await g2.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(BottomSheet)).top, 0, reason: 'expanded to the whole room');
      expect(tester.getTopLeft(find.text('row 0')).dy, _top(tester), reason: 'the list did not scroll yet');
      // All the way up, the list scrolls.
      final top = _top(tester);
      await tester.drag(find.text('row 5'), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(_top(tester), top, reason: 'the sheet stays');
      expect(find.text('row 0'), findsNothing, reason: 'the list scrolled');
    });

    testWidgets('pulled down, the list goes back to its top before the sheet comes down', (tester) async {
      await _app(tester);
      await _list(tester);
      await tester.fling(find.text('row 2'), const Offset(0, -150), 1500);
      await tester.pumpAndSettle();
      final top = _top(tester);
      await tester.drag(find.text('row 5'), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(find.text('row 0'), findsNothing);
      // 200 down: only the list moves, it is not at its top yet.
      await tester.drag(find.text('row 8'), const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(_top(tester), top);
      // Down again past its top: the rest pulls the sheet.
      final g = await tester.startGesture(tester.getCenter(find.text('row 3')));
      for (var i = 0; i < 20; i++) {
        await g.moveBy(const Offset(0, 15));
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(tester.getTopLeft(find.text('row 0')).dy, greaterThan(top), reason: 'at its top, then the sheet followed');
      await tester.pump(const Duration(milliseconds: 200));
      await g.up();
      await tester.pumpAndSettle();
      expect(find.text('row 0'), findsOneWidget);
    });

    testWidgets('the top corners fold away as it fills the screen, and come back', (tester) async {
      await _app(tester);
      showSheet<void>(
        context: _ctx,
        isScrollControlled: true,
        builder: (_) => SheetExtent(
          initial: 0.5,
          builder: (context, scroll) => ListView.builder(
            key: const Key('body'),
            controller: scroll,
            itemCount: 40,
            itemBuilder: (_, i) => SizedBox(height: 50, child: Text('row $i')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      double corner() {
        final m = tester.widget<Material>(find.descendant(of: find.byType(BottomSheet), matching: find.byType(Material)).first);
        final rect = tester.getRect(find.byType(BottomSheet));
        final path = m.shape!.getOuterPath(rect);
        // How far in from the top-left corner the outline starts on the top edge.
        for (var x = 0.0; x < 40; x += 0.5) {
          if (path.contains(rect.topLeft + Offset(x, 0.5))) return x;
        }
        return 40;
      }

      expect(corner(), greaterThan(10), reason: 'rounded at its first height');
      final g = await tester.startGesture(tester.getCenter(find.text('row 2')));
      for (var i = 0; i < 6; i++) {
        await g.moveBy(const Offset(0, -25));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await g.up();
      await tester.fling(find.text('row 2'), const Offset(0, -150), 1500);
      await tester.pumpAndSettle();
      expect(corner(), lessThan(1), reason: 'square at the top of the screen');
      await tester.fling(find.text('row 2'), const Offset(0, 150), 1500);
      await tester.pumpAndSettle();
      expect(corner(), greaterThan(10), reason: 'rounded again');
    });

    testWidgets('Back from the expanded height goes back to the first height, then closes', (tester) async {
      await _app(tester);
      await _list(tester);
      final half = _top(tester);
      await tester.fling(find.text('row 2'), const Offset(0, -150), 1500);
      await tester.pumpAndSettle();
      expect(_top(tester), lessThan(half));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_top(tester), closeTo(half, 0.5), reason: 'the top layer (the expanded height) closes first');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('row 0'), findsNothing);
    });

    testWidgets('a fast flick down from the expanded height goes to the first height, not closed', (tester) async {
      await _app(tester);
      await _list(tester);
      final half = _top(tester);
      await tester.fling(find.text('row 2'), const Offset(0, -150), 1500);
      await tester.pumpAndSettle();
      // 150 px at 1500 px/s: closing would take it from the top to the bottom; ArchiveTune stops at the first height.
      await tester.fling(find.text('row 2'), const Offset(0, 150), 1500);
      await tester.pumpAndSettle();
      expect(find.text('row 0'), findsOneWidget, reason: 'still open');
      expect(_top(tester), closeTo(half, 0.5));
      // And from the first height, a flick down closes it.
      await tester.fling(find.text('row 2'), const Offset(0, 60), 1500);
      await tester.pumpAndSettle();
      expect(find.text('row 0'), findsNothing);
    });
  });

  testWidgets('with animations off it appears and goes at once', (tester) async {
    await _app(tester, reduced: true);
    _plain<void>(tester);
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(find.byType(BottomSheet)).top, 600 - 300 - kMinInteractiveDimension);
    Navigator.of(tester.element(find.text('sheet'))).maybePop();
    await tester.pump();
    await tester.pump();
    expect(find.text('sheet'), findsNothing);
  });

  testWidgets('a result comes back as from showModalBottomSheet', (tester) async {
    await _app(tester);
    final f = showSheet<String>(
      context: _ctx,
      builder: (c) => TextButton(onPressed: () => Navigator.pop(c, 'picked'), child: const Text('pick')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('pick'));
    await tester.pumpAndSettle();
    expect(await f, 'picked');
  });
}
