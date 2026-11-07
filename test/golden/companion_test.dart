// Screen companion on the Dart side (lib/agent/companion.dart, Fitur 5): it starts only with the user's consent, a
// step sends the screen as it is (or that it cannot be seen), the highlight lands where the step points, and Stop ends
// it at once, from the app or from Android's notification.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/companion.dart';
import 'package:griphub_agent/agent/drafts.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/agent/panel.dart';
import 'package:griphub_agent/ui/companion_screen.dart';
import 'package:griphub_agent/ui/panel_screen.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'harness.dart';

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const _frame = {
  'data': 'SlBFRw==',
  'mimeType': 'image/jpeg',
  'width': 540,
  'height': 1200,
  'screenWidth': 1080,
  'screenHeight': 2400,
  'mean': 120.0,
  'deviation': 60.0,
};

/// A phone side for the companion: consent [consent], frames like [frame], the accessibility tree when [a11y].
(FakeHost, List<String>) phone({bool consent = true, Map<String, Object?> frame = _frame, bool a11y = false}) {
  final host = FakeHost();
  final calls = <String>[];
  host.methods['companionStart'] = (_) {
    calls.add('start');
    return consent;
  };
  host.methods['companionCapture'] = (_) {
    calls.add('capture');
    return frame;
  };
  host.methods['companionStop'] = (_) {
    calls.add('stop');
    return null;
  };
  host.methods['companionClearHighlight'] = (_) => null;
  host.methods['companionHighlight'] = (c) {
    final a = (c.arguments as Map);
    calls.add('highlight ${a['x']},${a['y']},${a['w']},${a['h']}');
    return null;
  };
  host.methods['a11yStatus'] = (_) => a11y;
  host.methods['a11yTree'] = (_) => [
    {'id': 'n1', 'text': 'Transfer', 'x': 40, 'y': 1800, 'w': 300, 'h': 120},
  ];
  host.answers['companion_start'] = (_) => {'active': true};
  host.answers['companion_stop'] = (_) => {'active': false};
  return (host, calls);
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() async {
    layoutErrors.clear();
    Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
  });
  tearDown(PanelState.instance.reset);

  test('a black, flat frame is a secure screen; an ordinary one is not', () {
    expect(ScreenCompanion.isSecureFrame(0, 0), isTrue);
    expect(ScreenCompanion.isSecureFrame(3.2, 1.1), isTrue);
    expect(ScreenCompanion.isSecureFrame(30, 2), isFalse, reason: 'a dark app with content');
    expect(ScreenCompanion.isSecureFrame(5, 25), isFalse, reason: 'dark but not flat');
  });

  test('where the highlight goes: an element of the tree as it is, a box from the frame scaled to the screen', () {
    const frame = (width: 540, height: 1200, screenWidth: 1080, screenHeight: 2400);
    final nodes = {
      'n1': <String, dynamic>{'x': 40, 'y': 1800, 'w': 300, 'h': 120},
    };
    expect(ScreenCompanion.place({'id': 'n1'}, frame: frame, nodes: nodes), (x: 40, y: 1800, w: 300, h: 120));
    expect(ScreenCompanion.place({'x': 20, 'y': 900, 'w': 150, 'h': 60}, frame: frame), (x: 40, y: 1800, w: 300, h: 120));
    expect(ScreenCompanion.place({'id': 'n9'}, frame: frame, nodes: nodes), isNull, reason: 'an unknown element points at nothing');
    expect(ScreenCompanion.place({'x': 900, 'y': 10, 'w': 10, 'h': 10}, frame: frame), isNull, reason: 'off the screen');
    expect(ScreenCompanion.place(null, frame: frame), isNull);
  });

  test('the reply is shown without its pointer line', () {
    expect(hideCompanionPointer('Ketuk Transfer.\nSOROT: #n1'), 'Ketuk Transfer.');
    expect(hideCompanionPointer('Biasa saja'), 'Biasa saja');
  });

  testWidgets('declined consent: nothing starts, nothing is recorded', (tester) async {
    final (host, calls) = phone(consent: false);
    final agent = newAgent();
    await tester.pump();
    expect(await ScreenCompanion.instance.start(agent), isFalse);
    expect(calls, ['start']);
    expect(host.sent('companion_start'), isEmpty);
    expect(ScreenCompanion.instance.active, isFalse);
  });

  testWidgets('a step: the screen goes with it; the highlight lands on the element; Stop ends it all', (tester) async {
    final (host, calls) = phone(a11y: true);
    final agent = newAgent();
    await tester.pump();
    expect(await ScreenCompanion.instance.start(agent), isTrue);
    expect(host.sent('companion_start'), hasLength(1));
    await ScreenCompanion.instance.step(agent, 'Bagaimana cara transfer?');
    final turn = host.sent('companion_turn').single;
    expect(turn['secure'], isFalse);
    expect((turn['frame'] as Map)['data'], 'SlBFRw==');
    expect((turn['tree'] as List).single['text'], 'Transfer');
    host.emit({'type': 'companion_pointer', 'pointer': {'id': 'n1'}});
    await frames(tester);
    expect(calls, contains('highlight 40,1800,300,120'));
    expect(ScreenCompanion.instance.looking, isFalse);
    await ScreenCompanion.instance.stop(agent);
    expect(calls.last, 'stop');
    expect(host.sent('companion_stop'), hasLength(1));
    expect(ScreenCompanion.instance.active, isFalse);
  });

  testWidgets('a secure screen: no picture is sent, only that it cannot be seen', (tester) async {
    final (host, _) = phone(frame: {..._frame, 'mean': 0.4, 'deviation': 0.2});
    final agent = newAgent();
    await tester.pump();
    await ScreenCompanion.instance.start(agent);
    await ScreenCompanion.instance.step(agent, 'Kenapa layar ini?');
    final turn = host.sent('companion_turn').single;
    expect(turn['secure'], isTrue);
    expect(turn.containsKey('frame'), isFalse);
    await ScreenCompanion.instance.stop(agent);
  });

  testWidgets('Stop from Android\'s notification ends it in the app too', (tester) async {
    final (host, _) = phone();
    final agent = newAgent();
    await tester.pump();
    await ScreenCompanion.instance.start(agent);
    expect(ScreenCompanion.instance.active, isTrue);
    host.emitPlatform({'kind': 'companion', 'active': false});
    await frames(tester);
    expect(ScreenCompanion.instance.active, isFalse);
    expect(host.sent('companion_stop'), hasLength(1), reason: 'recorded in the chat');
  });

  Future<(FakeHost, List<String>, AgentController)> panelWithCompanion(WidgetTester tester, {Look look = const Look()}) async {
    final (host, calls) = phone();
    host.methods['takeLaunch'] = (_) => null;
    final agent = newAgent()
      ..status = BootStatus.ready
      ..sessionId = 'p'
      ..isChat = true
      ..model = ModelInfo(const {'provider': 'griphub', 'id': 'gemini-3.8-flash', 'name': 'Gemini 3.8 Flash', 'input': ['text', 'image']});
    PanelState.instance.apply({'surface': 'panel'});
    await pumpLook(tester, look, PanelGate(agent: agent, child: const SizedBox()), height: 520);
    await frames(tester);
    await ScreenCompanion.instance.start(agent);
    await frames(tester);
    return (host, calls, agent);
  }

  testWidgets('in the panel: Stop always there, "I did it" takes the next step, a typed message is a step too', (tester) async {
    final (host, calls, agent) = await panelWithCompanion(tester);
    expect(find.text('Screen companion is on'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    await tester.tap(find.text('I did it'));
    await frames(tester);
    expect(host.sent('companion_turn').single['text'], 'Done. What next?');
    host.emit({'type': 'companion_pointer', 'pointer': null});
    await frames(tester);
    await tester.enterText(find.byType(TextField).last, 'Tombol yang mana?');
    await frames(tester);
    await tester.tap(find.byIcon(LucideIcons.arrowUp));
    await frames(tester);
    expect(host.sent('companion_turn').last['text'], 'Tombol yang mana?');
    expect(host.sent('prompt'), isEmpty, reason: 'not an ordinary message');
    await tester.tap(find.text('Stop'));
    await frames(tester);
    expect(calls, contains('stop'));
    expect(find.text('Screen companion is on'), findsNothing);
    expect(agent.busy, isFalse);
  });

  for (final look in const [Look(), Look(dark: true, language: 'id')]) {
    testWidgets('golden: panel with the companion on ${look.name}', (tester) async {
      await panelWithCompanion(tester, look: look);
      expect(layoutErrors, isEmpty);
      await loadImages(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('companion_panel_${look.name}')));
      await ScreenCompanion.instance.stop(newAgent());
    });

    testWidgets('golden: companion settings ${look.name}', (tester) async {
      phone();
      await pumpLook(tester, look, CompanionScreen(agent: newAgent()), height: 1500);
      await frames(tester);
      expect(layoutErrors, isEmpty);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('companion_settings_${look.name}')));
    });
  }
}
