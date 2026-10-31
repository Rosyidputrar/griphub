import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_backend.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/features.dart';
import 'package:griphub_agent/ui/chat_extras.dart';
import 'package:griphub_agent/ui/theme.dart';

import 'support/fake_backend.dart';

/// Regression test for the approval double-tap queue-jump: answering the
/// first card must NOT immediately slide the next card into its place, or
/// the second half of a double-tap approves an action the user never saw.
void main() {
  group('answering while the link is down', offlineApprovalTests);
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

    // After the hold window the next card cross-fades in and can be answered.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('rm -rf /tmp/y'), findsOneWidget);
    expect(find.text('rm -rf /tmp/x'), findsNothing);
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

/// UX-01: an answer given while the link to a server is down used to make the card vanish, and the host went on waiting
/// for it with nothing left to tap.
void offlineApprovalTests() {
  Approval card(String id) => Approval({
    'approvalId': id,
    'toolName': 'bash',
    'summary': 'rm -rf /tmp/$id',
    'reason': 'risky',
    'key': 'bash:$id',
  });

  late FakeBackend backend;
  late AgentClient client;
  late Features features;
  late List<Map<String, dynamic>> replies;

  setUp(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(PlatformBackend.method, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(PlatformBackend.method, null));
    replies = [];
    backend = FakeBackend()
      ..onCommand = (c) {
        if (c['type'] == 'approval_reply') replies.add(c);
        return null;
      };
    client = AgentClient(backend: backend)..remote = const LaunchSpec(['ssh']);
    features = Features(client);
  });

  Future<void> show(WidgetTester tester) async {
    await tester.runAsync(client.start);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [Palette.dark]),
        home: Scaffold(body: ApprovalCards(features: features)),
      ),
    );
  }

  testWidgets('with the link down the card stays, its buttons are off, and it says why', (tester) async {
    features.approvals.add(card('a1'));
    await show(tester);
    client.connection.value = const Connection(LinkState.offline);
    await tester.pump();

    expect(find.text('rm -rf /tmp/a1'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    expect(find.textContaining('still waiting for your answer'), findsOneWidget);

    client.connection.value = const Connection(LinkState.connected);
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull, reason: 'and back on when the link is');
    expect(find.textContaining('still waiting for your answer'), findsNothing);
  });

  testWidgets('an answer the host did not take brings the card back and says so', (tester) async {
    features.approvals.add(card('a1'));
    features.approvals.add(card('a2'));
    backend.onCommand = (c) => throw const FakeFailure('Not connected to the server.', code: 'offline');
    await show(tester);
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    expect(features.approvals.map((a) => a.id), ['a1', 'a2'], reason: 'both are still waiting, in order');
    expect(find.text('rm -rf /tmp/a1'), findsOneWidget, reason: 'the same card, not the next one');
    expect(find.text('rm -rf /tmp/a2'), findsNothing);
    expect(find.text('Not connected to the server.'), findsOneWidget, reason: 'and the person is told');
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull, reason: 'and can try again');
  });

  testWidgets('after the link is back the same card can be answered, once', (tester) async {
    features.approvals.add(card('a1'));
    await show(tester);
    client.connection.value = const Connection(LinkState.offline);
    // Tapped in the moment before the screen caught up: Features.answer itself refuses and restores.
    await expectLater(features.answer(features.approvals.first, allow: true), throwsA(isA<AgentError>()));
    expect(features.approvals.map((a) => a.id), ['a1']);

    client.connection.value = const Connection(LinkState.connected);
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect(replies.map((r) => r['approvalId']), ['a1']);
  });
}
