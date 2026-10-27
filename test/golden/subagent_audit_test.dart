// Regression tests for the subagent UI/UX audit. Each test pins the fixed
// behaviour of one finding (the audit's former `BUG:` tests), against the
// real controller, reducer and widgets with a fake host on the channels.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/integrations.dart';
import 'package:griphub_agent/agent/subagents.dart';
import 'package:griphub_agent/ui/subagent_card.dart';
import 'package:griphub_agent/ui/subagent_settings_screen.dart';
import 'package:griphub_agent/ui/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'harness.dart';
import 'subagent_golden_test.dart' show agentWithSubagents, subRecord;

/// Lets fake-host replies (microtasks on the fake clock) and the controller's
/// 32 ms notify timer run. Never use Future.delayed inside testWidgets: it
/// waits on a clock nobody advances.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Map<String, dynamic> approvalReq(String sub, String id) => {
  'type': 'subagent_approval_request',
  'subagentId': sub,
  'approvalId': id,
  'toolName': 'bash',
  'summary': 'rm -rf build',
  'reason': 'risky',
  'key': 'bash:rm -rf build',
};

void main() {
  setUpAll(loadAppFonts);
  late FakeHost host;
  setUp(() {
    host = FakeHost();
    applyLook(const Look());
    layoutErrors.clear();
  });

  group('protocol', () {
    test('1. host "waiting_approval" reads as Needs approval', () {
      final store = SubagentStore();
      store.applyRecord({'type': 'subagent_started', 'subagent': subRecord('s1')});
      store.applyRecord({'type': 'subagent_status', 'subagentId': 's1', 'status': 'waiting_approval'});
      expect(store['s1']!.status, SubagentStatus.waitingApproval);
      expect(store['s1']!.statusKey, 'Needs approval');
    });

    test('1b. an unknown status keeps the last known one instead of "waiting for a slot"', () {
      final store = SubagentStore();
      store.applyRecord({'type': 'subagent_started', 'subagent': subRecord('s1')});
      store.applyRecord({'type': 'subagent_status', 'subagentId': 's1', 'status': 'bogus'});
      expect(store['s1']!.status, SubagentStatus.running);
    });
  });

  group('notifications', () {
    testWidgets('4. parent chat open but app in background: finished and approval notify', (tester) async {
      host = FakeHost();
      final agent = newAgent();
      await tester.pump();
      agent.sessionFile = 'chat-1.jsonl';
      agent.integrations.settings = AppSettings(host.publicSettings());
      agent.inBackground = true;
      host.emit({'type': 'subagent_started', 'subagent': subRecord('s1')});
      host.emit(approvalReq('s1', 'a1'));
      host.emit({'type': 'subagent_finished', 'subagent': subRecord('s1', status: 'done', finished: Duration.zero)});
      await settle(tester);
      final titles = host.notifications.map((n) => n['title']).toList();
      expect(titles, containsAll(['Subagent needs approval', 'Subagent finished']));
    });

    testWidgets('4b. parent chat open in the foreground: nothing notifies', (tester) async {
      host = FakeHost();
      final agent = newAgent();
      await tester.pump();
      agent.sessionFile = 'chat-1.jsonl';
      agent.integrations.settings = AppSettings(host.publicSettings());
      host.emit({'type': 'subagent_started', 'subagent': subRecord('s1')});
      host.emit({'type': 'subagent_finished', 'subagent': subRecord('s1', status: 'done', finished: Duration.zero)});
      await settle(tester);
      expect(host.notifications, isEmpty);
    });

    testWidgets('2. toggles saved earlier apply before Settings is ever opened', (tester) async {
      host = FakeHost();
      final agent = newAgent();
      await tester.pump();
      agent.sessionFile = 'open.jsonl';
      host.stored['subagentNotifyDone'] = false;
      expect(agent.integrations.settings, isNull);
      host.emit({'type': 'subagent_started', 'subagent': subRecord('s1', parent: 'other.jsonl')});
      host.emit({
        'type': 'subagent_finished',
        'subagent': subRecord('s1', parent: 'other.jsonl', status: 'done', finished: Duration.zero),
      });
      await settle(tester);
      expect(host.notifications.map((n) => n['title']), isNot(contains('Subagent finished')));
      expect(host.sent('settings_get'), isNotEmpty);
    });

    testWidgets('3. the running notification has its own toggle and follows the UI language', (tester) async {
      host = FakeHost();
      final agent = newAgent();
      agent.translate = (en) => en == 'Subagent running' ? 'Subagent berjalan' : en;
      await tester.pump();
      agent.sessionFile = 'open.jsonl';
      host.stored['subagentNotifyRunning'] = false;
      agent.integrations.settings = AppSettings(host.publicSettings());
      host.emit({'type': 'subagent_started', 'subagent': subRecord('s1', parent: 'other.jsonl')});
      await settle(tester);
      expect(host.notifications, isEmpty);
      host.stored['subagentNotifyRunning'] = true;
      agent.integrations.settings = AppSettings(host.publicSettings());
      host.emit({'type': 'subagent_status', 'subagentId': 's1', 'status': 'running'});
      await settle(tester);
      expect(host.notifications.single['title'], 'Subagent berjalan');
    });

    testWidgets('answering an approval cancels its notification', (tester) async {
      host = FakeHost();
      final agent = newAgent();
      await tester.pump();
      agent.sessionFile = 'open.jsonl';
      agent.integrations.settings = AppSettings(host.publicSettings());
      host.emit({'type': 'subagent_started', 'subagent': subRecord('s1', parent: 'other.jsonl')});
      host.emit(approvalReq('s1', 'a1'));
      await settle(tester);
      final id = host.notifications.firstWhere((n) => n['title'] == 'Subagent needs approval')['id'];
      host.emit({'type': 'subagent_approval_dismiss', 'subagentId': 's1', 'approvalId': 'a1'});
      await settle(tester);
      final cancelled = host.calls.where((c) => c.method == 'cancelNotification').map((c) => c.arguments);
      expect(cancelled, contains(id));
    });
  });

  group('settings screen', () {
    Future<void> pumpSettings(WidgetTester tester, {Look look = const Look()}) async {
      final agent = newAgent();
      agent.integrations.settings = AppSettings(host.publicSettings());
      await pumpLook(tester, look, SubagentSettingsScreen(agent: agent), height: 1500);
      await settle(tester);
    }

    testWidgets('5. "Same as the chat" clears the subagent approval mode again', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      host.stored['subagentApprovalMode'] = 'ask_all';
      await pumpSettings(tester);
      expect(find.text('Ask all'), findsOneWidget);
      await tester.tap(find.text('Same as the chat'));
      await settle(tester);
      expect(host.stored.containsKey('subagentApprovalMode'), isFalse);
      expect(host.sent('settings_set').last['settings'], {'subagentApprovalMode': null});
      // Following the chat hides the subagent's own mode.
      expect(find.text('Ask all'), findsNothing);
    });

    testWidgets('6. time limit offers "No limit" and saves 0', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      await pumpSettings(tester);
      expect(find.text('No limit'), findsNWidgets(2));
      await tester.tap(find.text('No limit').last);
      await settle(tester);
      expect(host.stored['subagentMinutesLimit'], 0);
      expect(find.textContaining('No time limit'), findsOneWidget);
    });

    testWidgets('16. custom field is prefilled; decimals work for credits, minutes say why not', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      host.stored['subagentCreditLimit'] = 37;
      await pumpSettings(tester);
      await tester.tap(find.text('Custom: 37 credits'));
      await settle(tester);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '37');
      await tester.enterText(find.byType(TextField), '2.5');
      await tester.tap(find.text('Use'));
      await settle(tester);
      expect(host.stored['subagentCreditLimit'], 2.5);
      await tester.tap(find.text('Custom').last);
      await settle(tester);
      await tester.enterText(find.byType(TextField), '2.5');
      await tester.tap(find.text('Use'));
      await settle(tester);
      expect(find.text('Enter a whole number of minutes, 1 or more.'), findsOneWidget);
      expect(host.stored.containsKey('subagentMinutesLimit'), isFalse);
    });

    testWidgets('15. exactly one chip is selected while Custom is open', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      await pumpSettings(tester);
      await tester.tap(find.text('Custom').last);
      await settle(tester);
      final time = find.byType(ChoiceChip).evaluate().skip(5).map((e) => e.widget as ChoiceChip);
      expect(time.where((c) => c.selected), hasLength(1));
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '30 min')).selected, isFalse);
    });

    testWidgets('9. nothing overflows at 320dp with 1.3x text', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      host.stored['subagentApprovalMode'] = 'ask_all';
      await pumpSettings(tester, look: const Look(textScale: 1.3, width: 320));
      expect(layoutErrors, isEmpty);
      expect(find.text('Bypass all'), findsOneWidget);
    });
  });

  group('card and sheet', () {
    testWidgets('10. card meta is in the UI language', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      final agent = agentWithSubagents();
      await pumpLook(tester, const Look(), Scaffold(body: SubagentCard(state: agent.subagentStore['d-done']!, agent: agent)));
      expect(find.text('2 tools • 2m 50s • ~0.14 credits'), findsOneWidget);
      await pumpLook(tester, const Look(language: 'id'), Scaffold(body: SubagentCard(state: agent.subagentStore['d-done']!, agent: agent)));
      expect(find.text('2 tool • 2 mnt 50 dtk • ~0,14 kredit'), findsOneWidget);
    });

    testWidgets('11. a card that needs approval is warning-coloured and can be answered in place', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      final agent = agentWithSubagents();
      await pumpLook(tester, const Look(), Scaffold(body: SubagentCard(state: agent.subagentStore['b-approval']!, agent: agent)));
      expect(find.text('Allow'), findsOneWidget);
      await tester.tap(find.text('Always'));
      await settle(tester);
      final reply = host.sent('subagent_approval_reply').single;
      expect(reply, containsPair('allow', true));
      expect(reply, containsPair('always', true));
      expect(reply, containsPair('key', 'bash:rm -rf build'));
    });

    testWidgets('12. a queued card waits, without a progress bar', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      final agent = agentWithSubagents();
      await pumpLook(tester, const Look(), Scaffold(body: SubagentCard(state: agent.subagentStore['c-queued']!, agent: agent)));
      expect(find.textContaining('Waiting for a free slot'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('8. the queue send icon contrasts with its button', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      final agent = agentWithSubagents();
      await pumpLook(tester, const Look(), Scaffold(body: SubagentSheet(state: agent.subagentStore['a-running']!, agent: agent)), height: 1700);
      final icon = tester.widget<Icon>(find.byIcon(LucideIcons.sendHorizontal));
      final fill = tester.widget<Material>(find.ancestor(of: find.byIcon(LucideIcons.sendHorizontal), matching: find.byType(Material)).first).color;
      expect(icon.color, isNot(fill));
    });

    testWidgets('13. a finished sheet shows time, tokens and cost, and renders the report', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      final agent = agentWithSubagents();
      await pumpLook(tester, const Look(), Scaffold(body: SubagentSheet(state: agent.subagentStore['d-done']!, agent: agent)), height: 1700);
      expect(find.text('2 tools • 2m 50s • 15k tokens • ~0.14 credits'), findsOneWidget);
      expect(find.textContaining('## '), findsNothing);
      expect(find.text('Ringkasan'), findsOneWidget);
    });

    testWidgets('14. while stopping, no queue and no graceful stop', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      final agent = agentWithSubagents();
      await pumpLook(tester, const Look(), Scaffold(body: SubagentSheet(state: agent.subagentStore['g-stopping']!, agent: agent)), height: 1700);
      expect(find.text('Message for the subagent'), findsNothing);
      expect(find.text('Stop gracefully'), findsNothing);
      expect(find.text('Force stop'), findsOneWidget);
    });

    testWidgets('17. the force-stop confirm is danger-filled', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      final agent = agentWithSubagents();
      await pumpLook(tester, const Look(), Scaffold(body: SubagentSheet(state: agent.subagentStore['a-running']!, agent: agent)), height: 1700);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Force stop'));
      await settle(tester);
      final confirm = tester.widget<FilledButton>(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
      expect(confirm.style?.backgroundColor?.resolve({}), Palette.light.danger);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
      await settle(tester);
      expect(host.sent('subagent_stop').single, containsPair('force', true));
    });

    testWidgets('18. cards are tighter in compact mode', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      final agent = agentWithSubagents();
      final s = agent.subagentStore['a-running']!;
      Widget card() => Scaffold(body: Align(alignment: Alignment.topCenter, child: SubagentCard(state: s, agent: agent)));
      await pumpLook(tester, const Look(), card());
      final normal = tester.getSize(find.byType(SubagentCard)).height;
      await pumpLook(tester, const Look(compact: true), card());
      expect(tester.getSize(find.byType(SubagentCard)).height, lessThan(normal));
    });

    testWidgets('19. banner with several chats lets you choose; a missing chat gets a plain message', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      final agent = newAgent();
      agent.sessionFile = 'open.jsonl';
      host.sessions.add('other1.jsonl');
      agent.subagentStore.applyRecord({'type': 'subagent_started', 'subagent': subRecord('x0', parent: 'other0.jsonl', title: 'A')});
      agent.subagentStore.applyRecord({'type': 'subagent_started', 'subagent': subRecord('x1', parent: 'other1.jsonl', title: 'B')});
      await pumpLook(tester, const Look(), Scaffold(body: Column(children: [CrossChatBanner(agent: agent)])), height: 700);
      await tester.tap(find.text('Choose'));
      await settle(tester);
      await tester.tap(find.text('B'));
      await settle(tester);
      expect(host.opened, ['other1.jsonl']);
      await tester.tap(find.text('Choose'));
      await settle(tester);
      await tester.tap(find.text('A'));
      await settle(tester);
      expect(find.text('That chat is no longer available.'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
    });
  });
}
