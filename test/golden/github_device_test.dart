// Signing in to GitHub with a code: the host waits for the approval, the app only watches. Leaving the screen does not
// end the sign-in (the host goes on, and tells the app when it is done), coming back to the screen picks it up again,
// and only the Cancel button stops the host from waiting.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_backend.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/clock.dart';
import 'package:griphub_agent/agent/integrations.dart';
import 'package:griphub_agent/ui/accounts_screen.dart';
import 'package:griphub_agent/ui/i18n.dart';
import 'package:griphub_agent/ui/theme.dart';

import '../support/fake_backend.dart';
import 'harness.dart';

Map<String, dynamic> summary({required bool signedIn}) => {
  'github': signedIn ? {'login': 'akun1', 'name': 'Akun Satu', 'avatarUrl': null, 'expired': false} : null,
  'vercel': null,
  'cloudflare': null,
  'ssh': {'publicKey': null, 'hosts': const []},
};

const pending = {
  'status': 'pending',
  'deviceCode': 'd1',
  'userCode': 'ABCD-1234',
  'verificationUri': 'https://github.com/login/device',
  'expiresIn': 600,
  'interval': 1,
};

/// Time passes in the app: the wait loop sleeps whole seconds.
Future<void> seconds(WidgetTester tester, int n) async {
  for (var i = 0; i < n * 2; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  group('the screen', () {
    late FakeHost host;
    var polls = 0;

    Future<void> open(WidgetTester tester, {Object? Function(Map<String, dynamic>)? status, Object? Function(Map<String, dynamic>)? poll}) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      polls = 0;
      host.answers['integrations'] = (_) => summary(signedIn: false);
      host.answers['github_device_status'] = status ?? (_) => pending;
      host.answers['github_device_poll'] = poll ?? (_) {
        polls++;
        return polls < 2 ? {'status': 'pending'} : {'status': 'done', 'state': summary(signedIn: true)};
      };
      host.answers['github_device_cancel'] = (_) => {'status': 'none'};
      await pumpLook(tester, const Look(), AccountsScreen(agent: newAgent()));
      await seconds(tester, 1);
    }

    testWidgets('opened while the host waits on a sign-in: the code is shown again, and the wait ends in the account', (tester) async {
      await open(tester);
      expect(find.text('ABCD-1234'), findsOneWidget, reason: 'the code of the flow the host is waiting on');
      expect(find.text('Waiting for you to approve on GitHub…'), findsOneWidget);
      expect(host.sent('github_device_start'), isEmpty, reason: 'a new flow was not started over the old one');
      await seconds(tester, 3);
      expect(host.sent('github_device_poll').first['deviceCode'], 'd1');
      expect(find.text('Akun Satu'), findsOneWidget, reason: 'approved: the account shows');
      expect(find.text('ABCD-1234'), findsNothing);
    });

    testWidgets('leaving the screen does not cancel the host; the Cancel button does, and brings the plain sign-in back', (tester) async {
      await open(tester, poll: (_) => {'status': 'pending'});
      expect(find.text('ABCD-1234'), findsOneWidget);
      await tester.pumpWidget(const SizedBox()); // the screen is left
      await seconds(tester, 2);
      expect(host.sent('github_device_cancel'), isEmpty, reason: 'the host goes on waiting for the approval');

      await open(tester, poll: (_) => {'status': 'pending'});
      await tester.tap(find.text('Cancel'));
      await seconds(tester, 1);
      expect(host.sent('github_device_cancel'), hasLength(1), reason: 'the user gave up: the host stops too');
      expect(find.text('ABCD-1234'), findsNothing);
      expect(find.text('Sign in with GitHub'), findsOneWidget);
    });

    testWidgets('nothing under way: the plain sign-in', (tester) async {
      await open(tester, status: (_) => {'status': 'none'});
      expect(find.text('Sign in with GitHub'), findsOneWidget);
      expect(find.text('ABCD-1234'), findsNothing);
    });

    testWidgets('a host that has no such command (an older one): the plain sign-in', (tester) async {
      await open(tester, status: (_) => const HostError('Unknown command: github_device_status'));
      expect(find.text('Sign in with GitHub'), findsOneWidget);
      expect(find.text('ABCD-1234'), findsNothing);
    });

    testWidgets('an answer of no shape at all (nothing, or a host that answers everything with nothing) is nothing under way', (tester) async {
      await open(tester, status: (_) => null);
      expect(find.text('Sign in with GitHub'), findsOneWidget);
      expect(find.text('ABCD-1234'), findsNothing);
    });

    testWidgets('a flow that already ended is not shown as waiting', (tester) async {
      await open(tester, status: (_) => {...pending, 'status': 'expired'});
      expect(find.text('ABCD-1234'), findsNothing);
      expect(find.text('Sign in with GitHub'), findsOneWidget);
    });

    testWidgets('approved while the screen is open and nobody is asking: the host tells the app, and the account shows', (tester) async {
      await open(tester, poll: (_) => {'status': 'pending'});
      expect(find.text('ABCD-1234'), findsOneWidget);
      host.emit({'type': 'integrations', 'summary': summary(signedIn: true)});
      await seconds(tester, 1);
      expect(find.text('Akun Satu'), findsOneWidget);
      expect(find.text('ABCD-1234'), findsNothing);
    });

    testWidgets('says whose accounts these are: this phone\'s agent, or the server\'s', (tester) async {
      await open(tester, status: (_) => {'status': 'none'});
      expect(find.textContaining("These accounts are for this phone's agent"), findsOneWidget);
    });
  });

  testWidgets('on a server the accounts are said to be the server\'s, and that the phone\'s agent has its own', (tester) async {
    FakeHost();
    final backend = FakeBackend()
      ..onCommand = (c) => switch (c['type']) {
        'hello' || 'state' => {'sessionId': 's', 'sessionFile': 's.jsonl', 'cwd': '/w', 'isStreaming': false},
        'integrations' => summary(signedIn: false),
        'github_device_status' => {'status': 'none'},
        'messages' || 'providers' || 'models' || 'sessions' || 'subagent_list' || 'approvals_pending' || 'job_list' => const [],
        'runs' => {'runs': const [], 'schedules': const [], 'concurrency': 1},
        'settings_get' => {'dns': 'system'},
        _ => const {},
      };
    final agent = AgentController(AgentClient(backend: backend)..remote = const LaunchSpec(['ssh', 'x']));
    await tester.runAsync(() => agent.boot());
    await pumpLook(tester, const Look(), AccountsScreen(agent: agent));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.textContaining("These accounts are the server's"), findsOneWidget);
    expect(find.textContaining("for this phone's agent"), findsNothing);
  });

  test('the strings of the sign-in and the box guide have Indonesian', () {
    Appearance.instance.language = 'id';
    addTearDown(() => Appearance.instance.language = 'en');
    for (final en in [
      "These accounts are the server's: the agent there signs in to them, so what you connect on this phone's own agent does not carry over.",
      "These accounts are for this phone's agent. A server agent keeps its own: connect there too if you use one.",
      'Commands hang and never answer',
      'With the box on, a command that waits for ever with no output, or is refused with "the agent\'s box did not answer", means the box is stuck, not the agent. Reset the box in Settings > The agent\'s box and try again; if that does not help, turn the box off there: commands then run on the server itself.',
    ]) {
      expect(tr(en), isNot(en), reason: 'untranslated: $en');
    }
  });

  group('watching the host\'s wait', () {
    late FakeBackend backend;
    late AgentController agent;
    var calls = 0;

    GithubDeviceFlow flow({int expiresInSeconds = 600}) => (
      deviceCode: 'd1',
      userCode: 'ABCD-1234',
      verificationUri: 'https://github.com/login/device',
      expiresAt: clock().millisecondsSinceEpoch + expiresInSeconds * 1000,
      interval: 1,
    );

    /// What the host answers to everything a boot asks, so the controller comes up.
    Object? base(Map<String, dynamic> c) => switch (c['type']) {
      'hello' || 'state' => {'sessionId': 's', 'sessionFile': 's.jsonl', 'cwd': '/w', 'isStreaming': false},
      'messages' || 'providers' || 'models' || 'sessions' || 'subagent_list' || 'approvals_pending' || 'job_list' => const [],
      'runs' => {'runs': const [], 'schedules': const [], 'concurrency': 1},
      'settings_get' => {'dns': 'system'},
      _ => const {},
    };

    setUp(() {
      calls = 0;
      backend = FakeBackend();
      agent = AgentController(AgentClient(backend: backend)..remote = const LaunchSpec(['ssh', 'x']));
    });

    test('a link that drops meanwhile is waited out, not taken for a failure: the host is still waiting', () async {
      backend.onCommand = (c) {
        if (c['type'] != 'github_device_poll') return base(c);
        calls++;
        if (calls == 1) throw const FakeFailure('The connection to the server was lost.', code: 'connection_lost');
        if (calls == 2) throw const FakeFailure('Not connected to the server.', code: 'offline');
        return {'status': 'done', 'state': summary(signedIn: true)};
      };
      await agent.boot();
      final ok = await agent.integrations.githubDeviceWait(flow(), cancelled: () => false);
      expect(ok, isTrue);
      expect(calls, 3);
      expect(agent.integrations.github?.login, 'akun1');
    });

    test('a link that stays down until the code expires says it expired', () async {
      backend.onCommand = (c) => c['type'] == 'github_device_poll' ? throw const FakeFailure('lost', code: 'offline') : base(c);
      await agent.boot();
      await expectLater(
        agent.integrations.githubDeviceWait(flow(expiresInSeconds: -1), cancelled: () => false),
        throwsA('The code expired. Try again.'),
      );
    });

    test('what the host says went wrong is not waited out: a wrong Client ID reaches the user', () async {
      backend.onCommand = (c) => c['type'] == 'github_device_poll'
          ? throw const FakeFailure('The client_id and/or client_secret passed are incorrect.')
          : base(c);
      await agent.boot();
      await expectLater(
        agent.integrations.githubDeviceWait(flow(), cancelled: () => false),
        throwsA(isA<AgentError>().having((e) => e.message, 'message', contains('client_id'))),
      );
    });

    test('the host\'s seconds left become a time by the app\'s own clock', () async {
      backend.onCommand = (c) => c['type'] == 'github_device_status' ? pending : base(c);
      await agent.boot();
      final before = clock().millisecondsSinceEpoch;
      final f = await agent.integrations.githubDeviceStatus();
      expect(f?.userCode, 'ABCD-1234');
      expect(f!.expiresAt, inInclusiveRange(before + 599_000, clock().millisecondsSinceEpoch + 600_000));
    });
  });
}
