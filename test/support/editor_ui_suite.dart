import 'dart:io';

import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/ui/editor_screen.dart';
import 'package:griphub_agent/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

import 'files_ui_suite.dart';

/// The code editor, per [FsVariant]: saving, and above all not overwriting a file that changed underneath it.
void editorUiSuite(FsVariant variant) {
  late Directory dir;
  late AgentController agent;

  setUp(() => dir = variant.makeDir());
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String p(String rel) => '${dir.path}/$rel';

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<CodeLineEditingController> open(WidgetTester tester, String name) async {
    agent = await variant.makeAgent(tester, dir);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: EditorScreen(agent: agent, path: p(name)),
      ),
    );
    await settle(tester);
    return tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
  }

  /// Something else (the agent, say) changes the file underneath the editor.
  void changeBehindTheEditor(String name, String text) => File(p(name)).writeAsStringSync(text);

  Future<void> tapSave(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Save'));
    await settle(tester);
  }

  // GripHub's editor keeps the bytes it read or wrote last and compares the file with them before saving (its own
  // design, kept over CoderRa's modification-time check): a file changed underneath is never overwritten silently.
  group('EditorScreen', () {
    testWidgets('opens a file, saves an edit, and saves again without quarrelling with its own earlier save', (
      tester,
    ) async {
      File(p('a.txt')).writeAsStringSync('one');
      final c = await open(tester, 'a.txt');
      expect(c.text, 'one');

      c.text = 'two';
      await settle(tester);
      await tapSave(tester);
      expect(File(p('a.txt')).readAsStringSync(), 'two');
      expect(find.text('File changed on disk'), findsNothing);

      c.text = 'three';
      await settle(tester);
      await tapSave(tester);
      expect(File(p('a.txt')).readAsStringSync(), 'three', reason: 'the second save follows the first');
      expect(find.text('File changed on disk'), findsNothing);
    });

    testWidgets('a file changed underneath is not overwritten: it asks, and "Cancel" writes nothing', (tester) async {
      File(p('a.txt')).writeAsStringSync('original');
      final c = await open(tester, 'a.txt');
      c.text = 'my edit';
      await settle(tester);
      changeBehindTheEditor('a.txt', 'the agent was here');

      await tapSave(tester);
      expect(find.text('File changed on disk'), findsOneWidget);
      expect(
        File(p('a.txt')).readAsStringSync(),
        'the agent was here',
        reason: 'nothing written while the dialog is up',
      );

      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(File(p('a.txt')).readAsStringSync(), 'the agent was here');
      expect(c.text, 'my edit', reason: 'the edits are still on screen');
    });

    testWidgets('"Overwrite" writes my version', (tester) async {
      File(p('a.txt')).writeAsStringSync('original');
      final c = await open(tester, 'a.txt');
      c.text = 'my edit';
      await settle(tester);
      changeBehindTheEditor('a.txt', 'the agent was here');
      await tapSave(tester);
      await tester.tap(find.text('Overwrite'));
      await settle(tester);
      expect(File(p('a.txt')).readAsStringSync(), 'my edit');
      expect(find.text('File changed on disk'), findsNothing);

      // Saving again follows my own write, without asking.
      c.text = 'my second edit';
      await settle(tester);
      await tapSave(tester);
      expect(find.text('File changed on disk'), findsNothing);
      expect(File(p('a.txt')).readAsStringSync(), 'my second edit');
    });

    testWidgets('"Reload" drops my edits and shows the new content; saving then works from it', (tester) async {
      File(p('a.txt')).writeAsStringSync('original');
      final c = await open(tester, 'a.txt');
      c.text = 'my edit';
      await settle(tester);
      changeBehindTheEditor('a.txt', 'the agent was here');
      await tapSave(tester);
      await tester.tap(find.text('Reload'));
      await settle(tester);
      expect(c.text, 'the agent was here');
      expect(File(p('a.txt')).readAsStringSync(), 'the agent was here');
      expect(find.byType(CodeEditor), findsOneWidget, reason: 'the editor is back');

      c.text = 'after reload';
      await settle(tester);
      await tapSave(tester);
      expect(find.text('File changed on disk'), findsNothing);
      expect(File(p('a.txt')).readAsStringSync(), 'after reload');
    });

    testWidgets('a file deleted underneath is written again from the edits', (tester) async {
      File(p('a.txt')).writeAsStringSync('original');
      final c = await open(tester, 'a.txt');
      c.text = 'my edit';
      await settle(tester);
      File(p('a.txt')).deleteSync();

      await tapSave(tester);
      expect(find.text('File changed on disk'), findsNothing);
      expect(File(p('a.txt')).readAsStringSync(), 'my edit');
    });

    testWidgets('a file with Windows line endings keeps them through an edit', (tester) async {
      File(p('w.txt')).writeAsStringSync('one\r\ntwo\r\n');
      final c = await open(tester, 'w.txt');
      expect(find.byTooltip('Save'), findsOneWidget);
      c.text = 'one\ntwo\nthree\n';
      await settle(tester);
      await tapSave(tester);
      expect(File(p('w.txt')).readAsStringSync(), 'one\r\ntwo\r\nthree\r\n');
    });
  });
}
