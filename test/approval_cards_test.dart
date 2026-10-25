import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/features.dart';
import 'package:griphub_agent/ui/chat_extras.dart';
import 'package:griphub_agent/ui/theme.dart';

/// Regression test for the approval double-tap queue-jump: answering the
/// first card must NOT immediately slide the next card into its place, or
/// the second half of a double-tap approves an action the user never saw.
void main() {
  testWidgets('answering keeps the first card until the next one may appear',
      (tester) async {
    final answered = <String>[];
    final binding = TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('griphub/agent'),
      (call) async {
        if (call.method == 'send') {
          final payload = jsonDecode(call.arguments as String) as Map;
          if (payload['type'] == 'approval_reply') {
            answered.add(payload['approvalId'] as String);
          }
        }
        return null;
      },
    );
    binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('griphub/agent/events'),
      MockStreamHandler.inline(onListen: (_, _) {}, onCancel: (_) {}),
    );

    final features = Features(AgentClient());
    features.approvals.addAll([
      Approval({
        'approvalId': 'a1',
        'toolName': 'bash',
        'summary': 'rm -rf /tmp/x',
        'reason': 'risky',
        'key': 'bash:rm -rf /tmp/x',
      }),
      Approval({
        'approvalId': 'a2',
        'toolName': 'bash',
        'summary': 'rm -rf /tmp/y',
        'reason': 'risky',
        'key': 'bash:rm -rf /tmp/y',
      }),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [Palette.dark]),
        home: Scaffold(body: ApprovalCards(features: features)),
      ),
    );
    expect(find.text('rm -rf /tmp/x'), findsOneWidget);

    // Allow is the only FilledButton on the card (Deny/Always are outlined).
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.idle();

    // Only the first approval was answered, and its card is still the one
    // on screen: a bounce tap can only hit the disabled answered card.
    expect(answered, ['a1']);
    expect(find.text('rm -rf /tmp/x'), findsOneWidget);
    expect(find.text('rm -rf /tmp/y'), findsNothing);

    // After the hold window the next card appears and can be answered.
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('rm -rf /tmp/y'), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.idle();
    expect(answered, ['a1', 'a2']);
  });

  testWidgets('answering the same approval twice sends one reply',
      (tester) async {
    final answered = <String>[];
    final binding = TestDefaultBinaryMessengerBinding.instance;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('griphub/agent'),
      (call) async {
        if (call.method == 'send') {
          final payload = jsonDecode(call.arguments as String) as Map;
          if (payload['type'] == 'approval_reply') {
            answered.add(payload['approvalId'] as String);
          }
        }
        return null;
      },
    );
    binding.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('griphub/agent/events'),
      MockStreamHandler.inline(onListen: (_, _) {}, onCancel: (_) {}),
    );

    final features = Features(AgentClient());
    final approval = Approval({
      'approvalId': 'a9',
      'toolName': 'bash',
      'summary': 'rm -rf /tmp/z',
      'reason': 'risky',
      'key': 'bash:rm -rf /tmp/z',
    });
    features.approvals.add(approval);
    // The reply round-trip never completes in tests (no native host), so
    // the calls are fire-and-forget here; the guard is what is under test.
    unawaited(features.answer(approval, allow: true));
    await tester.pump();
    unawaited(features.answer(approval, allow: true));
    await tester.pump();
    expect(answered, ['a9']);
  });
}
