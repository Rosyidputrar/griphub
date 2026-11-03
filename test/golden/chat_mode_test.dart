// Chat mode: a plain conversation beside the coding chat (agent/src/chatmode.ts). The new-chat sheet offers it first
// and starts it with one tap, the chat list tells the two apart and filters them, and the chat screen leaves out
// everything that is about a project (terminal, deploy, plan mode, review) and shows a web search as one sentence.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/drafts.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/ui/folder_picker.dart';
import 'package:griphub_agent/ui/home_shell.dart';
import 'package:griphub_agent/ui/i18n.dart';
import 'package:griphub_agent/ui/kit.dart';
import 'package:griphub_agent/ui/message_views.dart';
import 'package:griphub_agent/ui/new_chat_sheet.dart';
import 'package:griphub_agent/ui/theme.dart';

import 'harness.dart';

const _looks = [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)];

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

AgentController agentWith({bool chat = false}) => newAgent()
  ..model = ModelInfo({'provider': 'griphub', 'id': 'mock', 'name': 'Mock'})
  ..isChat = chat
  ..info = {'workspace': '/ws'}
  ..cwd = chat ? '/ws/.chats' : '/ws/shop';

/// A reply that searched the web once, then answered.
AssistantEntry searched(String query, {bool done = true}) {
  final entry = AssistantEntry()..streaming = false;
  entry.block(0, BlockKind.toolCall)
    ..toolCallId = 't1'
    ..toolName = 'web_search'
    ..args = {'query': query};
  entry.block(1, BlockKind.text).text = 'Harga emas hari ini sekitar Rp 1,4 juta per gram. Sumber: https://example.com/emas';
  return entry;
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
    Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
  });

  group('what makes a chat', () {
    test('a session from the host is a chat only when it says so; an older host means coding', () {
      expect(SessionSummary({'path': 'a', 'id': 'a', 'modified': 0, 'chatMode': 'chat'}).isChat, isTrue);
      expect(SessionSummary({'path': 'a', 'id': 'a', 'modified': 0, 'chatMode': 'coding'}).isChat, isFalse);
      expect(SessionSummary({'path': 'a', 'id': 'a', 'modified': 0}).isChat, isFalse);
    });

    test('the chat folder is not a project to name', () {
      expect(sessionFolder('/ws/.chats', '/ws'), isNull);
      expect(sessionFolder('/ws/.chats/', '/ws'), isNull);
      expect(sessionFolder('/ws/shop', '/ws'), 'shop');
      expect(sessionFolder('/ws/.chats-old', '/ws'), '.chats-old', reason: 'only the one folder');
      expect(sessionFolder('/other/.chats', '/ws'), '.chats');
    });

    test('a web search or page read is a sentence; any other tool keeps its card', () {
      expect(plainToolSentence('web_search', {'query': 'harga emas'}, ToolStatus.running), 'Searching the web for "harga emas"');
      expect(plainToolSentence('web_search', {'query': 'harga emas'}, ToolStatus.done), 'Searched the web for "harga emas"');
      expect(plainToolSentence('web_search', null, null), 'Searching the web…');
      expect(plainToolSentence('web_fetch', {'url': 'https://www.kompas.com/a/b'}, ToolStatus.done), 'Opened www.kompas.com');
      expect(plainToolSentence('web_fetch', {'url': 'kompas.com/a'}, ToolStatus.running), 'Opening kompas.com');
      expect(plainToolSentence('read', {'path': 'x'}, ToolStatus.done), isNull);
      expect(plainToolSentence('bash', {'command': 'ls'}, ToolStatus.done), isNull);
      Appearance.instance.language = 'id';
      addTearDown(() => Appearance.instance.language = 'en');
      expect(plainToolSentence('web_search', {'query': 'emas'}, ToolStatus.done), 'Mencari di web "emas"');
    });
  });

  group('the new chat sheet', () {
    Future<FakeHost> open(WidgetTester tester, Look look) async {
      final host = FakeHost();
      host.answers['projects'] = (_) => [
        {'name': 'shop', 'path': '/ws/shop', 'git': true},
      ];
      host.answers['new_session'] = (c) => {
        'sessionFile': 'new.jsonl',
        'sessionId': 'new',
        'chatMode': c['chatMode'] ?? 'coding',
        'cwd': c['chatMode'] == 'chat' ? '/ws/.chats' : (c['cwd'] ?? '/ws'),
      };
      final agent = newAgent()..info = {'workspace': '/ws'};
      await pumpLook(
        tester,
        look,
        Builder(builder: (context) => Scaffold(body: Center(child: TextButton(onPressed: () => showNewChatSheet(context, agent), child: const Text('open'))))),
        height: 1200,
      );
      await tester.tap(find.text('open'));
      // The sheet's spring, and the project list answering behind it.
      await sheetSettles(tester);
      await sheetSettles(tester);
      return host;
    }

    for (final look in _looks) {
      testWidgets('offers Chat first, then Coding (${look.name})', (tester) async {
        await open(tester, look);
        // The suggested name has the time in it; a golden needs the same one every run.
        await tester.enterText(find.byType(TextField), 'my-project');
        await tester.pump();
        expect(layoutErrors, isEmpty);
        expect(find.text(tr('Chat')), findsOneWidget);
        expect(find.text(tr('Ask anything, look up the news, get help writing')), findsOneWidget);
        expect(find.text(tr('Coding').toUpperCase()), findsOneWidget);
        expect(find.text(tr('New project')), findsOneWidget);
        expect(find.text(tr('Open a folder')), findsOneWidget);
        expect(find.text('Quick chat'), findsNothing, reason: 'replaced by Chat');
        // Chat is above the coding choices.
        expect(tester.getTopLeft(find.text(tr('Chat'))).dy, lessThan(tester.getTopLeft(find.text(tr('New project'))).dy));
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('new_chat_sheet_${look.name}')));
      });
    }

    testWidgets('one tap on Chat starts a plain conversation: no folder is sent', (tester) async {
      final host = await open(tester, const Look());
      await tester.tap(find.text('Chat'));
      await sheetSettles(tester);
      await sheetSettles(tester);
      final sent = host.sent('new_session');
      expect(sent, hasLength(1));
      expect(sent.single['chatMode'], 'chat');
      expect(sent.single.containsKey('cwd'), isFalse);
      expect(find.text('Ask anything, look up the news, get help writing'), findsNothing, reason: 'the sheet closed');
    });

    testWidgets('a recent project still starts a coding chat in its folder', (tester) async {
      final host = await open(tester, const Look());
      await tester.tap(find.widgetWithText(ActionChip, 'shop'));
      await sheetSettles(tester);
      await sheetSettles(tester);
      final sent = host.sent('new_session');
      expect(sent, hasLength(1));
      expect(sent.single.containsKey('chatMode'), isFalse);
      expect(sent.single['cwd'], '/ws/shop');
    });
  });

  group('the chat list', () {
    Map<String, dynamic> session(String id, String name, String cwd, {String? mode, int at = 1761900000000}) => {
      'path': '/s/$id.jsonl',
      'id': id,
      'name': name,
      'cwd': cwd,
      'messageCount': 3,
      'modified': at,
      'chatMode': ?mode,
    };

    Future<void> open(WidgetTester tester, Look look, List<Map<String, dynamic>> sessions) async {
      final host = FakeHost();
      host.answers['sessions'] = (_) => sessions;
      final agent = newAgent()..info = {'workspace': '/ws'};
      await pumpLook(tester, look, HomeShell(agent: agent), height: 900);
      await frames(tester);
      await tester.tap(find.bySemanticsLabel(RegExp('^${tr('Chats')}')).first);
      await frames(tester, 12);
    }

    /// A segment of the filter above the list (not a row's own "Chat" label).
    Finder segment(String label) =>
        find.descendant(of: find.byType(PillSegments<String>), matching: find.text(label));

    final mixed = [
      session('a', 'Berita hari ini', '/ws/.chats', mode: 'chat', at: 1761900000000),
      session('b', 'Toko online', '/ws/shop', mode: 'coding', at: 1761800000000),
      session('c', 'Resep nasi goreng', '/ws/.chats', mode: 'chat', at: 1761700000000),
      session('d', 'Catatan lama', '/ws', mode: 'coding', at: 1761600000000),
    ];

    for (final look in _looks) {
      testWidgets('chats and coding chats are told apart (${look.name})', (tester) async {
        await open(tester, look, mixed);
        expect(layoutErrors, isEmpty);
        expect(find.text('Berita hari ini'), findsOneWidget);
        expect(find.text('Toko online'), findsOneWidget);
        // A chat says "Chat", a project says its folder, the workspace says so (not "Quick chat").
        expect(find.text(tr('Chat')), findsWidgets);
        expect(find.text('shop'), findsOneWidget);
        expect(find.text(tr('Workspace')), findsOneWidget);
        expect(find.text('Quick chat'), findsNothing);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('chats_filter_${look.name}')));
      });
    }

    testWidgets('the filter shows only chats, only coding chats, or all', (tester) async {
      await open(tester, const Look(), mixed);
      await tester.tap(segment('Chat'));
      await frames(tester, 6);
      expect(find.text('Berita hari ini'), findsOneWidget);
      expect(find.text('Resep nasi goreng'), findsOneWidget);
      expect(find.text('Toko online'), findsNothing);
      expect(find.text('Catatan lama'), findsNothing);
      await tester.tap(segment('Coding'));
      await frames(tester, 6);
      expect(find.text('Toko online'), findsOneWidget);
      expect(find.text('Catatan lama'), findsOneWidget);
      expect(find.text('Berita hari ini'), findsNothing);
      await tester.tap(segment('All'));
      await frames(tester, 6);
      expect(find.text('Berita hari ini'), findsOneWidget);
      expect(find.text('Toko online'), findsOneWidget);
    });

    testWidgets('with no plain conversation yet there is no filter: the list is as it was', (tester) async {
      await open(tester, const Look(), [mixed[1], mixed[3]]);
      expect(find.text('Toko online'), findsOneWidget);
      expect(find.text('Coding'), findsNothing);
      expect(find.text('Chat'), findsNothing, reason: 'neither a filter nor a chat row');
    });

    testWidgets('a filter with no match says so and keeps the filter to change it', (tester) async {
      await open(tester, const Look(), [mixed[0]]);
      await tester.tap(segment('Coding'));
      await frames(tester, 6);
      expect(find.text('Nothing matches.'), findsOneWidget);
      await tester.tap(segment('All'));
      await frames(tester, 6);
      expect(find.text('Berita hari ini'), findsOneWidget);
    });
  });

  group('the chat screen', () {
    Future<AgentController> open(WidgetTester tester, Look look, {required bool chat, List<ChatEntry> entries = const []}) async {
      FakeHost();
      final agent = agentWith(chat: chat);
      agent.entries.addAll(entries);
      await pumpLook(tester, look, ChatScreen(agent: agent), height: 844);
      await frames(tester);
      return agent;
    }

    for (final look in _looks) {
      testWidgets('empty: a chat greets and suggests things to ask (${look.name})', (tester) async {
        await open(tester, look, chat: true);
        expect(layoutErrors, isEmpty);
        expect(find.text(tr('How can I help?')), findsOneWidget);
        expect(find.text(tr("Today's news")), findsOneWidget);
        expect(find.text(tr('What should we build?')), findsNothing);
        expect(find.text(tr('Ask anything…')), findsOneWidget, reason: 'the composer hint');
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('chat_empty_${look.name}')));
      });
    }

    testWidgets('a chat has no terminal, deploy, project tools or plan mode', (tester) async {
      await open(tester, const Look(), chat: true);
      for (final tooltip in ['Terminal', 'Deploy', 'Project tools', 'More', 'Plan mode', 'Plan mode on']) {
        expect(find.byTooltip(tooltip), findsNothing, reason: tooltip);
        expect(find.bySemanticsLabel(tooltip), findsNothing, reason: tooltip);
      }
      // What a chat does have.
      expect(find.byTooltip('Attach'), findsOneWidget);
      expect(find.byTooltip('Back'), findsNothing); // opened as the only route
    });

    testWidgets('a coding chat keeps all of it', (tester) async {
      await open(tester, const Look(), chat: false);
      expect(find.byTooltip('Terminal'), findsOneWidget);
      expect(find.byTooltip('Deploy'), findsOneWidget);
      expect(find.byTooltip('Project tools'), findsOneWidget);
      expect(find.bySemanticsLabel('Plan mode'), findsWidgets);
      expect(find.text('What should we build?'), findsOneWidget);
    });

    testWidgets('the title says Chat with the model, not a project', (tester) async {
      await open(tester, const Look(), chat: true);
      expect(find.text('Chat · Mock'), findsOneWidget);
    });

    testWidgets('typing / or @ in a chat opens no command or file list', (tester) async {
      final host = FakeHost();
      host.answers['slash_commands'] = (_) => [
        {'name': 'review', 'description': 'Review'},
      ];
      host.answers['files_find'] = (_) => ['a.txt'];
      final agent = agentWith(chat: true);
      await pumpLook(tester, const Look(), ChatScreen(agent: agent));
      await tester.enterText(find.byType(TextField).last, '/re');
      await frames(tester, 12);
      expect(host.sent('slash_commands'), isEmpty, reason: 'not even asked');
      await tester.enterText(find.byType(TextField).last, 'cek @a');
      await frames(tester, 12);
      expect(host.sent('files_find'), isEmpty);
    });

    for (final look in _looks) {
      testWidgets('a web search shows as one sentence, and a tap opens the details (${look.name})', (tester) async {
        final agent = await open(tester, look, chat: true, entries: [UserEntry('Berapa harga emas hari ini?'), searched('harga emas hari ini')]);
        agent.tools['t1'] = ToolRun('t1')
          ..status = ToolStatus.done
          ..output = 'Results for "harga emas hari ini" (duckduckgo):\n\n1. Emas\n   https://example.com/emas';
        agent.notifyListeners();
        await frames(tester);
        expect(layoutErrors, isEmpty);
        expect(find.text(tr('Searched the web for "{x}"').replaceAll('{x}', 'harga emas hari ini')), findsOneWidget);
        expect(find.text('web_search'), findsNothing, reason: 'no tool name in a chat');
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('chat_search_${look.name}')));
        await tester.tap(find.textContaining('harga emas hari ini').first);
        await frames(tester);
        expect(find.textContaining('example.com/emas'), findsWidgets, reason: 'the output is one tap away');
      });
    }

    testWidgets('the same search in a coding chat keeps its tool card', (tester) async {
      final agent = await open(tester, const Look(), chat: false, entries: [UserEntry('cari'), searched('harga emas')]);
      agent.tools['t1'] = ToolRun('t1')..status = ToolStatus.done;
      agent.notifyListeners();
      await frames(tester);
      expect(find.text('web_search'), findsOneWidget);
      expect(find.textContaining('Searched the web for'), findsNothing);
    });

    testWidgets('a search still running says so while it runs', (tester) async {
      final agent = await open(tester, const Look(), chat: true, entries: [UserEntry('berita'), searched('berita terbaru')]);
      agent.tools['t1'] = ToolRun('t1');
      agent.notifyListeners();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Searching the web for "berita terbaru"'), findsOneWidget);
    });
  });
}
