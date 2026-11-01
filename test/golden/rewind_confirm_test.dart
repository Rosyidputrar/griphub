// UX-05: "Edit & resend" used to move the chat back at once: every later message left the chat and the model's context
// with no question and no undo, and the files the agent changed stayed as they were. Now it asks first, with Fork (a
// copy that leaves this chat as it is) as the first choice.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/ui/message_views.dart' show UserBubble;
import 'package:griphub_agent/ui/rewind_confirm.dart';

import 'harness.dart';

Future<void> frames(WidgetTester tester, [int n = 10]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  test('what going back takes out counts your messages and the agent\'s after it', () {
    final a = UserEntry('satu'), b = UserEntry('dua');
    final entries = <ChatEntry>[a, AssistantEntry(), b, AssistantEntry(), NoticeEntry('x')];
    expect(messagesAfter(entries, a), 3);
    expect(messagesAfter(entries, b), 1);
    expect(messagesAfter(entries, UserEntry('lain')), 0);
  });

  group('sheet', () {
    for (final look in [const Look(), const Look(dark: true, language: 'id'), const Look(language: 'id', textScale: 1.6, width: 320)]) {
      testWidgets('looks right, ${look.name}', (tester) async {
        await pumpLook(
          tester,
          look,
          Scaffold(
            body: Builder(
              builder: (context) => Center(child: ElevatedButton(onPressed: () => confirmRewind(context, messages: 7), child: const Text('open'))),
            ),
          ),
          height: 900,
        );
        await tester.tap(find.text('open'));
        await frames(tester);
        collectLayoutErrors(tester, look.name);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('rewind_confirm_${look.name}')));
      });
    }
  });

  group('in the chat', () {
    late FakeHost host;
    late List<Map<String, dynamic>> sent;

    // The message's own bubble (the chat's title shows the same words).
    final first = find.descendant(of: find.byType(UserBubble), matching: find.text('pesan pertama'));

    Future<void> openMenu(WidgetTester tester) async {
      host = FakeHost();
      host.answers['fork_points'] = (_) => [
        {'entryId': 'e1', 'text': 'pesan pertama'},
        {'entryId': 'e2', 'text': 'pesan kedua'},
      ];
      host.answers['edit_message'] = (_) => {'text': 'pesan pertama'};
      host.answers['messages'] = (_) => <Object>[];
      host.answers['fork_session'] = (_) => {'text': 'pesan pertama'};
      final agent = newAgent();
      agent.entries
        ..add(UserEntry('pesan pertama'))
        ..add(AssistantEntry())
        ..add(UserEntry('pesan kedua'))
        ..add(AssistantEntry());
      await pumpLook(tester, const Look(), ChatScreen(agent: agent), height: 900);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.longPress(first);
      await frames(tester);
      await tester.tap(find.text('Edit & resend'));
      await frames(tester);
      sent = host.commands;
    }

    bool rewound() => sent.any((c) => c['type'] == 'edit_message' || c['type'] == 'fork_session');

    testWidgets('Edit & resend asks first, and says what is lost and what is not', (tester) async {
      await openMenu(tester);
      expect(find.text('Go back to this message?'), findsOneWidget);
      expect(find.textContaining('The 3 messages after it leave this chat'), findsOneWidget);
      expect(find.textContaining('Files the agent already changed stay changed'), findsOneWidget);
      expect(rewound(), isFalse, reason: 'nothing moved yet');
    });

    testWidgets('Cancel leaves the chat exactly as it was', (tester) async {
      await openMenu(tester);
      await tester.tap(find.text('Cancel'));
      await frames(tester);
      expect(rewound(), isFalse);
      expect(find.text('pesan kedua'), findsOneWidget);
    });

    testWidgets('dismissing the sheet changes nothing either', (tester) async {
      await openMenu(tester);
      await tester.tapAt(const Offset(200, 40));
      await frames(tester);
      expect(find.text('Go back to this message?'), findsNothing);
      expect(rewound(), isFalse);
    });

    testWidgets('Go back and edit rewinds, as before, after the question', (tester) async {
      await openMenu(tester);
      await tester.tap(find.text('Go back and edit'));
      await frames(tester);
      expect(sent.where((c) => c['type'] == 'edit_message'), hasLength(1));
      expect(sent.where((c) => c['type'] == 'edit_message').single['entryId'], 'e1');
      expect(sent.where((c) => c['type'] == 'fork_session'), isEmpty);
    });

    testWidgets('Fork instead copies the chat and does not rewind this one', (tester) async {
      await openMenu(tester);
      await tester.tap(find.text('Fork instead: keep this chat'));
      await frames(tester);
      expect(sent.where((c) => c['type'] == 'fork_session'), hasLength(1));
      expect(sent.where((c) => c['type'] == 'edit_message'), isEmpty);
    });

    testWidgets('Fork from here is not asked about: it loses nothing', (tester) async {
      await openMenu(tester);
      await tester.tap(find.text('Cancel'));
      await frames(tester);
      await tester.longPress(first);
      await frames(tester);
      await tester.tap(find.text('Fork from here'));
      await frames(tester);
      expect(find.text('Go back to this message?'), findsNothing);
      expect(sent.where((c) => c['type'] == 'fork_session'), hasLength(1));
    });
  });
}
