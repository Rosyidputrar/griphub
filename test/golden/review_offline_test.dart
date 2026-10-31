// Review before commit (every changed file with its diff, a message the agent writes, Commit or Commit and push), the
// banner a turn leaves when there is something to commit, and the bubble of a message waiting for the server.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/agent/offline_prompts.dart';
import 'package:griphub_agent/ui/chat_extras.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/ui/diff_view.dart';
import 'package:griphub_agent/ui/message_views.dart';
import 'package:griphub_agent/ui/review_screen.dart';

import 'harness.dart';

const _looks = [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)];

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Map<String, dynamic> _review({List<Map<String, dynamic>>? files}) => {
  'repo': true,
  'root': '/w',
  'branch': 'main',
  'upstream': 'origin/main',
  'ahead': 0,
  'behind': 0,
  'remote': 'git@github.com:me/shop.git',
  'files':
      files ??
      [
        {'path': 'lib/login.dart', 'code': ' M', 'staged': false, 'unstaged': true, 'untracked': false},
        {'path': 'lib/ui/login_form.dart', 'code': ' M', 'staged': false, 'unstaged': true, 'untracked': false},
        {'path': 'test/login_test.dart', 'code': '??', 'staged': false, 'unstaged': true, 'untracked': true},
        {'path': 'assets/logo.png', 'code': ' M', 'staged': false, 'unstaged': true, 'untracked': false},
      ],
  'stats': {
    'lib/login.dart': {'additions': 2, 'deletions': 1},
    'lib/ui/login_form.dart': {'additions': 5, 'deletions': 3},
    'test/login_test.dart': {'additions': 12, 'deletions': 0},
    'assets/logo.png': {'additions': 0, 'deletions': 0, 'binary': true},
  },
};

String _patchFor(String path) => '''diff --git a/$path b/$path
--- a/$path
+++ b/$path
@@ -1,3 +1,4 @@
 Future<void> signIn(String email) async {
-  await api.login(email);
+  await api.login(email.trim());
+  notifyListeners();
 }
''';

FakeHost _host({Object? message = 'Trim the email before signing in\n\nA trailing space made the login fail.'}) {
  final host = FakeHost();
  host.answers['git_review'] = (_) => _review();
  host.answers['git_diff'] = (c) => {'patch': _patchFor(c['file'] as String? ?? '')};
  host.answers['git_commit_message'] = (_) => message is HostError ? message : {'message': message};
  host.answers['git_commit'] = (_) => {'commit': 'a1b2c3d Trim the email before signing in'};
  host.answers['git_push'] = (_) => null;
  return host;
}

void main() {
  setUpAll(loadAppFonts);
  group('which names look like secrets', secretNameTests);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  group('review before commit', () {
    for (final look in _looks) {
      testWidgets('golden: the changed files, their diffs and the message the agent wrote ${look.name}', (tester) async {
        _host();
        await pumpLook(tester, look, ReviewScreen(agent: newAgent()), height: 1100);
        await frames(tester);
        expect(find.byType(DiffView), findsNWidgets(3), reason: 'the first three files open');
        expect(find.text('Trim the email before signing in\n\nA trailing space made the login fail.'), findsOneWidget);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('review_${look.name}')));
      });
    }

    testWidgets('Commit commits the ticked files with the message, then closes', (tester) async {
      final host = _host();
      await pumpLook(tester, const Look(), Scaffold(body: Builder(builder: (c) => TextButton(
        onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => ReviewScreen(agent: newAgent()))),
        child: const Text('open'),
      ))));
      await tester.tap(find.text('open'));
      await frames(tester, 12);
      await tester.enterText(find.byType(TextField), 'Fix the login');
      await tester.tap(find.text('Commit'));
      await frames(tester, 12);
      final commit = host.sent('git_commit').single;
      expect(commit['message'], 'Fix the login', reason: 'what the user typed over the agent\'s message');
      expect(commit['all'], false, reason: 'not `git add -A`: the files are named');
      expect(commit['paths'], ['lib/login.dart', 'lib/ui/login_form.dart', 'test/login_test.dart', 'assets/logo.png']);
      expect(host.sent('git_push'), isEmpty);
      expect(find.byType(ReviewScreen), findsNothing);
      expect(find.textContaining('Committed: a1b2c3d'), findsOneWidget);
    });

    testWidgets('Commit and push pushes after the commit', (tester) async {
      final host = _host();
      await pumpLook(tester, const Look(), Scaffold(body: Builder(builder: (c) => TextButton(
        onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => ReviewScreen(agent: newAgent()))),
        child: const Text('open'),
      ))), height: 1100);
      await tester.tap(find.text('open'));
      await frames(tester, 12);
      // The button says where it goes.
      await tester.tap(find.text('Commit and push to origin/main'));
      for (var i = 0; i < 40 && find.byType(ReviewScreen).evaluate().isNotEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(host.sent('git_commit'), hasLength(1));
      expect(host.sent('git_push'), hasLength(1));
      expect(find.byType(ReviewScreen), findsNothing, reason: 'closed once pushed');
      expect(find.textContaining('Committed and pushed'), findsOneWidget);
    });

    Future<FakeHost> openWith(WidgetTester tester, List<Map<String, dynamic>> files) async {
      final host = _host();
      host.answers['git_review'] = (_) => _review(files: files);
      await pumpLook(tester, const Look(), Scaffold(body: Builder(builder: (c) => TextButton(
        onPressed: () => Navigator.of(c).push(MaterialPageRoute<void>(builder: (_) => ReviewScreen(agent: newAgent()))),
        child: const Text('open'),
      ))), height: 1100);
      await tester.tap(find.text('open'));
      await frames(tester, 12);
      await tester.enterText(find.byType(TextField), 'Add the form');
      await tester.pump();
      return host;
    }

    Map<String, dynamic> file(String path, {String code = ' M'}) =>
        {'path': path, 'code': code, 'staged': false, 'unstaged': true, 'untracked': code == '??'};

    testWidgets('a file that looks like a secret starts unticked, says why, and is not committed', (tester) async {
      final host = await openWith(tester, [file('lib/a.dart'), file('.env', code: '??'), file('keys/id_ed25519', code: '??')]);
      expect(find.text('May contain secrets: not included unless you tick it'), findsNWidgets(2));
      final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).map((c) => c.value).toList();
      expect(boxes, [true, false, false]);
      expect(find.text('Commit'), findsNothing, reason: 'the button counts what goes in: "Commit (1)"');
      await tester.tap(find.text('Commit (1)'));
      await frames(tester, 12);
      expect(host.sent('git_commit').single['paths'], ['lib/a.dart']);
    });

    testWidgets('ticking a secret-looking file includes it; unticking a file leaves it out; none ticked cannot commit', (tester) async {
      final host = await openWith(tester, [file('lib/a.dart'), file('.env', code: '??')]);
      await tester.tap(find.byType(Checkbox).at(1)); // the .env, on purpose
      await tester.pump();
      await tester.tap(find.byType(Checkbox).at(0)); // not the code
      await tester.pump();
      await tester.tap(find.byType(Checkbox).at(0));
      await tester.pump();
      await tester.tap(find.text('Commit'));
      await frames(tester, 12);
      expect(host.sent('git_commit').single['paths'], ['lib/a.dart', '.env']);
    });

    testWidgets('with nothing ticked Commit is off', (tester) async {
      await openWith(tester, [file('lib/a.dart')]);
      await tester.tap(find.text('Select none'));
      await tester.pump();
      expect(tester.widget<FilledButton>(find.ancestor(of: find.textContaining('Commit'), matching: find.byType(FilledButton)).first).onPressed, isNull);
      await tester.tap(find.text('Select all'));
      await tester.pump();
      expect(tester.widget<FilledButton>(find.ancestor(of: find.text('Commit'), matching: find.byType(FilledButton)).first).onPressed, isNotNull);
    });

    testWidgets('a message the agent could not write says why, and the field stays for typing one', (tester) async {
      _host(message: const HostError('Daily budget of 5 credits reached'));
      await pumpLook(tester, const Look(), ReviewScreen(agent: newAgent()), height: 1100);
      await frames(tester);
      expect(find.textContaining('Daily budget of 5 credits reached'), findsOneWidget);
      final commit = tester.widget<FilledButton>(find.ancestor(of: find.text('Commit'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
      expect(commit.onPressed, isNull, reason: 'no commit without a message');
    });

    testWidgets('nothing to commit says so', (tester) async {
      final host = FakeHost();
      host.answers['git_review'] = (_) => _review(files: const []);
      await pumpLook(tester, const Look(), ReviewScreen(agent: newAgent()));
      await frames(tester);
      expect(find.text('Nothing to commit'), findsOneWidget);
      expect(host.sent('git_commit_message'), isEmpty, reason: 'no message asked for nothing');
    });
  });

  testWidgets('after a turn with changes left, the chat offers to review and commit them', (tester) async {
    final host = _host();
    host.answers['git_status'] = (_) => _review();
    final agent = newAgent();
    await pumpLook(tester, const Look(), ChatScreen(agent: agent));
    await frames(tester, 2);
    expect(find.byType(ReviewBanner), findsNothing, reason: 'not before a turn');
    host.emit({
      'type': 'event',
      'event': {'type': 'agent_start'},
    });
    await frames(tester, 2);
    host.emit({
      'type': 'event',
      'event': {'type': 'agent_settled'},
    });
    await frames(tester);
    expect(find.text('4 files changed'), findsOneWidget);
    await expectLater(find.byType(ReviewBanner), matchesGoldenFile(golden('review_banner')));
    await tester.tap(find.byTooltip('Close'));
    await frames(tester);
    expect(find.byType(ReviewBanner), findsNothing);
  });

  group('a message waiting for the server', () {
    for (final look in _looks) {
      testWidgets('golden: waiting, and refused once back ${look.name}', (tester) async {
        FakeHost();
        await pumpLook(
          tester,
          look,
          Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                QueuedMessageView(
                  prompt: QueuedPrompt({'id': 'a', 'text': 'Add a dark mode to the settings page', 'images': 0}),
                  status: look.language == 'id' ? 'Menunggu koneksi' : 'Waiting for the connection',
                  statusIcon: LucideIcons.wifiOff,
                  onCancel: () {},
                ),
                const SizedBox(height: 16),
                QueuedMessageView(
                  prompt: QueuedPrompt({'id': 'b', 'text': 'And deploy it', 'images': 1}),
                  error: 'Daily budget of 5 credits reached',
                  onRetry: () {},
                  onCancel: () {},
                ),
              ],
            ),
          ),
          height: 320,
        );
        await frames(tester);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('offline_prompt_${look.name}')));
      });
    }

    testWidgets('in the chat: the bubble, and Cancel gives the text back to the composer', (tester) async {
      FakeHost();
      final agent = newAgent()..offlinePrompts = [OfflinePrompt(id: 'o1', text: 'Fix the footer')];
      await pumpLook(tester, const Look(), ChatScreen(agent: agent));
      await frames(tester);
      expect(find.text('Waiting for the connection'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await frames(tester);
      expect(agent.offlinePrompts, isEmpty);
      expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, 'Fix the footer');
    });
  });
}

// Which files look like secrets (ReviewScreen leaves them unticked).
void secretNameTests() {
  test('secret-looking names', () {
    for (final yes in ['.env', 'app/.env.local', '.env.production', 'cert.pem', 'k/server.key', 'id_rsa', '.ssh/config', '.npmrc', 'credentials.json', 'service-account-prod.json', 'a.keystore', '.aws/credentials']) {
      expect(looksSecret(yes), true, reason: yes);
    }
    for (final no in ['.env.example', '.env.sample', 'lib/env.dart', 'id_rsa.pub', 'README.md', 'monkey.dart', 'keyboard.png', 'src/keys.dart', 'package.json']) {
      expect(looksSecret(no), false, reason: no);
    }
  });
}
