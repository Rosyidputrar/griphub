// Goldens for files with the agent on a server (server_agent.md, phase 5): the transfer dialog while attachments are
// sent, and the folder picker on a server (no phone storage, the breadcrumb starts at the server). Light/dark,
// English/Indonesian, and a narrow phone with large text, where nothing may overflow.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/agent_fs.dart';
import 'package:griphub_agent/ui/folder_picker.dart';
import 'package:griphub_agent/ui/i18n.dart';
import 'package:griphub_agent/ui/transfer_dialog.dart';

import '../support/fake_backend.dart';
import 'harness.dart';

/// The files of a temporary folder, presented as a server's (the screens then behave as with a server agent).
class _ServerFs extends LocalFs {
  const _ServerFs();

  @override
  bool get isLocal => false;
}

const _looks = [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)];

void main() {
  setUpAll(loadAppFonts);

  for (final look in _looks) {
    testWidgets('transfer dialog, sending files (${look.name})', (tester) async {
      final done = Completer<void>();
      await pumpLook(
        tester,
        look,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => runTransfer<void>(
                  context,
                  title: tr('Sending files'),
                  task: (h) {
                    h.label = 'design-mockup-final-v3.pdf · 2 ${tr('of')} 3';
                    h.onProgress(3 * 1024 * 1024 + 300 * 1024, 8 * 1024 * 1024);
                    return done.future;
                  },
                ),
                child: const Text('send'),
              ),
            ),
          ),
        ),
        height: 700,
      );
      await tester.tap(find.text('send'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      collectLayoutErrors(tester, 'transfer_sending_${look.name}');
      await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('transfer_sending_${look.name}')));
      expect(layoutErrors.where((e) => e.contains('transfer_sending_${look.name}')), isEmpty);
      done.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('folder picker on a server (${look.name})', (tester) async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(const MethodChannel('griphub/agent'), (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('griphub/agent'), null));
      final ws = Directory.systemTemp.createTempSync('gh-golden-ws-');
      addTearDown(() => ws.deleteSync(recursive: true));
      Directory('${ws.path}/landing-page/.git').createSync(recursive: true);
      Directory('${ws.path}/api-server/.git').createSync(recursive: true);
      Directory('${ws.path}/notes').createSync();
      final agent = AgentController(AgentClient(backend: FakeBackend()))
        ..info = {'workspace': ws.path}
        ..fs = const _ServerFs();

      await pumpLook(tester, look, FolderPicker(agent: agent), height: 700);
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(find.text('landing-page'), findsOneWidget);
      collectLayoutErrors(tester, 'folder_picker_server_${look.name}');
      await expectLater(find.byType(FolderPicker), matchesGoldenFile(golden('folder_picker_server_${look.name}')));
      expect(layoutErrors.where((e) => e.contains('folder_picker_server_${look.name}')), isEmpty);
    });
  }
}
