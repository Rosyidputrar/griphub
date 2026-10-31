// UX-02: Stop, Plan mode and the thinking level used to fail without a word when the host did not take them or the link
// to a server was down (an unhandled async error, and a tap that looked like it did nothing).
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/ui/chat_screen.dart';

import 'harness.dart';

void main() {
  setUpAll(loadAppFonts);
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
