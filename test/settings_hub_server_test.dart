import 'dart:io';

import 'package:griphub_agent/agent/agent_backend.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/remote_profile.dart';
import 'package:griphub_agent/ui/server_screen.dart';
import 'package:griphub_agent/ui/settings_hub.dart';
import 'package:griphub_agent/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'server_screen_test.dart' show StubSetup, setupCode;
import 'support/fake_backend.dart';

/// Settings says where the agent runs before anything else, and leads to the server agent from there.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late FakeBackend backend;
  late AgentController agent;

  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(PlatformBackend.method, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(PlatformBackend.method, null));
    tmp = Directory.systemTemp.createTempSync('gh-settings-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    backend = FakeBackend()..onCommand = (c) => null;
    agent = AgentController(AgentClient(backend: backend)..backoff = ((_) => const Duration(minutes: 1)));
  });

  void configure({bool saved = false, bool active = false}) {
    final store = RemoteProfileStore(File('${tmp.path}/home/.griphub/remote.json'));
    if (saved) store.save(RemoteProfile.fromSetupCode(SetupCode.parse(setupCode())).copyWith(active: active));
    agent.remote.configure(setup: StubSetup('${tmp.path}/home'), store: store, hostDir: '${tmp.path}/host');
  }

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: SettingsHub(agent: agent),
      ),
    );
    await tester.pump();
  }

  testWidgets('on the phone: says so, and the way to a server is at the top', (tester) async {
    configure();
    await open(tester);
    expect(find.text('Agent: this phone'), findsOneWidget);
    expect(find.text('Agent on a VPS / server'), findsOneWidget);
    expect(find.text('Linux container'), findsOneWidget);
    await tester.tap(find.text('Agent: this phone'));
    await tester.pumpAndSettle();
    expect(find.byType(ServerScreen), findsOneWidget);
  });

  testWidgets('on a server: the server, its link, and the box row before the box has answered', (tester) async {
    configure(saved: true, active: true);
    agent.client.connection.value = const Connection(LinkState.reconnecting, attempt: 1);
    await open(tester);
    expect(find.text('Agent: your server'), findsOneWidget);
    expect(find.text('Not connected to the server'), findsOneWidget);
    expect(find.text('The agent\'s box'), findsOneWidget, reason: 'not the phone\'s Debian or Alpine');
    expect(find.text('Where the agent\'s commands run'), findsOneWidget);
    expect(find.text('Linux container'), findsNothing);

    agent.client.connection.value = const Connection(LinkState.connected);
    await tester.pump();
    expect(find.text('Connected'), findsOneWidget);
  });
}
