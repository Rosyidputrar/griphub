// Three additions: an edit's approval card shows the change as a diff; typing @ in the composer offers the project's
// files; and the open chat can be shared, copied or saved as Markdown.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/chat_export.dart';
import 'package:griphub_agent/ui/chat_extras.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/ui/diff_view.dart';

import 'harness.dart';

const _looks = [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)];

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _patch = '''--- lib/login.dart
+++ lib/login.dart
@@ -10,7 +10,8 @@
 Future<void> signIn(String email, String password) async {
-  final user = await api.login(email, password);
+  final user = await api.login(email.trim(), password);
+  if (user == null) throw const LoginFailed();
   session.user = user;
   await prefs.save(user.token);
   notifyListeners();
 }
''';

Map<String, dynamic> _approval({String? patch, String id = 'a1'}) => {
  'type': 'approval',
  'approvalId': id,
  'toolName': 'edit',
  'summary': 'lib/login.dart',
  'reason': 'Approval required for every change',
  'key': 'edit:lib/login.dart',
  'patch': ?patch,
};

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  group('an edit\'s approval shows the change', () {
    for (final look in _looks) {
      testWidgets('golden: the diff on the card ${look.name}', (tester) async {
        final host = FakeHost();
        final agent = newAgent();
        await pumpLook(tester, look, Scaffold(body: ListView(children: [ApprovalCards(features: agent.features)])), height: 560);
        host.emit(_approval(patch: _patch));
        await frames(tester);
        expect(find.byType(DiffView), findsOneWidget);
        expect(find.text('lib/login.dart'), findsOneWidget, reason: 'the diff names the file');
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('approval_diff_${look.name}')));
      });
    }

    testWidgets('without a patch (a command, or a change the host could not work out) the card shows what it runs', (tester) async {
      final host = FakeHost();
      final agent = newAgent();
      await pumpLook(tester, const Look(), Scaffold(body: ListView(children: [ApprovalCards(features: agent.features)])));
      host.emit(_approval());
      await frames(tester);
      expect(find.byType(DiffView), findsNothing);
      expect(find.text('lib/login.dart'), findsOneWidget);
    });

    testWidgets('a change longer than the card opens whole on its own page', (tester) async {
      final host = FakeHost();
      final agent = newAgent();
      final long = StringBuffer('--- big.txt\n+++ big.txt\n@@ -1,0 +1,40 @@\n');
      for (var i = 0; i < 40; i++) {
        long.write('+line $i\n');
      }
      await pumpLook(tester, const Look(), Scaffold(body: ListView(children: [ApprovalCards(features: agent.features)])));
      host.emit(_approval(patch: long.toString()));
      await frames(tester);
      await tester.tap(find.text('See the whole change'));
      await frames(tester);
      expect(find.text('The whole change'), findsOneWidget);
      expect(find.textContaining('line 39', findRichText: true, skipOffstage: false), findsWidgets, reason: 'all of it, to the last line');
    });
  });

  group('@ offers the project\'s files', () {
    test('an @ at the start or after a space starts a mention; an email address does not', () {
      expect(mentionAt('look at @chs', 12), (start: 8, query: 'chs'));
      expect(mentionAt('@', 1), (start: 0, query: ''));
      expect(mentionAt('mail me@home.com', 16), isNull);
      expect(mentionAt('@lib/ui done', 12), isNull, reason: 'the cursor is past the mention');
      final r = insertMention('fix @chs please', 4, 8, 'lib/ui/chat_screen.dart');
      expect(r.text, 'fix @lib/ui/chat_screen.dart please', reason: 'the space already there is not doubled');
      expect(insertMention('@ch', 0, 3, 'a.dart'), (text: '@a.dart ', cursor: 8));
    });

    for (final look in _looks) {
      testWidgets('golden: typing @ lists matching files, and picking one puts its path in ${look.name}', (tester) async {
        final host = FakeHost();
        final queries = <String>[];
        host.answers['files_find'] = (cmd) {
          queries.add(cmd['query'] as String);
          return {
            'files': ['lib/ui/chat_screen.dart', 'lib/ui/chat_extras.dart', 'lib/agent/chat.dart'],
            'truncated': false,
          };
        };
        final agent = newAgent();
        await pumpLook(tester, look, ChatScreen(agent: agent));
        await frames(tester, 2);
        await tester.enterText(find.byType(TextField).last, 'fix the layout in @chat');
        await frames(tester);
        expect(queries.last, 'chat');
        expect(find.byType(MentionMenu), findsOneWidget);
        expect(find.text('chat_screen.dart'), findsOneWidget);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold).first, matchesGoldenFile(golden('mention_menu_${look.name}')));
        await tester.tap(find.text('chat_screen.dart'));
        await frames(tester);
        expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, 'fix the layout in @lib/ui/chat_screen.dart ');
        expect(find.byType(MentionMenu), findsNothing, reason: 'the cursor left the mention');
      });
    }

    testWidgets('a host that can\'t list files (no project yet) shows no list, and no error', (tester) async {
      final host = FakeHost();
      host.answers['files_find'] = (_) => const HostError('No chat is open');
      final agent = newAgent();
      await pumpLook(tester, const Look(), ChatScreen(agent: agent));
      await tester.enterText(find.byType(TextField).last, '@x');
      await frames(tester);
      expect(find.byType(MentionMenu), findsNothing);
      expect(find.textContaining('No chat is open'), findsNothing);
    });
  });

  group('sharing a chat', () {
    List<ChatEntry> transcript() {
      final reply = AssistantEntry()..streaming = false;
      reply.block(0, BlockKind.thinking).text = 'Let me look at the login first.';
      reply.block(1, BlockKind.text).text = 'The email had a trailing space. I trimmed it.';
      reply.block(2, BlockKind.toolCall)
        ..toolCallId = 't1'
        ..toolName = 'edit'
        ..args = {'path': 'lib/login.dart'};
      reply.block(3, BlockKind.toolCall)
        ..toolCallId = 't2'
        ..toolName = 'bash'
        ..args = {'command': 'flutter test'};
      reply.block(4, BlockKind.text).text = 'Tests pass.';
      return [
        UserEntry('Fix the login\nIt fails with spaces'),
        reply,
        NoticeEntry('Daily budget almost used', error: true),
        CompactionEntry(running: false, tokensBefore: 320000)..tokensAfter = 24000,
      ];
    }

    test('Markdown: messages and answers, a line per tool with how it went, no thinking, notes as quotes', () {
      final md = chatMarkdown(
        title: 'Fix the login',
        entries: transcript(),
        tools: {'t1': ToolRun('t1')..status = ToolStatus.done, 't2': ToolRun('t2')..status = ToolStatus.failed},
        project: 'shop-app',
        model: 'Claude',
        at: DateTime(2026, 10, 30, 9, 5),
      );
      expect(md, startsWith('# Fix the login\n\n_2026-10-30 09:05 · Project: `shop-app` · Model: Claude_\n'));
      expect(md, contains('## You\n\nFix the login\nIt fails with spaces\n'));
      expect(md, contains('## Agent\n\nThe email had a trailing space. I trimmed it.\n\n- ✓ `edit` `login.dart`\n- ✗ `bash` `flutter test`\n\nTests pass.'));
      expect(md, isNot(contains('Let me look')), reason: 'thinking stays out');
      expect(md, contains('> ⚠️ Daily budget almost used'));
      expect(md, contains('(320k → 24k tokens)'));
    });

    test('the file name says which chat and when', () {
      expect(chatExportName('Fix the login!', DateTime(2026, 10, 30, 9, 5)), 'griphub-fix-the-login-20261030-0905.md');
      expect(chatExportName('Перевод', DateTime(2026, 1, 2, 3, 4)), 'griphub-chat-20260102-0304.md');
    });

    testWidgets('from Project tools: share as text, as a file, copy or save; copy puts the Markdown on the clipboard', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      FakeHost();
      final agent = newAgent();
      agent.entries.addAll(transcript());
      await pumpLook(tester, const Look(), ChatScreen(agent: agent));
      await frames(tester, 2);
      await tester.tap(find.byTooltip('Project tools'));
      await frames(tester);
      await tester.tap(find.text('Share this chat'));
      await frames(tester);
      for (final option in ['Share as text', 'Share as a Markdown file', 'Copy as Markdown', 'Save to Downloads']) {
        expect(find.text(option), findsOneWidget, reason: option);
      }
      await expectLater(find.byType(BottomSheet), matchesGoldenFile(golden('chat_export_sheet')));
      await tester.tap(find.text('Copy as Markdown'));
      await frames(tester);
      expect(copied, startsWith('# Fix the login'));
      expect(find.text('Chat copied'), findsOneWidget);
    });
  });
}
