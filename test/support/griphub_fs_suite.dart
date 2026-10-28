import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/sent_attachments.dart';
import 'package:griphub_agent/ui/attachment_viewer.dart';
import 'package:griphub_agent/ui/chat_extras.dart';
import 'package:griphub_agent/ui/editor_screen.dart';
import 'package:griphub_agent/ui/message_views.dart';
import 'package:griphub_agent/ui/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'files_ui_suite.dart';

/// A 1×1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// The screens GripHub has on top of CoderRa's that read project files, per [FsVariant]: the sent-attachment viewer and
/// thumbnails (the copies live in the project's `.attachments`, on the agent's machine) and the project memory file.
void griphubFsSuite(FsVariant variant) {
  late Directory dir;
  late AgentController agent;

  setUp(() => dir = variant.makeDir());
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String p(String rel) => '${dir.path}/$rel';

  /// Lets real file I/O finish, then rebuilds. A picture fetched from a server takes a dozen steps or more (stat, the
  /// cache folder, each chunk, the rename), each of which continues only when the test pumps.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pump(const Duration(milliseconds: 500));
  }

  Widget app(Widget home) => MaterialApp(theme: buildTheme(Brightness.light), home: home);

  SentAttachment sent(String rel, {String? mime}) {
    final f = File(p(rel));
    return (path: f.path, name: rel.split('/').last, mime: mime, size: f.existsSync() ? f.lengthSync() : -1);
  }

  group('sent attachments', () {
    Future<void> view(WidgetTester tester, SentAttachment a) async {
      agent = await variant.makeAgent(tester, dir);
      await tester.pumpWidget(app(AttachmentViewerScreen(attachment: a, fs: agent.fs)));
      await settle(tester);
    }

    testWidgets('a text attachment opens with its contents', (tester) async {
      File(p('.attachments/1_0_notes.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# Plan\n\nShip the **server** mode.');
      await view(tester, sent('.attachments/1_0_notes.md'));
      expect(find.text('Plan'), findsOneWidget);
      expect(find.textContaining('Ship the'), findsOneWidget);
    });

    testWidgets('a picture opens from the agent\'s machine', (tester) async {
      File(p('.attachments/1_0_shot.png'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(_png);
      await view(tester, sent('.attachments/1_0_shot.png', mime: 'image/png'));
      final image = tester.widget<Image>(find.byType(Image)).image as FileImage;
      expect(image.file.readAsBytesSync(), _png);
      if (variant.remote) {
        expect(image.file.path, isNot(p('.attachments/1_0_shot.png')), reason: 'fetched to the phone');
      }
    });

    testWidgets('a copy that is gone says so', (tester) async {
      await view(tester, sent('.attachments/1_0_gone.txt'));
      expect(find.text('File no longer available'), findsOneWidget);
    });

    testWidgets('a text file too large to preview shows its facts instead', (tester) async {
      File(p('.attachments/1_0_big.log'))
        ..createSync(recursive: true)
        ..writeAsStringSync('x' * (AttachmentViewerScreen.maxTextBytes + 1));
      await view(tester, sent('.attachments/1_0_big.log'));
      expect(find.text('File is too large to preview'), findsOneWidget);
    });

    testWidgets('the message shows a thumbnail of a sent picture, and a placeholder for one that is gone', (
      tester,
    ) async {
      File(p('.attachments/1_0_shot.png'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(_png);
      agent = await variant.makeAgent(tester, dir);
      await tester.pumpWidget(
        app(
          Scaffold(
            body: MessageAttachments(
              attachments: [
                sent('.attachments/1_0_shot.png', mime: 'image/png'),
                sent('.attachments/2_0_gone.png'),
              ],
              fs: agent.fs,
            ),
          ),
        ),
      );
      await settle(tester);
      final images = tester.widgetList<Image>(find.byType(Image)).toList();
      expect(images, isNotEmpty);
      final shown = (images.first.image as FileImage).file;
      expect(shown.readAsBytesSync(), _png);
      if (variant.remote) {
        expect(shown.path, isNot(p('.attachments/1_0_shot.png')), reason: 'fetched to the phone');
        // The phone has no file at the server's path; the one that is gone gets the placeholder at once.
        expect(find.byIcon(LucideIcons.imageOff), findsOneWidget);
      }
    });
  });

  group('project memory', () {
    testWidgets('opening it makes AGENTS.md in the project when there is none, and edits it', (tester) async {
      Directory(p('proj')).createSync();
      agent = await variant.makeAgent(tester, dir);
      agent.cwd = p('proj');
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showProjectTools(context, agent, onPrompt: (_) {}),
                child: const Text('tools'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('tools'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.ensureVisible(find.text('Project memory'));
      await tester.tap(find.text('Project memory'));
      await settle(tester);

      expect(File(p('proj/AGENTS.md')).readAsStringSync(), startsWith('# Project notes for the agent'));
      expect(find.byType(EditorScreen), findsOneWidget);
    });

    testWidgets('an existing AGENTS.md is left as it is', (tester) async {
      File(p('proj/AGENTS.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('mine');
      agent = await variant.makeAgent(tester, dir);
      agent.cwd = p('proj');
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showProjectTools(context, agent, onPrompt: (_) {}),
                child: const Text('tools'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('tools'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.ensureVisible(find.text('Project memory'));
      await tester.tap(find.text('Project memory'));
      await settle(tester);

      expect(File(p('proj/AGENTS.md')).readAsStringSync(), 'mine');
      expect(find.byType(EditorScreen), findsOneWidget);
    });
  });
}
