import 'package:griphub_agent/ui/predictive_back.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
  'swipeEdge': 1, // right
};

/// How opaque [text]'s page is drawn (the transition's Opacity nearest to it).
double _opacity(WidgetTester tester, String text) => tester
    .widgetList<Opacity>(find.ancestor(of: find.text(text), matching: find.byType(Opacity)))
    .fold(1.0, (o, w) => o * w.opacity);

Future<void> _app(WidgetTester tester, {bool vetoPop = false, RouteSettings? bSettings}) async {
  tester.binding.addObserver(PredictiveBack.instance);
  addTearDown(() => tester.binding.removeObserver(PredictiveBack.instance));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        pageTransitionsTheme: const PageTransitionsTheme(builders: {TargetPlatform.android: SmoothPageTransitions()}),
      ),
      navigatorObservers: [PredictiveBack.instance],
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  settings: bSettings,
                  builder: (_) => PopScope(
                    canPop: !vetoPop,
                    child: const Scaffold(body: Center(child: Text('page b'))),
                  ),
                ),
              ),
              child: const Text('push'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('push'));
  await tester.pumpAndSettle();
}

void main() {
  group('page motion (ArchiveTune)', () {
    const width = 800.0; // the test window's logical width

    test('the durations and the curve', () {
      const b = SmoothPageTransitions();
      expect(b.transitionDuration, const Duration(milliseconds: 250));
      expect(b.reverseTransitionDuration, const Duration(milliseconds: 200));
      expect(SmoothPageTransitions.curve, Curves.fastOutSlowIn);
    });

    test('geometry at each moment, without a gesture', () {
      ({double dx, double opacity}) at(double v, AnimationStatus s, [double u = 0, AnimationStatus us = AnimationStatus.dismissed, bool nested = false]) =>
          SmoothPageTransitions.place(value: v, status: s, under: u, underStatus: us, nested: nested);
      const fwd = AnimationStatus.forward, rev = AnimationStatus.reverse, done = AnimationStatus.completed;
      // Pushed: from the right edge, the whole width, fading in.
      expect(at(0, fwd), (dx: 1.0, opacity: 0.0));
      expect(at(1, done), (dx: 0.0, opacity: 1.0));
      final mid = at(0.5, fwd);
      expect(mid.dx, closeTo(1 - Curves.fastOutSlowIn.transform(0.5), 1e-9));
      expect(mid.opacity, closeTo(Curves.fastOutSlowIn.transform(0.5), 1e-9));
      // Covered: out to the left, the whole width, fading out; done by 200 of the 250 ms.
      expect(at(1, done, 0.8, fwd), (dx: -1.0, opacity: 0.0));
      expect(at(1, done, 0.4, fwd).dx, closeTo(-Curves.fastOutSlowIn.transform(0.5), 1e-9));
      // Popped: never fades, slides the whole width off to the right.
      for (final v in [1.0, 0.75, 0.5, 0.25, 0.01]) {
        final r = at(v, rev);
        expect(r.opacity, 1, reason: 'a page going back is never faded (at $v)');
        expect(r.dx, closeTo(Curves.fastOutSlowIn.transform(1 - v), 1e-9));
      }
      expect(at(0, rev).dx, 1, reason: 'all the way off-screen');
      // Uncovered by a pop: in from the left, the whole width, no fade.
      expect(at(1, done, 1, rev), (dx: -1.0, opacity: 1.0));
      expect(at(1, done, 0.5, rev).opacity, 1);
      expect(at(1, done, 0, rev), (dx: 0.0, opacity: 1.0));
      // Nested (search results): half the width and a fade, both ways.
      expect(at(1, done, 0.8, fwd, true), (dx: -0.5, opacity: 0.0));
      expect(at(1, done, 1, rev, true), (dx: -0.5, opacity: 0.0));
      expect(at(1, done, 0, rev, true), (dx: 0.0, opacity: 1.0));
    });

    testWidgets('push: both pages travel the whole width, the new one fades in, the old one out', (tester) async {
      await _app(tester);
      // _app pushed and settled; go back and push again, watching it.
      await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 125));
      final b = tester.getCenter(find.text('page b')).dx;
      final a = tester.getCenter(find.text('push')).dx;
      final t = Curves.fastOutSlowIn.transform(0.5);
      expect(b, closeTo(width / 2 + width * (1 - t), 1.5), reason: 'half-way on the curve, from the right edge');
      expect(_opacity(tester, 'page b'), closeTo(t, 0.01));
      final u = Curves.fastOutSlowIn.transform(0.5 / 0.8);
      expect(a, closeTo(width / 2 - width * u, 1.5), reason: 'the page underneath leaves to the left, all the way');
      expect(_opacity(tester, 'push'), closeTo(1 - u, 0.01));
      await tester.pump(const Duration(milliseconds: 125));
      expect(tester.getCenter(find.text('page b')).dx, closeTo(width / 2, 0.5));
      expect(_opacity(tester, 'page b'), 1);
      await tester.pump(const Duration(milliseconds: 16)); // the route settles on the next frame
      expect(find.text('push'), findsNothing, reason: 'the page underneath is fully covered at 250 ms');
    });

    testWidgets('pop: the page slides fully off to the right at full opacity, the one underneath comes back from the left', (tester) async {
      await _app(tester);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      var last = width / 2;
      for (var ms = 20; ms < 200; ms += 20) {
        await tester.pump(const Duration(milliseconds: 20));
        final b = tester.getCenter(find.text('page b')).dx;
        expect(_opacity(tester, 'page b'), 1, reason: 'no fade at $ms ms');
        expect(_opacity(tester, 'push'), 1, reason: 'the page coming back is not faded either');
        expect(b, greaterThan(last), reason: 'keeps moving right');
        expect(tester.getCenter(find.text('push')).dx, closeTo(b - width, 1.5), reason: 'the two pages move as one');
        last = b;
      }
      expect(last, greaterThan(width * 1.45), reason: 'nearly all the way off by the last frame');
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 16)); // the route is removed on the next frame
      expect(find.text('page b'), findsNothing, reason: '200 ms');
      expect(tester.getCenter(find.text('push')).dx, width / 2);
    });

    testWidgets('a nested page (search results) moves half the width under the next one, and back', (tester) async {
      await _app(tester);
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.maybePop();
      await tester.pumpAndSettle();
      nav.push(MaterialPageRoute<void>(settings: SmoothPageTransitions.nested, builder: (_) => const Scaffold(body: Center(child: Text('results')))));
      await tester.pumpAndSettle();
      nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Center(child: Text('file')))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 199));
      expect(tester.getCenter(find.text('results')).dx, closeTo(0, 2), reason: 'half the width to the left');
      expect(_opacity(tester, 'results'), closeTo(0, 0.01));
      await tester.pumpAndSettle();
      nav.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final t = Curves.fastOutSlowIn.transform(0.5);
      expect(tester.getCenter(find.text('results')).dx, closeTo(width / 2 - width / 2 * (1 - t), 2));
      expect(_opacity(tester, 'results'), closeTo(t, 0.02), reason: 'fades back in');
      expect(_opacity(tester, 'file'), 1, reason: 'the page going back still never fades');
      await tester.pumpAndSettle();
      expect(tester.getCenter(find.text('results')).dx, width / 2);
    });

    testWidgets('going back while a page is still coming in turns it around, with no jump', (tester) async {
      await _app(tester);
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('push'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final before = tester.getCenter(find.text('page b')).dx;
      final faded = _opacity(tester, 'page b');
      nav.pop();
      await tester.pump();
      expect((tester.getCenter(find.text('page b')).dx - before).abs(), lessThan(1));
      expect((_opacity(tester, 'page b') - faded).abs(), lessThan(0.01));
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getCenter(find.text('page b')).dx, greaterThan(before), reason: 'heads back to the right');
      await tester.pumpAndSettle();
      expect(find.text('page b'), findsNothing);
      expect(tester.getCenter(find.text('push')).dx, width / 2);
    });

    testWidgets('a sheet or menu on top does not move the page underneath', (tester) async {
      await _app(tester);
      final ctx = tester.element(find.text('page b'));
      showModalBottomSheet<void>(context: ctx, builder: (_) => const SizedBox(height: 200, child: Text('sheet')));
      await tester.pumpAndSettle();
      expect(tester.getCenter(find.text('page b')).dx, width / 2);
      expect(_opacity(tester, 'page b'), 1);
    });
  });

  testWidgets('the page follows the gesture and goes back on release', (tester) async {
    await _app(tester);
    await _send(tester, 'startBackGesture', _event(0));
    await tester.pump();
    await _send(tester, 'updateBackGestureProgress', _event(0.5));
    await tester.pump();
    // Shrunk toward the finger, with the page underneath already showing.
    final rect = tester.getRect(find.text('page b'));
    expect(find.text('push'), findsOneWidget);
    expect(PredictiveBack.instance.gesture.value, isNotNull);
    await _send(tester, 'updateBackGestureProgress', _event(0));
    await tester.pump();
    expect(tester.getRect(find.text('page b')).center.dx, greaterThan(rect.center.dx), reason: 'follows back');

    await _send(tester, 'updateBackGestureProgress', _event(0.4));
    await tester.pump();
    final released = tester.getRect(find.text('page b'));
    await _send(tester, 'commitBackGesture');
    await tester.pump();
    // The exit starts exactly where the finger left the page: no jump.
    final atCommit = tester.getRect(find.text('page b'));
    expect((atCommit.center.dx - released.center.dx).abs(), lessThan(1.0));
    expect((atCommit.width - released.width).abs(), lessThan(1.0));
    await tester.pump(const Duration(milliseconds: 16));
    // ... then slides away fast toward the edge, relaxing back to full size as it goes.
    final exiting = tester.getRect(find.text('page b'));
    expect((exiting.center.dx - released.center.dx).abs(), greaterThan(50));
    expect(exiting.width, greaterThanOrEqualTo(released.width - 0.5));
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsNothing);
    expect(find.text('push'), findsOneWidget);
    expect(PredictiveBack.instance.gesture.value, isNull);
    expect(tester.state<NavigatorState>(find.byType(Navigator)).userGestureInProgress, isFalse);
  });

  testWidgets('swiping back to the edge cancels', (tester) async {
    await _app(tester);
    await _send(tester, 'startBackGesture', _event(0));
    await _send(tester, 'updateBackGestureProgress', _event(0.6));
    await tester.pump();
    await _send(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsOneWidget);
    expect(PredictiveBack.instance.gesture.value, isNull);
    // Back to full size.
    expect(tester.getCenter(find.text('page b')), tester.getCenter(find.byType(Navigator)));
  });

  testWidgets('a page that vetoes popping keeps the plain back', (tester) async {
    await _app(tester, vetoPop: true);
    await _send(tester, 'startBackGesture', _event(0));
    await _send(tester, 'updateBackGestureProgress', _event(0.5));
    await tester.pump();
    expect(PredictiveBack.instance.gesture.value, isNull);
    expect(tester.getCenter(find.text('page b')), tester.getCenter(find.byType(Navigator)));
    await _send(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('page b'), findsOneWidget);
  });

  testWidgets('sheets slide part of the way and close on release', (tester) async {
    tester.binding.addObserver(PredictiveBack.instance);
    addTearDown(() => tester.binding.removeObserver(PredictiveBack.instance));
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [PredictiveBack.instance],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => const SizedBox(height: 300, child: Text('sheet')),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final top = tester.getTopLeft(find.text('sheet')).dy;
    await _send(tester, 'startBackGesture', _event(0));
    await _send(tester, 'updateBackGestureProgress', _event(1));
    await tester.pump();
    final moved = tester.getTopLeft(find.text('sheet')).dy;
    expect(moved, greaterThan(top));
    expect(moved, lessThan(top + 300));
    await _send(tester, 'commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.text('sheet'), findsNothing);
  });
}
