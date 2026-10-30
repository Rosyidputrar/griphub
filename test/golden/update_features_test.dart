// The update's features on the app side: pasting a picture into the composer, pictures a tool read shown on its card,
// a changed file's contents in Git, the live clock of a turn, and background jobs calling their chat back. With
// goldens in light and dark, English and Indonesian, and on a narrow phone with large text.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/clock.dart';
import 'package:griphub_agent/agent/drafts.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/agent/remote_profile.dart';
import 'package:griphub_agent/ui/attachment_viewer.dart';
import 'package:griphub_agent/ui/auto_backup.dart';
import 'package:griphub_agent/ui/chat_extras.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/ui/git_screen.dart';
import 'package:griphub_agent/ui/live_clock.dart';
import 'package:griphub_agent/ui/message_views.dart';
import 'package:griphub_agent/ui/server_guide.dart';

import 'harness.dart';

const _looks = [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)];

/// A 32×32 gradient picture.
final _png = base64Decode(
  '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',
);

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// A `read` of a picture, finished, with the picture in its result.
AssistantEntry _readOf(String path) {
  final e = AssistantEntry()..streaming = false;
  e.block(0, BlockKind.text).text = 'Saya lihat dulu screenshot-nya.';
  final b = e.block(1, BlockKind.toolCall)
    ..toolCallId = 'call-read'
    ..toolName = 'read'
    ..args = {'path': path};
  b.buffer.write(jsonEncode(b.args));
  return e;
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  group('paste a picture', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('paste-');
      Drafts.root = dir.path;
    });
    tearDown(() => dir.deleteSync(recursive: true));

    testWidgets('"Paste image" in the field\'s menu attaches the copied picture', (tester) async {
      final copied = File('${dir.path}/copied.png')..writeAsBytesSync(_png);
      final host = FakeHost();
      host.methods['clipboardHasImage'] = (_) => true;
      host.methods['clipboardImage'] = (_) => {'path': copied.path, 'name': 'pasted-image.png', 'mime': 'image/png'};
      await pumpLook(tester, const Look(), ChatScreen(agent: newAgent()));
      await frames(tester);
      final field = find.byType(TextField).last;
      await tester.tap(field);
      await frames(tester);
      await tester.longPress(field);
      await frames(tester);
      expect(find.text('Paste image'), findsOneWidget);
      await tester.tap(find.text('Paste image'));
      await frames(tester);
      expect(host.calls.where((c) => c.method == 'clipboardImage'), hasLength(1));
      final strip = tester.widget<AttachmentStrip>(find.byType(AttachmentStrip));
      expect(strip.items.single.name, 'pasted-image.png');
      expect(strip.items.single.isImage, isTrue);
    });

    testWidgets('no "Paste image" when the clipboard holds no picture', (tester) async {
      final host = FakeHost();
      host.methods['clipboardHasImage'] = (_) => false;
      await pumpLook(tester, const Look(), ChatScreen(agent: newAgent()));
      await frames(tester);
      final field = find.byType(TextField).last;
      await tester.enterText(field, 'halo');
      await tester.longPress(field);
      await frames(tester);
      expect(find.text('Paste image'), findsNothing);
    });

    testWidgets('a picture the keyboard pastes becomes an attachment, never text', (tester) async {
      FakeHost();
      await pumpLook(tester, const Look(), ChatScreen(agent: newAgent()));
      await frames(tester);
      final field = tester.widget<TextField>(find.byType(TextField).last);
      expect(field.contentInsertionConfiguration!.allowedMimeTypes, containsAll(['image/png', 'image/jpeg']));
      field.contentInsertionConfiguration!.onContentInserted(
        KeyboardInsertedContent(mimeType: 'image/png', uri: 'content://keyboard/1', data: _png),
      );
      await frames(tester);
      final strip = tester.widget<AttachmentStrip>(find.byType(AttachmentStrip));
      expect(strip.items.single.name, 'pasted-image.png');
      expect(File(strip.items.single.path).readAsBytesSync(), _png);
      expect(field.controller!.text, isEmpty);
    });

    test('a pasted picture is saved with the extension of its type', () {
      expect(pastedImageAttachment(_png, 'image/jpeg').name, 'pasted-image.jpg');
      expect(pastedImageAttachment(_png, 'image/webp').name, 'pasted-image.webp');
      final a = pastedImageAttachment(_png, 'image/png');
      expect(a.mime, 'image/png');
      expect(File(a.path).readAsBytesSync(), _png);
    });
  });

  group('pictures a tool read', () {
    test('the picture in a result is decoded once; text and broken blocks are left out', () {
      final images = contentImageData([
        {'type': 'text', 'text': 'Read image file [image/png]'},
        {'type': 'image', 'data': base64Encode(_png), 'mimeType': 'image/png'},
        {'type': 'image', 'data': '%%%not base64', 'mimeType': 'image/png'},
      ]);
      expect(images, hasLength(1));
      expect(images.single.bytes, _png);
      expect(contentImageData('plain text'), isEmpty);
    });

    for (final look in _looks) {
      testWidgets('golden: a thumbnail on the read card ${look.name}', (tester) async {
        FakeHost();
        final run = ToolRun('call-read')
          ..status = ToolStatus.done
          ..output = 'Read image file [image/png]'
          ..images = contentImageData([
            {'type': 'image', 'data': base64Encode(_png), 'mimeType': 'image/png'},
          ]);
        await tester.runAsync(() async {
          await pumpLook(
            tester,
            look,
            Scaffold(
              body: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  AssistantMessageView(_readOf('/w/site/screenshot.png'), tools: {'call-read': run}),
                ],
              ),
            ),
            height: 420,
          );
          // Image.memory decodes off the test clock.
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await frames(tester, 4);
        expect(find.byType(ToolImages), findsOneWidget);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('tool_read_image_${look.name}')));
      });
    }

    testWidgets('a tap opens the picture full screen', (tester) async {
      FakeHost();
      final run = ToolRun('call-read')
        ..status = ToolStatus.done
        ..images = contentImageData([
          {'type': 'image', 'data': base64Encode(_png), 'mimeType': 'image/png'},
        ]);
      await pumpLook(
        tester,
        const Look(),
        Scaffold(body: AssistantMessageView(_readOf('/w/shot.png'), tools: {'call-read': run})),
      );
      await tester.tap(find.descendant(of: find.byType(ToolImages), matching: find.byType(Image)));
      await frames(tester);
      expect(find.byType(ImageBytesViewerScreen), findsOneWidget);
      expect(find.descendant(of: find.byType(ImageBytesViewerScreen), matching: find.text('shot.png')), findsOneWidget);
    });
  });

  group('live clock', () {
    testWidgets('counts every second while running, and stops at the time it took', (tester) async {
      FakeHost();
      final start = goldenNow.subtract(const Duration(seconds: 42));
      Widget clock({Duration? took}) => Scaffold(
        body: Center(
          child: LiveClock(label: 'Working', startedAt: start, took: took, state: took == null ? ClockState.running : ClockState.done),
        ),
      );
      await pumpLook(tester, const Look(), clock());
      expect(find.text('Working'), findsOneWidget);
      expect(find.text(' · 42s'), findsOneWidget);
      await pumpLook(tester, const Look(), clock(took: const Duration(minutes: 1, seconds: 23)));
      expect(find.text(' · 1m 23s'), findsOneWidget);
    });

    for (final look in _looks) {
      testWidgets('golden: running, done, failed and a finished turn\'s footer ${look.name}', (tester) async {
        FakeHost();
        final done = AssistantEntry()
          ..streaming = false
          ..turnMs = 83000;
        done.block(0, BlockKind.text).text = 'Selesai: halaman sudah dibuat.';
        final footer = turnFooters([UserEntry('Buat halaman'), done], busy: false)[1];
        await pumpLook(
          tester,
          look,
          Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                LiveClock(
                  label: look.language == 'id' ? 'Bekerja' : 'Working',
                  startedAt: goldenNow.subtract(const Duration(seconds: 42)),
                  detail: '12k tokens',
                ),
                const SizedBox(height: 14),
                AssistantMessageView(done, tools: const {}, footer: footer),
                const SizedBox(height: 14),
                JobNoticeView(
                  JobEntry({'id': 'j1', 'label': 'npm run build', 'status': 'done', 'exitCode': 0, 'elapsedMs': 151000}),
                ),
                JobNoticeView(
                  JobEntry({'id': 'j2', 'label': 'npm test', 'status': 'failed', 'exitCode': 1, 'elapsedMs': 12000}),
                ),
              ],
            ),
          ),
          height: 460,
        );
        // Stop the shimmer at a fixed point.
        await tester.pump(const Duration(milliseconds: 400));
        expect(footer!.took, const Duration(seconds: 83));
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('live_clock_${look.name}')));
      });
    }

    for (final look in _looks) {
      testWidgets('golden: a stopped or failed turn\'s footer says so, not Done ${look.name}', (tester) async {
        FakeHost();
        // A turn the user stopped: its reply carries stopReason aborted and still has its duration.
        final stopped = AssistantEntry()
          ..applyMessage({
            'content': [
              {'type': 'text', 'text': 'Setengah jalan membuat halaman.'},
            ],
            'stopReason': 'aborted',
            'griphubTurnMs': 902,
          });
        // A turn that died on a model error.
        final failed = AssistantEntry()
          ..applyMessage({
            'content': [
              {'type': 'text', 'text': 'Mencoba memanggil model.'},
            ],
            'stopReason': 'error',
            'errorMessage': 'HTTP 500',
            'griphubTurnMs': 14174,
          });
        final entries = [UserEntry('Buat halaman'), stopped, UserEntry('Coba lagi'), failed];
        final footers = turnFooters(entries, busy: false);
        await pumpLook(
          tester,
          look,
          Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                AssistantMessageView(stopped, tools: const {}, footer: footers[1]),
                const SizedBox(height: 14),
                AssistantMessageView(failed, tools: const {}, footer: footers[3]),
              ],
            ),
          ),
          height: 420,
        );
        expect(footers[1]!.outcome, TurnOutcome.stopped);
        expect(footers[3]!.outcome, TurnOutcome.failed);
        expect(find.text(look.language == 'id' ? 'Berhenti' : 'Stopped'), findsWidgets);
        expect(find.text(look.language == 'id' ? 'Gagal' : 'Failed'), findsWidgets);
        expect(find.text(look.language == 'id' ? 'Selesai' : 'Done'), findsNothing);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('turn_footer_outcome_${look.name}')));
      });
    }

    testWidgets('the chat\'s clock counts from the host\'s, and a finished turn keeps its time', (tester) async {
      final host = FakeHost();
      final agent = newAgent();
      await tester.pump();
      host.emit({
        'type': 'state',
        'state': {'sessionId': 's', 'isStreaming': true, 'turnElapsedMs': 30000},
      });
      await frames(tester, 2);
      // The host's 30 s so far, counted on from this phone's clock.
      expect(clock().difference(agent.turnStartedAt!).inSeconds, inInclusiveRange(29, 31));
      expect(agent.busy, isTrue);
      agent.addHistoryMessage({
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Beres.'},
        ],
      });
      host.emit({'type': 'agent_done', 'turnMs': 31000, 'retrying': false});
      await frames(tester, 2);
      expect((agent.entries.last as AssistantEntry).turnMs, 31000);
      expect(agent.turnStartedAt, isNull);
    });
  });

  group('background jobs', () {
    testWidgets('a job\'s records and its result in the chat: a notice, not a bubble, that starts a turn', (tester) async {
      final host = FakeHost();
      final agent = newAgent();
      await tester.pump();
      host.emit({
        'type': 'job',
        'job': {'id': 'j1', 'sessionFile': 's', 'toolCallId': 'call-1', 'command': 'npm run build', 'label': 'Build', 'status': 'running', 'elapsedMs': 5000, 'limitMinutes': 60},
      });
      await frames(tester, 2);
      expect(agent.jobStore.forToolCall('call-1')!.running, isTrue);
      expect(agent.features.jobsRunning, 1, reason: 'the phone keeps the host alive for it');
      host.emit({
        'type': 'job',
        'job': {'id': 'j1', 'sessionFile': 's', 'toolCallId': 'call-1', 'command': 'npm run build', 'label': 'Build', 'status': 'done', 'exitCode': 0, 'elapsedMs': 151000, 'limitMinutes': 60, 'tail': 'built'},
      });
      await frames(tester, 2);
      expect(agent.jobStore['j1']!.took, const Duration(seconds: 151));
      expect(agent.features.jobsRunning, 0);

      agent.addHistoryMessage({'role': 'user', 'content': 'Bangun di latar'});
      agent.addHistoryMessage({
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Saya jalankan build di latar.'},
        ],
      });
      agent.addHistoryMessage({
        'role': 'custom',
        'customType': 'griphub_job',
        'content': '[Background job j1] ...',
        'details': {
          'job': {'id': 'j1', 'label': 'Build', 'status': 'done', 'exitCode': 0, 'elapsedMs': 151000, 'tail': 'built'},
        },
      });
      agent.addHistoryMessage({
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Build berhasil.'},
        ],
      });
      expect(agent.entries.whereType<UserEntry>(), hasLength(1), reason: 'the callback is not a user message');
      final job = agent.entries.whereType<JobEntry>().single;
      expect(job.label, 'Build');
      // Two turns: one footer each.
      expect(turnFooters(agent.entries, busy: false).keys, [1, 3]);
    });

    for (final look in _looks) {
      testWidgets('golden: a running job on its card, with Stop ${look.name}', (tester) async {
        final host = FakeHost();
        host.answers['job_stop'] = (cmd) => {'id': cmd['jobId'], 'status': 'running', 'elapsedMs': 95000};
        final agent = newAgent();
        // The job's start is counted from the app's clock, pinned for goldens before the record arrives.
        pinClock();
        await tester.pump();
        host.emit({
          'type': 'job',
          'job': {'id': 'j1', 'sessionFile': 's', 'toolCallId': 'call-job', 'command': 'npm run build', 'label': 'Build the app', 'status': 'running', 'elapsedMs': 95000, 'limitMinutes': 60},
        });
        await frames(tester, 2);
        final e = AssistantEntry()..streaming = false;
        final b = e.block(0, BlockKind.toolCall)
          ..toolCallId = 'call-job'
          ..toolName = 'background_job'
          ..args = {'command': 'npm run build', 'label': 'Build the app'};
        b.buffer.write(jsonEncode(b.args));
        final run = ToolRun('call-job')..status = ToolStatus.done;
        await pumpLook(
          tester,
          look,
          Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [AssistantMessageView(e, tools: {'call-job': run}, agent: agent)],
            ),
          ),
          height: 220,
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(JobClock), findsOneWidget);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('job_card_running_${look.name}')));

        await tester.tap(find.text(look.language == 'id' ? 'Berhenti' : 'Stop'));
        await frames(tester, 2);
        expect(host.sent('job_stop').single['jobId'], 'j1');
      });
    }
  });

  group('git: a changed file\'s contents', () {
    late Directory repo;
    setUp(() => repo = Directory.systemTemp.createTempSync('git-file-'));
    tearDown(() => repo.deleteSync(recursive: true));

    Future<FakeHost> pumpGit(WidgetTester tester, Look look, List<Map<String, dynamic>> files) async {
      final host = FakeHost();
      host.answers['git_status'] = (_) => {'repo': true, 'root': repo.path, 'branch': 'main', 'files': files};
      host.answers['git_log'] = (_) => const [];
      host.answers['git_diff'] = (cmd) => {
        'patch': cmd['file'] == 'site/app.js'
            ? 'diff --git a/site/app.js b/site/app.js\n--- a/site/app.js\n+++ b/site/app.js\n@@ -1 +1 @@\n-old();\n+fresh();\n'
            : '',
      };
      final agent = newAgent()..cwd = '${repo.path}/site';
      await tester.runAsync(() async {
        await pumpLook(tester, look, GitScreen(agent: agent), height: 900);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await frames(tester);
      return host;
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    testWidgets('a text file opens on its changes, and "File" shows all of it, read from the repository top', (tester) async {
      File('${repo.path}/site/app.js')
        ..createSync(recursive: true)
        ..writeAsStringSync('fresh();\nconsole.log("line 2");\n');
      await pumpGit(tester, const Look(), [
        {'path': 'site/app.js', 'code': ' M', 'staged': false, 'unstaged': true, 'untracked': false},
      ]);
      await tester.tap(find.text('app.js'));
      await settle(tester);
      expect(find.text('+fresh();'), findsNothing, reason: 'diff rows draw the sign apart');
      expect(find.textContaining('fresh();'), findsWidgets);
      await tester.tap(find.text('File'));
      await settle(tester);
      expect(find.textContaining('console.log("line 2");', findRichText: true), findsWidgets);
    });

    for (final look in _looks) {
      testWidgets('golden: a changed picture opens as a picture ${look.name}', (tester) async {
        File('${repo.path}/site/logo.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(_png);
        await pumpGit(tester, look, [
          {'path': 'site/logo.png', 'code': ' M', 'staged': false, 'unstaged': true, 'untracked': false},
        ]);
        // Decoded into the image cache first, off the test clock: the sheet then shows it at once.
        await tester.runAsync(
          () => precacheImage(FileImage(File('${repo.path}/site/logo.png')), tester.element(find.byType(GitScreen))),
        );
        await tester.tap(find.text('logo.png'));
        await settle(tester);
        expect(find.text(look.language == 'id' ? 'File biner berubah' : 'Binary file changed'), findsNothing);
        expect(find.byType(AgentImage), findsOneWidget);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(BottomSheet), matchesGoldenFile(golden('git_file_picture_${look.name}')));
      });
    }

    testWidgets('a binary file that is not a picture says what it is', (tester) async {
      File('${repo.path}/site/data.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync([0, 1, 2, 3, 0, 255]);
      await pumpGit(tester, const Look(), [
        {'path': 'site/data.bin', 'code': '??', 'staged': false, 'unstaged': false, 'untracked': true},
      ]);
      await tester.tap(find.text('data.bin'));
      await settle(tester);
      expect(find.textContaining('Binary file (6 B), not shown as text.'), findsOneWidget);
    });
  });

  group('automatic server backup', () {
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('autobackup-'));
    tearDown(() => home.deleteSync(recursive: true));

    /// An agent with a server set up: in use or not, with a backup key and one fetched backup.
    Future<dynamic> agentWith({required bool active}) async {
      FakeHost();
      final agent = newAgent();
      final store = RemoteProfileStore(File('${home.path}/.griphub/remote.json'))
        ..save(
          RemoteProfile(host: 'vps.example.com', port: 22, user: 'griphub', hostKey: 'ssh-ed25519 AAAA', active: active, backupKey: 'ab' * 32),
        );
      agent.remote.configure(setup: RemoteSetup(home: home.path), store: store);
      final at = goldenNow.subtract(const Duration(minutes: 40)).millisecondsSinceEpoch;
      File('${agent.remote.backupsDir.path}/auto-$at.ghb')
        ..createSync(recursive: true)
        ..writeAsBytesSync([71, 72, 66, 49]);
      return (agent, at);
    }

    for (final look in _looks) {
      testWidgets('golden: on, with the server\'s and the phone\'s newest ${look.name}', (tester) async {
        final (agent, at) = await agentWith(active: true);
        pinClock();
        await pumpLook(tester, look, Scaffold(body: ListView(padding: const EdgeInsets.all(16), children: [ServerBackupCard(agent: agent)])), height: 520);
        await frames(tester, 2);
        agent.remote.autoBackup = {
          'enabled': true,
          'backups': [
            {'name': 'auto-$at.ghb', 'path': '/srv/auto-$at.ghb', 'at': at, 'size': 48 * 1024 * 1024},
          ],
        };
        agent.remote.notifyListeners();
        // The switch slides from off (nothing known yet) to on.
        await frames(tester, 10);
        expect(find.byType(Switch), findsOneWidget);
        expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('auto_backup_on_${look.name}')));
      });
    }

    testWidgets('back on the phone: no switch, and "Restore on this phone" offers the newest copy', (tester) async {
      final (agent, _) = await agentWith(active: false);
      await pumpLook(tester, const Look(), Scaffold(body: ListView(padding: const EdgeInsets.all(16), children: [ServerBackupCard(agent: agent)])), height: 520);
      await frames(tester, 2);
      expect(find.byType(Switch), findsNothing);
      await tester.tap(find.text('Restore on this phone'));
      await frames(tester);
      expect(find.text("Restore the server's data on this phone?"), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await frames(tester);
      // Switching back offers it once.
      expect(agent.remote.takeRestoreOffer(), isFalse, reason: 'only right after a switch');
    });
  });

  group('server guide', () {
    for (final look in _looks) {
      testWidgets('golden: the guide, and opened on the box ${look.name}', (tester) async {
        FakeHost();
        await pumpLook(tester, look, const ServerGuideScreen(), height: 1400);
        await frames(tester, 2);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('server_guide_${look.name}')));
        // Opened afresh, as the box screen opens it (its own key: not the state of the page above).
        await pumpLook(tester, look, const ServerGuideScreen(key: ValueKey('box'), section: 'box'), height: 900);
        await frames(tester, 3);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('server_guide_box_${look.name}')));
      });
    }

    testWidgets('every trouble on the server screen\'s list is in the guide too', (tester) async {
      FakeHost();
      await pumpLook(tester, const Look(), const ServerGuideScreen(), height: 6000);
      await frames(tester, 2);
      for (final (title, _) in serverTroubleshooting()) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
    });
  });
}
