// UX-09: running out of budget was shown as a small muted line, in English, with the number in English format and
// nowhere to go. A limit stop is now drawn as an error, in the app's language, with a way to the setting.
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/host_messages.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/ui/errors.dart';
import 'package:griphub_agent/ui/i18n.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/ui/usage_screen.dart';

import 'harness.dart';

const _budget = 'Daily budget of 5 credits reached (5.02 credits spent today). Raise it in Settings → Usage.';

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  test('which host messages are limit stops', () {
    expect(limitStopOf(_budget), LimitStop.budget);
    expect(limitStopOf('Stopped after 150 tool calls in one request.'), LimitStop.toolCalls);
    expect(limitStopOf('The background job ended.'), isNull);
    expect(limitStopOf('Daily budget of five credits reached'), isNull);
  });

  test('said in the app\'s language, with its number format', () {
    expect(trHost(_budget), _budget, reason: 'English as it is');
    applyLook(const Look(language: 'id'));
    expect(trHost(_budget), 'Batas harian 5 kredit tercapai (terpakai 5,02 hari ini). Naikkan di Pengaturan → Pemakaian.');
    expect(trHost('Stopped after 150 tool calls in one request.'), 'Berhenti setelah 150 panggilan tool dalam satu permintaan.');
    expect(trHost('Something the host said'), 'Something the host said', reason: 'other text is left as it is');
    // The same text as an error that came back from a command (checkBudget throws it).
    expect(friendlyError(AgentError(_budget)), 'Batas harian 5 kredit tercapai (terpakai 5,02 hari ini). Naikkan di Pengaturan → Pemakaian.');
  });

  testWidgets('the chat shows a budget stop as an error, with Raise limit that opens Usage', (tester) async {
    final host = FakeHost();
    final agent = newAgent();
    await pumpLook(tester, const Look(language: 'id'), ChatScreen(agent: agent));
    await tester.pump(const Duration(milliseconds: 100));
    host.emit({'type': 'notice', 'message': _budget});
    await tester.pump(const Duration(milliseconds: 100));
    final entry = agent.entries.whereType<NoticeEntry>().single;
    expect(entry.error, isTrue, reason: 'drawn as an error, not a muted hint');
    expect(find.textContaining('Batas harian 5 kredit tercapai (terpakai 5,02 hari ini)'), findsOneWidget);
    expect(find.text('Naikkan batas'), findsOneWidget);
    await tester.tap(find.text('Naikkan batas'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(UsageScreen), findsOneWidget);
  });

  testWidgets('another notice stays a quiet line', (tester) async {
    final host = FakeHost();
    final agent = newAgent();
    await pumpLook(tester, const Look(), ChatScreen(agent: agent));
    await tester.pump(const Duration(milliseconds: 100));
    host.emit({'type': 'notice', 'message': 'Switched to Mock after an error: boom'});
    await tester.pump(const Duration(milliseconds: 100));
    expect(agent.entries.whereType<NoticeEntry>().single.error, isFalse);
    expect(find.text('Raise limit'), findsNothing);
  });
}
