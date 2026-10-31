// Second half of the UI audit (UI-10 to UI-24): states, motion, semantics and touch targets.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/ui/home_shell.dart';

import 'harness.dart';

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  group('UI-10: a list that cannot be read says so', () {
    testWidgets('Home\'s Recent and the Chats tab show the error with a retry, and the retry works', (tester) async {
      final host = FakeHost();
      var fail = true;
      host.answers['sessions'] = (_) => fail ? const HostError('The server did not answer.') : <Object>[];
      await pumpLook(tester, const Look(), HomeShell(agent: newAgent()), height: 1600);
      await frames(tester);
      expect(find.text('The server did not answer.'), findsOneWidget, reason: 'Recent');
      await tester.tap(find.bySemanticsLabel(RegExp('^Chats')).first);
      await frames(tester, 12);
      expect(find.text('The server did not answer.'), findsOneWidget, reason: 'the Chats tab, not a spinner forever');
      fail = false;
      await tester.tap(find.text('Try again').last);
      await frames(tester, 12);
      expect(find.text('The server did not answer.'), findsNothing, reason: 'the Chats tab read the list again');
      expect(find.text('No chats yet. Tap + to start one.'), findsOneWidget);
    });
  });
}
