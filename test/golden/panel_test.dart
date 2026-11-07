// The floating panel (Fitur 4) on the Dart side: the panel replaces what is on screen while the panel window shows the
// engine and leaves the app's pages as they were; one-tap actions on a selection; the answer back into the other app
// when it allows that; nothing privileged decided in the panel; the panel's own controls; the permission screen;
// scanning a document; and "Tanya GripHub" without the permission landing in the app.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/drafts.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/agent/panel.dart';
import 'package:griphub_agent/ui/chat_extras.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/ui/home_shell.dart';
import 'package:griphub_agent/ui/panel_screen.dart';
import 'package:griphub_agent/ui/panel_settings_screen.dart';

import 'harness.dart';

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _kimi = {'provider': 'griphub', 'id': 'kimi-k3', 'name': 'Kimi K3', 'input': ['text']};

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    layoutErrors.clear();
    Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
  });
  tearDown(PanelState.instance.reset);

  /// The engine as the panel window shows it: [selection] from another app's text selection.
  Future<(FakeHost, AgentController, List<String>)> panel(
    WidgetTester tester, {
    String? selection,
    bool writable = false,
    Look look = const Look(),
    void Function(AgentController agent)? before,
  }) async {
    final host = FakeHost();
    final platform = <String>[];
    for (final m in ['panelOpenFull', 'panelMinimize', 'panelClose', 'panelReplaceText']) {
      host.methods[m] = (call) {
        platform.add(call.arguments == null ? m : '$m:${call.arguments}');
        return null;
      };
    }
    host.methods['takeLaunch'] = (_) => null;
    host.answers['new_session'] = (_) => {'sessionFile': 'p.jsonl', 'sessionId': 'p', 'cwd': '/w/.chats', 'chatMode': 'chat'};
    final agent = newAgent()
      ..status = BootStatus.ready
      ..sessionId = 'p'
      ..isChat = true
      ..model = ModelInfo(Map.of(_kimi));
    before?.call(agent);
    PanelState.instance.apply({'surface': 'panel', 'selection': selection, 'writable': writable});
    await pumpLook(
      tester,
      look,
      PanelGate(agent: agent, child: const Scaffold(body: Center(child: Text('the app underneath')))),
      height: 520,
    );
    await frames(tester);
    return (host, agent, platform);
  }

  testWidgets('the panel shows instead of the app; back to the app, its page is as it was', (tester) async {
    await panel(tester);
    expect(find.byType(PanelScreen), findsOneWidget);
    expect(find.text('the app underneath'), findsNothing);
    expect(find.byType(ChatScreen), findsOneWidget);
    PanelState.instance.apply({'surface': 'app'});
    await frames(tester);
    expect(find.byType(PanelScreen), findsNothing);
    expect(find.text('the app underneath'), findsOneWidget);
  });

  testWidgets('a selection: quoted, with Explain / Summarize / Translate / Reply one tap away', (tester) async {
    final (host, _, _) = await panel(tester, selection: 'Fotosintesis adalah proses tumbuhan membuat makanan.');
    expect(find.text('Fotosintesis adalah proses tumbuhan membuat makanan.'), findsOneWidget);
    await tester.tap(find.text('Explain'));
    await frames(tester);
    final prompt = host.sent('prompt').single['text'] as String;
    expect(prompt, startsWith('Explain this simply:'));
    expect(prompt, contains('> Fotosintesis adalah proses tumbuhan membuat makanan.'));
  });

  testWidgets('the answer can replace the selection when the other app allows it, and only then', (tester) async {
    void answered(AgentController agent) {
      agent.addHistoryMessage({'role': 'user', 'content': 'Translate'});
      agent.addHistoryMessage({
        'role': 'assistant',
        'model': 'kimi-k3',
        'stopReason': 'stop',
        'content': [
          {'type': 'text', 'text': 'Photosynthesis is how plants make food.'},
        ],
      });
    }

    final (_, _, platform) = await panel(tester, selection: 'Fotosintesis', writable: true, before: answered);
    await tester.tap(find.text('Replace the original text'));
    await frames(tester);
    expect(platform, ['panelReplaceText:Photosynthesis is how plants make food.']);
  });

  testWidgets('a read-only selection offers no replacement', (tester) async {
    await panel(tester, selection: 'Fotosintesis', before: (agent) {
      agent.addHistoryMessage({'role': 'user', 'content': 'x'});
      agent.addHistoryMessage({
        'role': 'assistant',
        'model': 'kimi-k3',
        'stopReason': 'stop',
        'content': [
          {'type': 'text', 'text': 'y'},
        ],
      });
    });
    expect(find.text('Replace the original text'), findsNothing);
  });

  testWidgets('the panel\'s controls: open in the app, fold into the bubble, close', (tester) async {
    final (_, _, platform) = await panel(tester);
    await tester.tap(find.byTooltip('Open in the app'));
    await tester.tap(find.byTooltip('Fold into the bubble'));
    await tester.tap(find.byTooltip('Close the panel'));
    await frames(tester);
    expect(platform, ['panelOpenFull', 'panelMinimize', 'panelClose']);
  });

  testWidgets('nothing privileged is decided in the panel: approvals and coding chats go to the app', (tester) async {
    final (host, agent, platform) = await panel(tester);
    host.emit({'type': 'approval', 'approvalId': 'a1', 'toolName': 'bash', 'summary': 'rm -rf build', 'reason': 'deletes files'});
    await frames(tester);
    expect(find.byType(ApprovalCards), findsNothing);
    expect(find.text('rm -rf build'), findsNothing);
    expect(find.text('1 waiting for your approval. Continue in the app'), findsOneWidget);
    await tester.tap(find.byType(PanelHandoff));
    await frames(tester);
    expect(platform, contains('panelOpenFull'));
    agent.isChat = false;
    host.emit({'type': 'approval_dismiss', 'approvalId': 'a1'});
    await frames(tester);
    expect(find.text('This chat uses project tools. Continue in the app'), findsOneWidget);
  });

  testWidgets('opened for a selection, the panel starts a plain chat', (tester) async {
    final host = FakeHost();
    host.methods['takeLaunch'] = (_) => {'action': 'panel_selection', 'text': 'halo', 'writable': false};
    host.answers['new_session'] = (_) => {'sessionFile': 'p.jsonl', 'sessionId': 'p', 'cwd': '/w/.chats', 'chatMode': 'chat'};
    final agent = newAgent()..status = BootStatus.ready;
    PanelState.instance.apply({'surface': 'panel', 'selection': 'halo'});
    await pumpLook(tester, const Look(), PanelGate(agent: agent, child: const SizedBox()), height: 520);
    await frames(tester, 12);
    expect(host.sent('new_session').single['chatMode'], 'chat');
  });

  for (final look in const [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)]) {
    testWidgets('golden: panel with a selection ${look.name}', (tester) async {
      await panel(tester, selection: 'The mitochondria is the powerhouse of the cell, producing ATP through respiration.', look: look);
      expect(layoutErrors, isEmpty);
      await loadImages(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('panel_selection_${look.name}')));
    });
  }

  group('the permission screen', () {
    Future<(FakeHost, List<String>)> pumpSettings(WidgetTester tester, {required bool allowed, Look look = const Look()}) async {
      final host = FakeHost();
      final calls = <String>[];
      host.methods['overlayPermission'] = (_) => allowed;
      host.methods['requestOverlayPermission'] = (_) {
        calls.add('request');
        return null;
      };
      host.methods['panelOpen'] = (_) {
        calls.add('open');
        return true;
      };
      await pumpLook(tester, look, PanelSettingsScreen(agent: newAgent()), height: 1100);
      await frames(tester);
      return (host, calls);
    }

    testWidgets('not allowed: says what it is for, and goes to the system setting', (tester) async {
      final (_, calls) = await pumpSettings(tester, allowed: false);
      expect(find.textContaining('Display over other apps'), findsOneWidget);
      await tester.tap(find.text('Open system settings'));
      await frames(tester);
      expect(calls, ['request']);
    });

    testWidgets('allowed: the panel can be tried at once', (tester) async {
      final (_, calls) = await pumpSettings(tester, allowed: true);
      await tester.tap(find.text('Try the panel now'));
      await frames(tester);
      expect(calls, ['open']);
    });

    for (final look in const [Look(), Look(dark: true, language: 'id')]) {
      testWidgets('golden: permission screen ${look.name}', (tester) async {
        await pumpSettings(tester, allowed: false, look: look);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('panel_permission_${look.name}')));
      });
    }
  });

  // A plain test: the photo is read from disk, which the fake clock of a widget test never lets finish.
  test('scanning a document sends the photo to be read, and nothing else', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final host = FakeHost();
    host.answers['scan_document'] = (cmd) => {'text': 'TOTAL 22.800', 'model': 'gemini-3.8-flash', 'name': 'Gemini 3.8 Flash', 'credits': 0.004};
    final agent = newAgent();
    final photo = File('${Directory.systemTemp.createTempSync('scan-').path}/doc.jpg')..writeAsBytesSync([1, 2, 3]);
    final r = await agent.scanDocument(photo);
    expect(r?.text, 'TOTAL 22.800');
    final image = host.sent('scan_document').single['image'] as Map;
    expect(image['mimeType'], 'image/jpeg');
    expect(base64Decode(image['data'] as String), [1, 2, 3]);
  });

  testWidgets('the attach menu offers "Scan a document" where it can', (tester) async {
    FakeHost();
    await pumpLook(
      tester,
      const Look(),
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(onPressed: () => pickAttachments(context, onScan: (_) async {}), child: const Text('open')),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await frames(tester);
    expect(find.text('Scan a document'), findsOneWidget);
  });

  testWidgets('"Tanya GripHub" without the permission: the selection lands in a new chat in the app', (tester) async {
    final host = FakeHost();
    host.methods['takeLaunch'] = (_) => {'action': 'selection', 'text': 'Apa arti kata ini?'};
    host.answers['new_session'] = (_) => {'sessionFile': 'n.jsonl', 'sessionId': 'n', 'cwd': '/w/.chats', 'chatMode': 'chat'};
    final agent = newAgent()..info = {'workspace': '/w'};
    await pumpLook(tester, const Look(), HomeShell(agent: agent), height: 900);
    await frames(tester, 16);
    expect(host.sent('new_session').single['chatMode'], 'chat');
    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(field.controller!.text, '> Apa arti kata ini?\n\n');
    expect(find.text('To ask from any app without opening this one, turn on the floating panel.'), findsOneWidget);
  });

  group('the home-screen widgets\' taps', () {
    Future<FakeHost> shell(WidgetTester tester, Map<String, dynamic> launch) async {
      final host = FakeHost();
      host.methods['takeLaunch'] = (_) => launch;
      host.answers['new_session'] = (_) => {'sessionFile': 'n.jsonl', 'sessionId': 'n', 'cwd': '/w/.chats', 'chatMode': 'chat'};
      host.answers['providers'] = (_) => const [];
      host.answers['models'] = (_) => [_kimi];
      final agent = newAgent()..info = {'workspace': '/w'};
      await pumpLook(tester, const Look(), HomeShell(agent: agent), height: 900);
      await frames(tester, 20);
      return host;
    }

    testWidgets('Tanya Cepat without the panel: a plain chat in the app', (tester) async {
      final host = await shell(tester, {'action': 'new_plain_chat'});
      expect(host.sent('new_session').single['chatMode'], 'chat');
      expect(find.byType(ChatScreen), findsOneWidget);
    });

    testWidgets('the model mark: the app at the model picker', (tester) async {
      await shell(tester, {'action': 'pick_model'});
      expect(find.text('Search models'), findsOneWidget);
    });

    testWidgets('the microphone: the panel, listening', (tester) async {
      final host = FakeHost();
      var listened = 0;
      host.methods['takeLaunch'] = (_) => {'action': 'panel_voice'};
      host.methods['listen'] = (_) {
        listened++;
        return null;
      };
      final agent = newAgent()
        ..status = BootStatus.ready
        ..isChat = true;
      PanelState.instance.apply({'surface': 'panel'});
      await pumpLook(tester, const Look(), PanelGate(agent: agent, child: const SizedBox()), height: 520);
      await frames(tester, 12);
      expect(listened, 1);
    });
  });
}
