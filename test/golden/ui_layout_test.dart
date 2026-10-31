// Layouts that broke on ordinary phones (UI audit): each case is pumped at the sizes that broke it, and fails on any
// overflow instead of only recording it. Goldens show the fixed layout.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/chat_screen.dart';

import 'harness.dart';

/// Fails the test when the layout overflowed while it was pumped.
void expectNoOverflow(String where) {
  expect(layoutErrors, isEmpty, reason: '$where overflowed: ${layoutErrors.join('\n')}');
}

AgentController agentWithModel() => newAgent()
  ..model = ModelInfo({'provider': 'griphub', 'id': 'mock', 'name': 'Mock'});

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  group('UI-01: the suggestions on an empty chat', () {
    const looks = [
      Look(width: 360),
      Look(width: 320),
      Look(width: 360, textScale: 1.3),
      Look(width: 411, textScale: 1.3),
      Look(width: 320, textScale: 2.0),
      Look(language: 'id', width: 320, textScale: 1.3),
      Look(dark: true, language: 'id', width: 360),
    ];
    for (final look in looks) {
      testWidgets('no overflow ${look.name}', (tester) async {
        FakeHost();
        await pumpLook(tester, look, ChatScreen(agent: agentWithModel()), height: 1400);
        await tester.pump(const Duration(milliseconds: 100));
        collectLayoutErrors(tester, look.name);
        expect(find.text('A site or app, ready to deploy'), look.language == 'en' ? findsOneWidget : findsNothing);
        expectNoOverflow('the suggestion grid');
      });
    }
    for (final look in const [Look(width: 360), Look(language: 'id', width: 320, textScale: 1.3)]) {
      testWidgets('golden ${look.name}', (tester) async {
        FakeHost();
        await pumpLook(tester, look, ChatScreen(agent: agentWithModel()));
        await tester.pump(const Duration(milliseconds: 100));
        await expectLater(find.byType(ChatScreen), matchesGoldenFile(golden('empty_chat_suggestions_${look.name}')));
      });
    }
  });
}
