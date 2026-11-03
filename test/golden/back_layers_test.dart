// Back closes the top layer first, everywhere: a layer drawn inside a page (the "/" and "@" suggestions over the chat's
// input, the editor's find bar, a selection) goes before the page does; a sheet, menu or dialog on top goes before the
// page under it; an expanded sheet goes back to its first height before it closes.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/ui/chat_extras.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/ui/editor_screen.dart';
import 'package:griphub_agent/ui/kit.dart';
import 'package:re_editor/re_editor.dart';

import 'harness.dart';

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// [page] pushed over a first page, as screens are opened in the app.
Future<void> _over(WidgetTester tester, Widget page) async {
  await pumpLook(
    tester,
    const Look(),
    Builder(
      builder: (c) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => page)),
          child: const Text('home'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('home'));
  await frames(tester);
}

/// The system Back (the button, or a back gesture the app does not animate).
Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await frames(tester);
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  group('the chat', () {
    late FakeHost host;
    late AgentController agent;
    // Made inside each test: the binding's channels are set up for it there.
    void fake() {
      host = FakeHost();
      host.answers['slash_commands'] = (_) => {
        'templates': [
          {'name': 'review', 'description': 'Review the changes'},
          {'name': 'refactor', 'description': 'Tidy the code'},
        ],
        'skills': <Object>[],
      };
      host.answers['files_find'] = (_) => {
        'files': ['lib/main.dart', 'lib/ui/kit.dart'],
      };
      agent = newAgent();
    }

    testWidgets('Back closes the "/" suggestions first and keeps the text, then leaves', (tester) async {
      fake();
      await _over(tester, ChatScreen(agent: agent));
      await tester.enterText(find.byType(TextField).last, '/re');
      await frames(tester);
      expect(find.byType(SlashMenu), findsOneWidget);
      expect(find.text('/review'), findsOneWidget);

      await _back(tester);
      expect(find.text('/review'), findsNothing, reason: 'the suggestions closed');
      expect(find.byType(ChatScreen), findsOneWidget, reason: 'the chat stayed');
      expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, '/re', reason: 'the text stayed');

      // Typing on brings them back.
      await tester.enterText(find.byType(TextField).last, '/rev');
      await frames(tester);
      expect(find.text('/review'), findsOneWidget);
      await _back(tester);
      await _back(tester);
      expect(find.byType(ChatScreen), findsNothing, reason: 'the second Back leaves');
    });

    testWidgets('Back closes the "@" file suggestions first', (tester) async {
      fake();
      await _over(tester, ChatScreen(agent: agent));
      await tester.enterText(find.byType(TextField).last, 'look at @ki');
      await frames(tester, 12);
      expect(find.byType(MentionMenu), findsOneWidget);
      expect(find.text('kit.dart'), findsOneWidget);
      await _back(tester);
      expect(find.text('kit.dart'), findsNothing);
      expect(find.byType(ChatScreen), findsOneWidget);
      await _back(tester);
      expect(find.byType(ChatScreen), findsNothing);
    });

    testWidgets('with nothing over the input, Back leaves at once', (tester) async {
      fake();
      await _over(tester, ChatScreen(agent: agent));
      await tester.enterText(find.byType(TextField).last, 'hello');
      await frames(tester);
      await _back(tester);
      expect(find.byType(ChatScreen), findsNothing);
      expect(host.sent('slash_commands'), isEmpty);
    });
  });

  testWidgets('the editor: Back closes find first, then asks about unsaved changes', (tester) async {
    final dir = Directory.systemTemp.createTempSync('gh-back-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/app.js')..writeAsStringSync('console.log(1);\n');
    final agent = newAgent();
    await tester.runAsync(() async {
      await _over(tester, EditorScreen(agent: agent, path: file.path));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await frames(tester);
    await tester.tap(find.byTooltip('Find'));
    await frames(tester);
    final find0 = tester.widget<CodeEditor>(find.byType(CodeEditor)).findController!;
    expect(find0.value, isNotNull, reason: 'find is open');
    await _back(tester);
    expect(find0.value, isNull, reason: 'Back closed find');
    expect(find.byType(EditorScreen), findsOneWidget);
    // Edited: Back asks.
    tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!.text = 'x';
    await frames(tester, 3);
    await _back(tester);
    expect(find.text('Unsaved changes'), findsOneWidget);
    // Back on the question closes the question, nothing else.
    await _back(tester);
    expect(find.text('Unsaved changes'), findsNothing);
    expect(find.byType(EditorScreen), findsOneWidget);
  });

  testWidgets('BackLayer: open, Back runs onClose and the page stays; closed, Back pops', (tester) async {
    var open = true;
    var closed = 0;
    await _over(
      tester,
      StatefulBuilder(
        builder: (context, setState) => BackLayer(
          open: open,
          onClose: () => setState(() {
            open = false;
            closed++;
          }),
          child: const Scaffold(body: Text('page')),
        ),
      ),
    );
    await _back(tester);
    expect(closed, 1);
    expect(find.text('page'), findsOneWidget);
    await _back(tester);
    expect(closed, 1);
    expect(find.text('page'), findsNothing);
  });
}
