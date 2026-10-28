// Goldens for the server agent (server_agent.md, phase 4): the Server agent screen before a server is set up and on a
// connected server, and the chat's connection banner while the link is down. Light/dark, English/Indonesian, and a
// narrow phone with large text, where nothing may overflow.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/remote_profile.dart';
import 'package:griphub_agent/ui/box_screen.dart';
import 'package:griphub_agent/ui/server_screen.dart';
import 'package:griphub_agent/ui/terminal_screen.dart';

import '../support/fake_backend.dart';
import 'harness.dart';

const _hostKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABn0o4m7AzJb8wgXq1z+8+KtuqK5nyX6AX9nOQI2zVG';
const _pubKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyOnlyForTests griphub-app';

String _code() =>
    'griphub1:${base64.encode(utf8.encode(jsonEncode({'v': 1, 'host': 'agentai.example.com', 'port': 22, 'user': 'griphub', 'hostKey': _hostKey})))}';

/// RemoteSetup with a fixed key and no ssh.
class _StubSetup extends RemoteSetup {
  _StubSetup(String home) : super(home: home);

  @override
  Future<String> ensureKey({Map<String, String>? env}) async => _pubKey;

  @override
  Future<String?> remoteStamp({Map<String, String>? env}) async => null;
}

const _looks = [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)];

void main() {
  setUpAll(loadAppFonts);

  late Directory tmp;
  late FakeBackend backend;
  late AgentController agent;

  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('griphub/agent'), (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('griphub/agent'), null));
    tmp = Directory.systemTemp.createTempSync('gh-golden-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    backend = FakeBackend();
    agent = AgentController(AgentClient(backend: backend)..backoff = ((_) => const Duration(minutes: 1)));
  });

  void configure({bool saved = false, bool active = false}) {
    final store = RemoteProfileStore(File('${tmp.path}/home/.griphub/remote.json'));
    if (saved) store.save(RemoteProfile.fromSetupCode(SetupCode.parse(_code())).copyWith(active: active));
    // The setup script the agent bundle carries.
    File('${tmp.path}/host/server/griphub-setup.sh')
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
    agent.remote.configure(setup: _StubSetup('${tmp.path}/home'), store: store, hostDir: '${tmp.path}/host');
  }

  for (final look in _looks) {
    testWidgets('server screen, no server yet (${look.name})', (tester) async {
      configure();
      await pumpLook(tester, look, ServerScreen(agent: agent), height: 1500);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      collectLayoutErrors(tester, 'server_setup_${look.name}');
      await expectLater(find.byType(ServerScreen), matchesGoldenFile(golden('server_setup_${look.name}')));
      expect(layoutErrors.where((e) => e.contains('server_setup_${look.name}')), isEmpty);
    });

    testWidgets('server screen, connected (${look.name})', (tester) async {
      configure(saved: true, active: true);
      backend.onCommand = (c) => switch (c['type']) {
        'health' => {
          'disk': {'freeBytes': 61203283968, 'totalBytes': 107374182400, 'level': 'ok'},
          'memory': {'rssBytes': 420 * 1024 * 1024},
          'runs': {'running': 1, 'queued': 0},
          'subagents': true,
          'uptimeSec': 93780,
          'node': 'v24.22.0',
          // The box image never got built (the field test's VPS): the card says so and offers the way out.
          'box': {'available': true, 'installed': false, 'enabled': true},
        },
        'settings_get' => {
          'notify': {'enabled': true, 'url': 'https://ntfy.sh', 'topic': 'griphub-3f9c2a7b1d4e8f60a5b2c7d9e1f3a4b6'},
        },
        _ => null,
      };
      await tester.runAsync(() => agent.client.start());
      await pumpLook(tester, look, ServerScreen(agent: agent), height: 1900);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      await tester.pump();
      collectLayoutErrors(tester, 'server_connected_${look.name}');
      await expectLater(find.byType(ServerScreen), matchesGoldenFile(golden('server_connected_${look.name}')));
      expect(layoutErrors.where((e) => e.contains('server_connected_${look.name}')), isEmpty);
    });

    testWidgets('connection banner and chip, reconnecting (${look.name})', (tester) async {
      configure(saved: true, active: true);
      final now = DateTime.now();
      agent.client.connection.value = Connection(
        LinkState.reconnecting,
        attempt: 3,
        retryAt: now.add(const Duration(seconds: 8, milliseconds: 500)),
        reason: 'ssh: connect to host agentai.example.com port 22: Connection timed out',
      );
      await pumpLook(
        tester,
        look,
        Scaffold(
          appBar: AppBar(
            title: const Text('Chat'),
            actions: [ConnectionChip(agent: agent)],
          ),
          body: Column(
            children: [
              ConnectionBanner(agent: agent),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
        height: 300,
      );
      collectLayoutErrors(tester, 'server_banner_${look.name}');
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('server_banner_${look.name}')));
      expect(layoutErrors.where((e) => e.contains('server_banner_${look.name}')), isEmpty);
      await tester.pumpWidget(const SizedBox()); // stops the countdown timer
    });

    testWidgets('update banner, server agent from another bundle (${look.name})', (tester) async {
      Directory('${tmp.path}/host').createSync(recursive: true);
      File('${tmp.path}/host/.stamp').writeAsStringSync('1.4.0 1800000000000\n');
      configure(saved: true, active: true);
      backend.hello = {...backend.hello, 'bundleStamp': '1.3.0 1700000000000'};
      await tester.runAsync(() => agent.client.start());
      await pumpLook(
        tester,
        look,
        Scaffold(
          appBar: AppBar(
            title: const Text('Chat'),
            actions: [ConnectionChip(agent: agent)],
          ),
          body: Column(
            children: [
              ConnectionBanner(agent: agent),
              ServerUpdateBanner(agent: agent),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
        height: 300,
      );
      await tester.pump();
      collectLayoutErrors(tester, 'server_update_${look.name}');
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('server_update_${look.name}')));
      expect(layoutErrors.where((e) => e.contains('server_update_${look.name}')), isEmpty);
    });

    testWidgets('terminal tab, connection to the server lost (${look.name})', (tester) async {
      var reconnects = 0;
      await pumpLook(
        tester,
        look,
        Scaffold(
          appBar: AppBar(title: const Text('Terminal')),
          body: Column(
            children: [
              ServerTabLostBar(onReconnect: () => reconnects++),
              const Expanded(child: ColoredBox(color: Colors.black)),
            ],
          ),
        ),
        height: 260,
      );
      collectLayoutErrors(tester, 'server_tab_lost_${look.name}');
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('server_tab_lost_${look.name}')));
      expect(layoutErrors.where((e) => e.contains('server_tab_lost_${look.name}')), isEmpty);
      await tester.tap(find.byType(TextButton));
      expect(reconnects, 1);
    });

    testWidgets('box screen, box not built yet (${look.name})', (tester) async {
      configure(saved: true, active: true);
      backend.onCommand = (c) => switch (c['type']) {
        'container_status' => {
          'kind': 'podman',
          'available': true,
          'installed': false,
          'state': 'none',
          'enabled': true,
          'image': 'localhost/griphub-box',
          'startedAt': null,
          'usage': null,
          'limits': {'memory': '2g', 'swap': '3g', 'cpus': '1.5'},
          'problem': 'The box image has not been built on this server.',
        },
        _ => null,
      };
      await tester.runAsync(() => agent.client.start());
      await pumpLook(tester, look, BoxScreen(agent: agent), height: 1300);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      await tester.pump();
      collectLayoutErrors(tester, 'box_not_built_${look.name}');
      await expectLater(find.byType(BoxScreen), matchesGoldenFile(golden('box_not_built_${look.name}')));
      expect(layoutErrors.where((e) => e.contains('box_not_built_${look.name}')), isEmpty);
    });
  }
}
