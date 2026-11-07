// Regression tests for the second audit's fixes on the app side: switching
// chats while the agent works (#3), the editor's on-disk check (#5), the
// undo dialog (#6) and the SSH deploy confirm (#1), with goldens of the new
// dialogs. Host-side halves are in agent/test/fixes.test.mjs.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/changes_screen.dart';
import 'package:griphub_agent/ui/chat_extras.dart';
import 'package:griphub_agent/ui/editor_screen.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:re_editor/re_editor.dart';

import 'harness.dart';

Future<void> frames(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(loadAppFonts);
  late FakeHost host;
  setUp(() {
    host = FakeHost();
    applyLook(const Look());
    layoutErrors.clear();
  });

  group('#3 switching chats while the agent works', () {
    // Everything here runs on the fake clock (FakeHost replies are microtasks
    // there); never tester.runAsync, which would wait on replies forever.
    testWidgets('while the agent works, another chat opens read-only: no question, no stop, nothing sent', (tester) async {
      // Fitur 8 replaced the stop-and-switch question for opening chats: looking is never locked, only sending is.
      host = FakeHost();
      host.answers['session_read'] = (cmd) => {
        'path': cmd['path'],
        'sessionId': 'b',
        'sessionName': 'Chat B',
        'cwd': '/w',
        'chatMode': 'chat',
        'messages': [
          {'role': 'user', 'content': 'pesan di B'},
        ],
      };
      final agent = newAgent();
      await pumpLook(tester, const Look(), const Scaffold(body: SizedBox()));
      agent.sessionFile = 'a.jsonl';
      agent.busy = true;
      var asked = 0;
      agent.confirmStopToSwitch = () async {
        asked++;
        return true;
      };
      bool? opened;
      agent.openSession('b.jsonl').then((v) => opened = v);
      await frames(tester, 3);
      expect(opened, isTrue);
      expect(asked, 0, reason: 'no question');
      expect(host.sent('abort'), isEmpty, reason: 'the turn goes on');
      expect(host.sent('open_session'), isEmpty, reason: 'the chat at work stays the open one');
      expect(host.sent('session_read').single['path'], 'b.jsonl');
      expect(agent.viewing?.title, 'Chat B');
      expect(agent.viewing?.entries.whereType<UserEntry>().single.text, 'pesan di B');
      expect(agent.sendLocked, isTrue);
      // Nothing goes out while locked, whatever asks.
      expect(await agent.send('kirim'), isFalse);
      expect(await agent.sendWith('kirim juga'), isFalse);
      await agent.retry();
      expect(host.sent('prompt'), isEmpty);
      expect(host.sent('retry'), isEmpty);

      // The turn ends: chat B opens for real, and can be written in.
      final finished = <String>[];
      agent.viewFinished.stream.listen(finished.add);
      host.emit({'type': 'state', 'state': {'isStreaming': false, 'sessionFile': 'a.jsonl', 'sessionId': 'a'}});
      await frames(tester, 12);
      expect(host.sent('open_session').single['path'], 'b.jsonl');
      expect(agent.viewing, isNull);
      expect(agent.sendLocked, isFalse);
      expect(agent.finishedUnseen, contains('a.jsonl'));
      expect(finished, hasLength(1));
    });

    testWidgets('the chat at work again, from the list or the pill: shown live, nothing reopened', (tester) async {
      host = FakeHost();
      host.answers['session_read'] = (cmd) => {'path': cmd['path'], 'sessionId': 'b', 'messages': const []};
      final agent = newAgent();
      await pumpLook(tester, const Look(), const Scaffold(body: SizedBox()));
      agent.sessionFile = 'a.jsonl';
      agent.busy = true;
      await agent.openSession('b.jsonl');
      expect(agent.viewing, isNotNull);
      expect(await agent.openSession('a.jsonl'), isTrue);
      expect(agent.viewing, isNull);
      expect(host.sent('open_session'), isEmpty);
      await agent.newSession();
      expect(agent.viewing?.isNew, isTrue, reason: 'a new chat waits read-only too');
      expect(host.sent('new_session'), isEmpty);
      agent.leaveView();
      expect(agent.viewing, isNull);
    });

    testWidgets('idle: no question, switches straight away; same chat: nothing to do', (tester) async {
      host = FakeHost();
      final agent = newAgent();
      await pumpLook(tester, const Look(), const Scaffold(body: SizedBox()));
      agent.sessionFile = 'a.jsonl';
      agent.confirmStopToSwitch = () async => fail('must not ask when idle');
      bool? same;
      agent.openSession('a.jsonl').then((v) => same = v);
      bool? fresh;
      agent.newSession().then((v) => fresh = v);
      await frames(tester, 6);
      expect(same, isTrue);
      expect(host.sent('open_session'), isEmpty);
      expect(fresh, isTrue);
      expect(host.sent('new_session'), hasLength(1));
    });

    testWidgets('golden: stop-and-switch dialog', (tester) async {
      await pumpLook(
        tester,
        const Look(language: 'id'),
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(onPressed: () => confirmStopToSwitch(context), child: const Text('open')),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await frames(tester);
      expect(layoutErrors, isEmpty);
      expect(find.text('Hentikan & pindah'), findsOneWidget);
      await expectLater(find.byType(AlertDialog), matchesGoldenFile(golden('dialog_stop_to_switch')));
    });
  });

  group('#5 editor and changes on disk', () {
    testWidgets('saving after the agent changed the file asks first; Reload keeps the agent\'s version', (tester) async {
      final dir = Directory.systemTemp.createTempSync('editor-test-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/app.js')..writeAsStringSync('console.log("v1");\n');
      final agent = newAgent();
      await tester.runAsync(() async {
        await pumpLook(tester, const Look(), EditorScreen(agent: agent, path: file.path));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await frames(tester);
      // The user types into the real editor; meanwhile the agent writes the same file.
      final controller = tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
      controller.text = '// mine\nconsole.log("v1");\n';
      await frames(tester, 3);
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, LucideIcons.save)).onPressed, isNotNull,
          reason: 'the edit made the buffer dirty');
      file.writeAsStringSync('console.log("agent");\n');
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Save').first);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await frames(tester);
      expect(find.text('File changed on disk'), findsOneWidget);
      await expectLater(find.byType(AlertDialog), matchesGoldenFile(golden('dialog_editor_changed_on_disk')));
      await tester.runAsync(() async {
        await tester.tap(find.text('Reload'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await frames(tester);
      expect(file.readAsStringSync(), 'console.log("agent");\n');
    });
  });

  group('#6 undo dialog', () {
    Future<List<String>?> show(WidgetTester tester, Look look, List<String> removes, {void Function()? before}) async {
      List<String>? result = const ['unset'];
      await pumpLook(
        tester,
        look,
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await showDialog<List<String>>(
                    context: context,
                    builder: (_) => UndoCheckpointDialog(label: "Before the agent's changes", removes: removes),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await frames(tester);
      before?.call();
      return result;
    }

    testWidgets('lists the files, ticking one keeps it', (tester) async {
      await show(tester, const Look(), ['src/agent-new.ts', 'notes/mine.md', 'assets/logo.svg']);
      expect(find.text('3 files will be deleted.'), findsOneWidget);
      await tester.tap(find.text('mine.md'));
      await frames(tester, 4);
      expect(find.text('2 files will be deleted.'), findsOneWidget);
      expect(layoutErrors, isEmpty);
      await expectLater(find.byType(AlertDialog), matchesGoldenFile(golden('dialog_undo_keep')));
      await tester.tap(find.text('Undo changes'));
      await frames(tester, 12);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('narrow, large text, Indonesian, many files', (tester) async {
      await show(
        tester,
        const Look(language: 'id', textScale: 1.3, width: 320),
        [for (var i = 0; i < 12; i++) 'lib/features/very/long/path/file_$i.dart'],
      );
      expect(layoutErrors, isEmpty);
      await expectLater(find.byType(AlertDialog), matchesGoldenFile(golden('dialog_undo_narrow')));
    });

    testWidgets('nothing to delete: plain confirm', (tester) async {
      await show(tester, const Look(dark: true), const []);
      expect(find.byType(CheckboxListTile), findsNothing);
      await expectLater(find.byType(AlertDialog), matchesGoldenFile(golden('dialog_undo_none')));
    });
  });
}
