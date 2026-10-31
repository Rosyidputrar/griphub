import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_backend.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/ui/backup_screen.dart';
import 'package:griphub_agent/ui/kit.dart';
import 'package:griphub_agent/ui/theme.dart';

import 'support/fake_backend.dart';
import 'support/remote_rig.dart';

/// Backup and restore with the agent on a server (server_agent.md, phase 6): the backup is made there and brought to the
/// phone, and a backup from the phone is sent to the server before it is restored. Real host, real ssh, real files.
/// Adapted from CoderRa's test/backup_screen_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> platform;

  setUp(() {
    platform = [];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(PlatformBackend.method, (call) async {
      platform.add(call);
      return call.method == 'saveToDownloads' ? '/storage/emulated/0/Download/GripHub/saved.zip' : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(PlatformBackend.method, null));
  });

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> until(WidgetTester tester, bool Function() ok, String what) async {
    for (var i = 0; i < 100; i++) {
      if (ok()) return;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    fail(
      'timed out waiting for $what; on screen: ${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).join(' | ')}',
    );
  }

  bool shown(String text) => find.textContaining(text).evaluate().isNotEmpty;

  Future<RemoteRig> rig(WidgetTester tester) async {
    final r = (await tester.runAsync(RemoteRig.start))!;
    addTearDown(() => tester.runAsync(r.dispose));
    r.agent.info = {'workspace': r.workspace};
    return r;
  }

  Future<void> open(WidgetTester tester, AgentController agent, {Future<String?> Function()? pick}) async {
    tall(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: BackupScreen(agent: agent, pickFile: pick),
      ),
    );
    await tester.pump();
  }

  /// A zip made on the phone, as a backup from another device would be.
  String phoneZip(Directory dir, Map<String, String> members) {
    final path = '${dir.path}/phone-backup.zip';
    final r = Process.runSync('python3', [
      '-c',
      'import sys, zipfile, json\nz = zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED)\n'
          'for n, d in json.loads(sys.argv[2]).items():\n    z.writestr(zipfile.ZipInfo(n), d)\nz.close()',
      path,
      '{${members.entries.map((e) => '"${e.key}": "${e.value}"').join(',')}}',
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    return path;
  }

  String field(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!.text;

  final skip = RemoteRig.skip;

  testWidgets('a backup made on the server comes to the phone, with progress, as a zip that opens', (tester) async {
    final r = await rig(tester);
    Directory('${r.workspace}/proj').createSync(recursive: true);
    File('${r.workspace}/proj/a.txt').writeAsStringSync('alpha' * 1000);
    await open(tester, r.agent);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Include workspace files'));
    await tester.pump();
    await tester.tap(find.text('Create backup'));
    await until(tester, () => find.text('Download to this phone').evaluate().isNotEmpty, 'the backup');
    expect(field(tester), startsWith('${r.workspace}/backups/'), reason: 'made on the server');
    expect(find.textContaining('Backup made on the server · '), findsOneWidget, reason: 'says where the zip is');

    await tester.tap(find.text('Download to this phone'));
    await until(tester, () => platform.any((c) => c.method == 'saveToDownloads'), 'the download to finish');
    await until(tester, () => !shown('Downloading the backup'), 'the progress dialog to go');

    final local = (platform.firstWhere((c) => c.method == 'saveToDownloads').arguments as Map)['path'] as String;
    expect(local, startsWith('${r.app.path}/.cache/'), reason: 'a file on the phone');
    final test = Process.runSync('unzip', ['-t', local]);
    expect(test.exitCode, 0, reason: '${test.stdout}');
    expect('${test.stdout}', contains('proj/a.txt'));
    expect(find.textContaining('Saved to /storage/emulated/0/Download/GripHub/saved.zip'), findsOneWidget);
  }, skip: skip != null);

  testWidgets('a backup from the phone is sent to the server first, restored there, and the copy is cleaned up', (
    tester,
  ) async {
    final r = await rig(tester);
    final zip = phoneZip(r.app, {'workspace/proj/restored.txt': 'from the phone', 'agent/AGENTS.md': 'restored notes'});
    await open(tester, r.agent, pick: () async => zip);

    await tester.tap(find.text('Choose file'));
    await until(
      tester,
      () => field(tester).endsWith('/backups/.restore-phone-backup.zip'),
      'the zip to reach the server',
    );
    await tester.pump(const Duration(milliseconds: 500)); // the progress dialog finishes closing
    final onServer = field(tester);
    expect(File(onServer).existsSync(), isTrue);
    expect(onServer, startsWith(r.workspace));

    await tester.tap(find.widgetWithText(PrimaryButton, 'Restore'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('project memory on the server are overwritten'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Restore'));
    await until(tester, () => shown('Restored 2 files'), 'the restore');
    expect(File('${r.workspace}/proj/restored.txt').readAsStringSync(), 'from the phone');
    await until(tester, () => !File(onServer).existsSync(), 'the uploaded copy to be removed');
  }, skip: skip != null);

  testWidgets('entries that may not be restored are skipped and counted', (tester) async {
    final r = await rig(tester);
    final zip = phoneZip(r.app, {'workspace/ok.txt': 'fine', 'workspace/../escape.txt': 'no'});
    await open(tester, r.agent, pick: () async => zip);
    await tester.tap(find.text('Choose file'));
    await until(tester, () => field(tester).endsWith('/backups/.restore-phone-backup.zip'), 'the upload');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.widgetWithText(PrimaryButton, 'Restore'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(TextButton, 'Restore'));
    await until(tester, () => shown('Restored 1 files'), 'the restore');
    expect(find.textContaining('1 blocked entries skipped'), findsOneWidget);
    expect(File('${r.workspace}/ok.txt').readAsStringSync(), 'fine');
    expect(File('${r.server.path}/escape.txt').existsSync(), isFalse);
    expect(File('${Directory(r.workspace).parent.path}/escape.txt').existsSync(), isFalse);
  }, skip: skip != null);

  testWidgets('on this phone there is no trip to make: no download button, and a chosen zip is used where it is', (
    tester,
  ) async {
    final backend = FakeBackend()
      ..onCommand = (c) => switch (c['type']) {
        'backup_create' => {'path': '/phone/ws/backups/b.zip', 'files': 3},
        _ => null,
      };
    final agent = AgentController(AgentClient(backend: backend));
    backend.running = true;
    await open(tester, agent, pick: () async => '/storage/emulated/0/Download/old.zip');
    await tester.tap(find.text('Create backup'));
    await tester.pump();
    await tester.pump();
    expect(find.text('3 files'), findsOneWidget);
    expect(find.text('Download to this phone'), findsNothing);

    await tester.tap(find.text('Choose file'));
    await tester.pump();
    expect(field(tester), '/storage/emulated/0/Download/old.zip');
    expect(backend.sent.where((c) => '${c['type']}'.startsWith('fs_')), isEmpty);
  });

  testWidgets('automatic backups on this phone: turned on with a recovery code shown once, and the first backup made', (
    tester,
  ) async {
    final stored = <String, Object?>{};
    var backups = <Map<String, Object?>>[];
    final backend = FakeBackend()
      ..onCommand = (c) => switch (c['type']) {
        'auto_backup_status' => {'enabled': stored['key'] != null, 'backups': backups, 'dir': '/download/GripHub/auto'},
        'auto_backup_configure' => () {
          stored['key'] = c['key'];
          if (c['key'] == null) backups = [];
          return {'enabled': c['key'] != null, 'backups': backups, 'dir': '/download/GripHub/auto'};
        }(),
        'auto_backup_now' => () {
          backups = [
            {'name': 'auto-1.ghb', 'path': '/download/GripHub/auto/auto-1.ghb', 'at': 1700000000000, 'size': 4096},
          ];
          return {'made': true, 'enabled': true, 'backups': backups, 'dir': '/download/GripHub/auto'};
        }(),
        'auto_backup_key' => {'key': stored['key']},
        _ => null,
      };
    final agent = AgentController(AgentClient(backend: backend));
    backend.running = true;
    await open(tester, agent);
    await tester.pump();

    // The phone card is there (the server one is not: no server is set up).
    expect(find.text('Automatic backup on this phone'), findsWidgets);
    expect(find.text('Automatic server backup'), findsNothing);

    // On: a key goes to the host, the recovery code is shown and must be acknowledged, then the first backup is made.
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    await tester.pump();
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('Recovery code')), findsOneWidget);
    final saved = stored['key']! as String;
    expect(saved.length, 64);
    expect(find.text(saved), findsOneWidget, reason: 'the code on screen is the key the host got');
    await tester.tap(find.text('I wrote it down'));
    await tester.pump();
    await tester.pump();
    expect(backend.sent.any((c) => c['type'] == 'auto_backup_now'), isTrue, reason: 'a switch that waits an hour misleads');
    await tester.pump();
    expect(find.textContaining('auto-1.ghb', findRichText: true), findsNothing); // the row shows time and size, not the name
    expect(find.textContaining('Newest'), findsOneWidget);

    // The code can be seen again on this phone (and only here; a server refuses, host-side test).
    await tester.tap(find.text('Recovery code'));
    await tester.pump();
    await tester.pump();
    expect(find.text(saved), findsOneWidget);
    await tester.tap(find.text('I wrote it down'));
    await tester.pump();

    // Off asks first, then deletes: the key is cleared on the host.
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    await tester.tap(find.text('Turn off'));
    await tester.pump();
    await tester.pump();
    expect(stored['key'], isNull);
  });

  testWidgets('restoring a phone backup (.ghb) asks for the recovery code and says keys are not in it', (tester) async {
    String? restoredWith;
    final backend = FakeBackend()
      ..onCommand = (c) => switch (c['type']) {
        'auto_backup_status' => {'enabled': false, 'backups': const [], 'dir': '/download/GripHub/auto'},
        'backup_restore_server' => () {
          restoredWith = c['key'] as String?;
          return {'restored': 7, 'skipped': 0, 'keptSshKey': false, 'createdAt': 1700000000000};
        }(),
        _ => null,
      };
    final agent = AgentController(AgentClient(backend: backend));
    backend.running = true;
    await open(tester, agent, pick: () async => '/storage/emulated/0/Download/GripHub/auto/auto-9.ghb');
    await tester.tap(find.text('Choose file'));
    await tester.pump();
    await tester.tap(find.text('Restore'));
    await tester.pump();
    // Not the zip flow: the code is asked for, not the overwrite warning.
    expect(find.text('Restore backup?'), findsNothing);
    expect(find.text('Recovery code'), findsWidgets);
    await tester.enterText(find.byType(TextField).last, 'ab' * 32);
    await tester.tap(find.text('Restore').last);
    await tester.pump();
    await until(tester, () => restoredWith != null, 'the restore to reach the host');
    expect(restoredWith, 'ab' * 32);
    await until(tester, () => find.textContaining('7').evaluate().isNotEmpty, 'the outcome on screen');
    expect(find.textContaining('enter them again'), findsOneWidget, reason: 'honest about the keys');
  });
}
