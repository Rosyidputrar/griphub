// The app's spinner: comets circling, big for a screen with nothing to show yet and small for a button or a row; in
// the theme's colours or in one colour; turning into a check or a cross when a wait ends; still when the system
// removes animations, and stopped when there is nothing left to move.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/ui/energy.dart';
import 'package:griphub_agent/ui/kit.dart';
import 'package:griphub_agent/ui/theme.dart';

import 'harness.dart';

const _looks = [Look(), Look(dark: true, language: 'id')];

/// Every size and kind of spinner the app uses, and both outcomes once settled.
class _Gallery extends StatefulWidget {
  const _Gallery();

  @override
  State<_Gallery> createState() => _GalleryState();
}

class _GalleryState extends State<_Gallery> {
  bool ended = false;

  void end() => setState(() => ended = true);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget row(List<Widget> children) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, crossAxisAlignment: CrossAxisAlignment.center, children: children),
    );
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          row(const [BusySpinner(size: 12), BusySpinner(), BusySpinner(size: 18), BusySpinner(size: 22)]),
          row([
            BusySpinner(color: p.accent),
            BusySpinner(size: 14, color: p.warning),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(color: p.text, borderRadius: BorderRadius.circular(Radii.lg)),
              child: BusySpinner(color: p.inverse),
            ),
          ]),
          row(const [BusySpinner.page(), EnergySpinner(size: 72)]),
          row([
            EnergySpinner(size: 72, outcome: ended ? EnergyOutcome.success : null),
            EnergySpinner(size: 72, outcome: ended ? EnergyOutcome.failure : null),
            EnergySpinner(size: 18, outcome: ended ? EnergyOutcome.success : null),
          ]),
          Container(
            color: p.surface,
            padding: const EdgeInsets.all(12),
            child: row(const [BusySpinner(), BusySpinner.page()]),
          ),
        ],
      ),
    );
  }
}

Future<void> frames(WidgetTester tester, Duration total) async {
  for (var left = total; left > Duration.zero; left -= const Duration(milliseconds: 50)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() => applyLook(const Look()));

  for (final look in _looks) {
    testWidgets('golden: every spinner, and a check and a cross ${look.name}', (tester) async {
      await pumpLook(tester, look, const _Gallery(), height: 520);
      await frames(tester, const Duration(milliseconds: 700));
      final gallery = tester.state<_GalleryState>(find.byType(_Gallery));
      gallery.end();
      await tester.pump();
      await frames(tester, const Duration(milliseconds: 1400));
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('energy_${look.name}')));
    });

    testWidgets('golden: the big spinner turning into a check, frame by frame ${look.name}', (tester) async {
      final outcome = ValueNotifier<EnergyOutcome?>(null);
      await pumpLook(
        tester,
        look,
        Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: const ValueKey('stage'),
              child: ValueListenableBuilder(
                valueListenable: outcome,
                builder: (_, o, _) => EnergySpinner(size: 120, outcome: o),
              ),
            ),
          ),
        ),
        height: 200,
      );
      await frames(tester, const Duration(milliseconds: 600));
      await expectLater(find.byKey(const ValueKey('stage')), matchesGoldenFile(golden('energy_morph0_${look.name}')));
      outcome.value = EnergyOutcome.success;
      await tester.pump();
      for (final (i, ms) in [(1, 150), (2, 250), (3, 600)]) {
        await frames(tester, Duration(milliseconds: ms));
        await expectLater(find.byKey(const ValueKey('stage')), matchesGoldenFile(golden('energy_morph${i}_${look.name}')));
      }
    });
  }

  testWidgets('it stops asking for frames once the check has formed, and spins again when the wait starts over', (tester) async {
    final outcome = ValueNotifier<EnergyOutcome?>(null);
    await pumpLook(
      tester,
      const Look(),
      Scaffold(
        body: Center(
          child: ValueListenableBuilder(
            valueListenable: outcome,
            builder: (_, o, _) => EnergySpinner(size: 44, outcome: o),
          ),
        ),
      ),
    );
    expect(tester.binding.transientCallbackCount, greaterThan(0), reason: 'spinning');
    outcome.value = EnergyOutcome.success;
    await tester.pump();
    await frames(tester, EnergySpinner.outcomeDuration + const Duration(milliseconds: 600));
    expect(tester.binding.transientCallbackCount, 0, reason: 'nothing left to move');
    outcome.value = null;
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
  });

  testWidgets('with animations removed it stands still, and asks for no frames', (tester) async {
    await pumpLook(
      tester,
      const Look(),
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: const Scaffold(body: Center(child: BusySpinner.page())),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('a hidden route stops its spinner', (tester) async {
    await pumpLook(tester, const Look(), const Scaffold(body: Center(child: BusySpinner.page())));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    Navigator.of(tester.element(find.byType(BusySpinner))).push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('on top'))),
    );
    await frames(tester, const Duration(milliseconds: 600));
    expect(find.text('on top'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 0, reason: 'TickerMode mutes the spinner under the new route');
  });

  group('a wait behind a dialog', () {
    Future<Completer<String>> open(WidgetTester tester, List<Object?> results, {bool confirm = false}) async {
      final work = Completer<String>();
      await pumpLook(
        tester,
        const Look(),
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => results.add(await runWithProgress(context, 'Restoring…', () => work.future, confirm: confirm)),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await frames(tester, const Duration(milliseconds: 300));
      expect(find.text('Restoring…'), findsOneWidget);
      return work;
    }

    EnergyOutcome? shown(WidgetTester tester) => tester.widget<EnergySpinner>(find.byType(EnergySpinner)).outcome;

    testWidgets('confirmed: ends with a check and "Done", then the dialog goes', (tester) async {
      final results = <Object?>[];
      final work = await open(tester, results, confirm: true);
      expect(shown(tester), isNull);
      work.complete('done');
      await tester.pump();
      await tester.pump();
      expect(shown(tester), EnergyOutcome.success);
      expect(find.text('Done'), findsOneWidget, reason: 'held for a moment, and no longer saying "Restoring…"');
      expect(find.text('Restoring…'), findsNothing);
      await frames(tester, EnergySpinner.outcomeDuration + const Duration(milliseconds: 100));
      expect(find.text('Done'), findsNothing);
      expect(results, ['done']);
    });

    testWidgets('not confirmed: success just closes, for work whose next screen says it worked', (tester) async {
      final results = <Object?>[];
      final work = await open(tester, results);
      work.complete('done');
      await tester.pump();
      await tester.pump();
      expect(find.byType(EnergySpinner), findsNothing);
      expect(results, ['done']);
    });

    testWidgets('a failure ends with a cross, then says why', (tester) async {
      final results = <Object?>[];
      final work = await open(tester, results);
      work.completeError(StateError('no space left'));
      await tester.pump();
      await tester.pump();
      expect(shown(tester), EnergyOutcome.failure);
      expect(find.text('Failed'), findsOneWidget);
      expect(find.textContaining('no space left'), findsNothing, reason: 'the cross first');
      await frames(tester, EnergySpinner.outcomeDuration + const Duration(milliseconds: 100));
      expect(find.text('Restoring…'), findsNothing);
      expect(find.textContaining('no space left'), findsOneWidget);
      expect(results, [null]);
    });
  });

  group('screen readers', () {
    testWidgets('hear "Loading…", in the app\'s language, then "Done" or "Failed"', (tester) async {
      final semantics = tester.ensureSemantics();
      final outcome = ValueNotifier<EnergyOutcome?>(null);
      await pumpLook(
        tester,
        const Look(language: 'id'),
        Scaffold(
          body: Center(
            child: ValueListenableBuilder(
              valueListenable: outcome,
              builder: (_, o, _) => EnergySpinner(size: 44, outcome: o),
            ),
          ),
        ),
      );
      expect(find.bySemanticsLabel('Memuat…'), findsOneWidget);
      outcome.value = EnergyOutcome.failure;
      await tester.pump();
      expect(find.bySemanticsLabel('Gagal'), findsOneWidget);
      expect(tester.getSemantics(find.bySemanticsLabel('Gagal')).flagsCollection.isLiveRegion, isTrue, reason: 'announced when it comes');
      outcome.value = EnergyOutcome.success;
      await tester.pump();
      expect(find.bySemanticsLabel('Selesai'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a spinner in place of a button\'s text gives the button a label', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpLook(tester, const Look(), Scaffold(body: Center(child: FilledButton(onPressed: () {}, child: const BusySpinner()))));
      expect(find.bySemanticsLabel('Loading…'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('the dialog\'s spinner is not read on top of its own label', (tester) async {
      final semantics = tester.ensureSemantics();
      final work = Completer<void>();
      await pumpLook(
        tester,
        const Look(),
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => runWithProgress(context, 'Restoring…', () => work.future),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await frames(tester, const Duration(milliseconds: 300));
      expect(find.bySemanticsLabel('Restoring…'), findsOneWidget);
      expect(find.bySemanticsLabel('Loading…'), findsNothing);
      work.complete();
      await frames(tester, const Duration(milliseconds: 300));
      semantics.dispose();
    });
  });
}
