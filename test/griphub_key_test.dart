// UX-03: a mistyped or half-pasted GripHub key, the commonest first-run failure, showed the router's raw HTTP reply in
// English. These pin what a first-time user reads, in both languages, and that a failure that is not the host's still
// says something.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/ui/griphub_screen.dart';

import 'golden/harness.dart';

void main() {
  setUpAll(loadAppFonts);
  setUp(() => applyLook(const Look()));

  group('what a key problem reads like', () {
    test('a rejected key', () {
      for (final raw in [
        '401 Unauthorized: {"error":{"message":"Invalid API key","type":"invalid_request_error"}}',
        '403 Forbidden: {"error":"no"}',
        'Invalid API key',
      ]) {
        expect(griphubKeyProblem(AgentError(raw)), 'The key was not accepted. Check that you copied all of it, with no spaces.', reason: raw);
      }
    });

    test('a router that does not answer', () {
      for (final raw in ['fetch failed', 'The operation was aborted due to timeout', 'request timed out']) {
        expect(griphubKeyProblem(AgentError(raw)), 'GripHub did not answer. Check your connection and try again.', reason: raw);
      }
    });

    test('another status is not shown as a number and a JSON body', () {
      final said = griphubKeyProblem(AgentError('502 Bad Gateway: <html>...</html>'));
      expect(said, 'GripHub could not load the models. Try again in a moment.');
      expect(said, isNot(contains('502')));
    });

    test('a failure that is not the host\'s (a platform error) still says something', () {
      expect(griphubKeyProblem(Exception('boom')), isNotEmpty);
      expect(griphubKeyProblem(StateError('')), isNotEmpty);
    });

    test('in Indonesian', () {
      applyLook(const Look(language: 'id'));
      expect(griphubKeyProblem(AgentError('401 Unauthorized: {}')), 'Key ditolak. Pastikan tersalin utuh, tanpa spasi.');
      expect(griphubKeyProblem(AgentError('fetch failed')), 'GripHub tidak menjawab. Periksa koneksi lalu coba lagi.');
    });
  });

  testWidgets('the screen shows it under the button, instead of the raw reply', (tester) async {
    final host = FakeHost();
    host.answers['custom_provider_fetch_models'] = (_) => const HostError('401 Unauthorized: {"error":{"message":"Invalid API key"}}');
    host.answers['custom_providers'] = (_) => <Object>[];
    await pumpLook(tester, const Look(), GripHubScreen(agent: newAgent()));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(find.byType(TextField).first, 'sk-typo');
    await tester.tap(find.text('Save & load models'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('The key was not accepted. Check that you copied all of it, with no spaces.'), findsOneWidget);
    expect(find.textContaining('Invalid API key'), findsNothing);
    expect(find.textContaining('401'), findsNothing);
  });
}
