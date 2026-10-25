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

Future<void> _app(WidgetTester tester, {bool vetoPop = false}) async {
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
