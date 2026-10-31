// UX-02: Stop, Plan mode and the thinking level used to fail without a word when the host did not take them or the link
// to a server was down (an unhandled async error, and a tap that looked like it did nothing).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/ui/chat_extras.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/agent/agent_backend.dart';
import 'package:griphub_agent/ui/tasks_screen.dart';
import 'package:griphub_agent/ui/theme.dart';

import 'harness.dart';

void main() {
  setUpAll(loadAppFonts);
  group('bypass all permissions', bypassTests);
  group('background runs', backgroundNoteTests);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  Future<void> open(WidgetTester tester, FakeHost host) async {
    final agent = newAgent()..busy = true;
    await pumpLook(tester, const Look(), ChatScreen(agent: agent));
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('Stop that the host refuses says so', (tester) async {
    final host = FakeHost();
    host.answers['abort'] = (_) => const HostError('Nothing is running.');
    await open(tester, host);
    await tester.tap(find.byIcon(LucideIcons.square));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Nothing is running.'), findsOneWidget);
  });

  testWidgets('Stop that works says it is stopping', (tester) async {
    final host = FakeHost();
    host.answers['abort'] = (_) => null;
    await open(tester, host);
    await tester.tap(find.byIcon(LucideIcons.square));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Stopping…'), findsOneWidget);
    expect(host.commands.where((c) => c['type'] == 'abort'), hasLength(1));
  });

  testWidgets('Stop with the server link down does not pretend: it says why, and sends nothing', (tester) async {
    final host = FakeHost();
    final agent = newAgent()..busy = true;
    await pumpLook(tester, const Look(), ChatScreen(agent: agent));
    agent.client.connection.value = const Connection(LinkState.offline);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byIcon(LucideIcons.square));
    await tester.pump();
    expect(find.textContaining("can't stop it from here"), findsOneWidget);
    expect(host.commands.where((c) => c['type'] == 'abort'), isEmpty);
  });

  testWidgets('Plan mode that the host refuses says so', (tester) async {
    final host = FakeHost();
    host.answers['plan_mode'] = (_) => const HostError('Plan mode is not available right now.');
    await open(tester, host);
    await tester.tap(find.byTooltip('Plan mode'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Plan mode is not available right now.'), findsOneWidget);
  });
}

// UX-07: "Bypass all permissions" is saved for every chat; the dialog did not say so, the button looked like any other,
// and once on nothing in the chat showed it.
void bypassTests() {
  testWidgets('the chat says approvals are bypassed, and Turn off puts the question back', (tester) async {
    final host = FakeHost();
    host.answers['settings_set'] = (c) => <String, dynamic>{};
    final agent = newAgent()..approvalMode = 'auto';
    await pumpLook(tester, const Look(), ChatScreen(agent: agent));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Permissions bypassed'), findsOneWidget);

    await tester.tap(find.text('Turn off'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(agent.approvalMode, 'ask_risky');
    expect(find.textContaining('Permissions bypassed'), findsNothing);
    expect(host.commands.where((c) => c['type'] == 'settings_set' && (c['settings'] as Map)['approvalMode'] == 'ask_risky'), hasLength(1));
  });

  testWidgets('with the default mode there is no bar', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(), ChatScreen(agent: newAgent()));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Permissions bypassed'), findsNothing);
  });

  testWidgets('the confirmation says it is for every chat until turned off, and its button is the danger colour', (tester) async {
    FakeHost();
    late BuildContext ctx;
    await pumpLook(tester, const Look(), Builder(builder: (c) => Scaffold(body: Center(child: TextButton(onPressed: () => confirmBypass(ctx = c), child: const Text('go'))))));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.textContaining('stays on for all chats until you turn it off in Settings > Approvals'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Bypass'));
    expect(button.style?.backgroundColor?.resolve({}), ctx.palette.danger);
  });
}

// UX-06: a background run on the phone has no approval guard at all (a server's refuse risky actions); the Tasks screen
// said nothing either way.
void backgroundNoteTests() {
  testWidgets('on the phone the Tasks screen says background runs do not ask', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(), TasksScreen(agent: newAgent()), height: 1400);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('Background runs do not ask before acting'), findsOneWidget);
    expect(find.textContaining('whatever the Approvals setting is'), findsOneWidget);
  });

  testWidgets('with a server agent it says what is refused instead', (tester) async {
    FakeHost();
    final agent = newAgent();
    agent.client.remote = const LaunchSpec(['ssh']);
    await pumpLook(tester, const Look(), TasksScreen(agent: agent), height: 1400);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('risky actions (deleting files, force push'), findsOneWidget);
    expect(find.textContaining('Background runs do not ask before acting'), findsNothing);
  });

  testWidgets('in Indonesian', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(language: 'id'), TasksScreen(agent: newAgent()), height: 1400);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('Tugas latar tidak meminta persetujuan'), findsOneWidget);
  });
}
