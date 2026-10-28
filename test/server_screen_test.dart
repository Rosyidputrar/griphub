import 'dart:convert';
import 'dart:io';

import 'package:griphub_agent/agent/agent_backend.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/remote_profile.dart';
import 'package:griphub_agent/ui/server_screen.dart';
import 'package:griphub_agent/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_backend.dart';

const hostKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABn0o4m7AzJb8wgXq1z+8+KtuqK5nyX6AX9nOQI2zVG';
const pubKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKeyOnlyForTests griphub-app';

String setupCode([Map<String, Object?> over = const {}]) =>
    'griphub1:${base64.encode(utf8.encode(jsonEncode({'v': 1, 'host': 'agent.example.com', 'port': 22, 'user': 'griphub', 'hostKey': hostKey, ...over})))}';

/// RemoteSetup without the processes: a fixed key, and answers for the server checks the test chooses.
class StubSetup extends RemoteSetup {
  StubSetup(String home) : super(home: home, ssh: 'ssh');

  ServerCheck result = const ServerCheck(ProblemNone.ok, 'Connected. The agent is running on the server.');
  InstallResult installResult = const InstallResult(
    ok: true,
    message: 'Installed (12 files). The agent was restarted.',
    filesSent: 12,
  );
  var checks = 0;
  var installs = 0;

  @override
  Future<String> ensureKey({Map<String, String>? env}) async => pubKey;

  @override
  Future<ServerCheck> check(
    RemoteProfile p, {
    Map<String, String>? env,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    checks++;
    return result;
  }

  @override
  Future<InstallResult> install(
    String hostDir, {
    Map<String, String>? env,
    void Function(String line)? onProgress,
    bool restart = true,
  }) async {
    installs++;
    onProgress?.call('Copying the agent...');
    return installResult;
  }
}

// ServerProblem.none is awkward to spell next to a ServerCheck, so name it once.
class ProblemNone {
  static const ok = ServerProblem.none;
}

/// The Server agent screen, the connection chip and the banner. Ported from CoderRa's test/server_screen_test.dart (the
/// file-access parts come with phase 5, server_agent.md).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late FakeBackend backend;
  late AgentController agent;
  late StubSetup setup;
  late RemoteProfileStore store;

  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(PlatformBackend.method, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(PlatformBackend.method, null));
    tmp = Directory.systemTemp.createTempSync('gh-ui-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    backend = FakeBackend();
    agent = AgentController(AgentClient(backend: backend)..backoff = ((_) => const Duration(milliseconds: 20)));
    setup = StubSetup('${tmp.path}/home');
    store = RemoteProfileStore(File('${tmp.path}/home/.griphub/remote.json'));
  });

  /// [saved]: a server already set up; [active]: and in use.
  void configure({bool saved = false, bool active = false}) {
    if (saved) store.save(RemoteProfile.fromSetupCode(SetupCode.parse(setupCode())).copyWith(active: active));
    agent.remote.configure(setup: setup, store: store, hostDir: '${tmp.path}/host');
  }

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> show(WidgetTester tester, Widget child) async {
    tall(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: child),
      ),
    );
  }

  group('ConnectionChip', () {
    testWidgets('is invisible until a server is set up, then says which agent is in use', (tester) async {
      configure();
      await show(tester, ConnectionChip(agent: agent));
      expect(find.byType(Text), findsNothing);

      store.save(RemoteProfile.fromSetupCode(SetupCode.parse(setupCode())));
      configure(); // reads it again
      await tester.pump();
      expect(find.text('Phone'), findsOneWidget);
    });

    testWidgets('follows the link while the server is in use', (tester) async {
      configure(saved: true, active: true);
      await show(tester, ConnectionChip(agent: agent));
      final link = agent.client.connection;

      link.value = Connection.local;
      await tester.pump();
      expect(find.text('Server'), findsOneWidget);

      link.value = const Connection(LinkState.reconnecting, attempt: 2);
      await tester.pump();
      expect(find.text('Reconnecting'), findsOneWidget);

      link.value = const Connection(LinkState.offline);
      await tester.pump();
      expect(find.text('Offline'), findsOneWidget);
    });
  });

  group('ConnectionBanner', () {
    testWidgets('is silent on the phone and while connected', (tester) async {
      configure();
      await show(tester, ConnectionBanner(agent: agent));
      expect(find.byType(Text), findsNothing);
      configure(saved: true, active: true);
      await tester.pump();
      expect(find.byType(Text), findsNothing, reason: 'connected');
    });

    testWidgets('says it is reconnecting, why, and lets the user hurry it', (tester) async {
      configure(saved: true, active: true);
      await show(tester, ConnectionBanner(agent: agent));
      agent.client.connection.value = Connection(
        LinkState.reconnecting,
        attempt: 3,
        retryAt: DateTime.now().add(const Duration(seconds: 8)),
        reason: 'ssh: connect to host x port 22: Connection timed out',
      );
      await tester.pump();
      expect(find.textContaining('Reconnecting to the server'), findsOneWidget);
      expect(find.textContaining('Connection timed out'), findsOneWidget);
      expect(find.text('The agent keeps working on the server.'), findsOneWidget);
      expect(find.text('Retry now'), findsOneWidget);
      await tester.pumpWidget(const SizedBox()); // stop the countdown timer
    });

    testWidgets('after another device took over it offers to take the connection back', (tester) async {
      configure(saved: true, active: true);
      await show(tester, ConnectionBanner(agent: agent));
      agent.client.connection.value = const Connection(
        LinkState.offline,
        kicked: true,
        reason: 'Another device took over the connection.',
      );
      await tester.pump();
      expect(find.text('Another device is using the server agent'), findsOneWidget);
      expect(find.text('Take over'), findsOneWidget);

      await tester.tap(find.text('Take over'));
      await tester.pump();
      expect(agent.client.connection.value.state, LinkState.reconnecting);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      expect(backend.starts, 1, reason: 'taking over starts a new connection');
      expect(agent.client.connection.value.connected, isTrue);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('when simply offline it says so and offers to reconnect', (tester) async {
      configure(saved: true, active: true);
      await show(tester, ConnectionBanner(agent: agent));
      agent.client.connection.value = const Connection(LinkState.offline);
      await tester.pump();
      expect(find.text('Not connected to the server'), findsOneWidget);
      expect(find.text('Reconnect'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('ServerUpdateBanner', () {
    Future<void> openChat(
      WidgetTester tester, {
      required String? serverStamp,
      String localStamp = '1.4.0 1800000000000',
    }) async {
      Directory('${tmp.path}/host').createSync(recursive: true);
      File('${tmp.path}/host/.stamp').writeAsStringSync('$localStamp\n');
      configure(saved: true, active: true);
      backend.hello = {...backend.hello, 'bundleStamp': ?serverStamp};
      backend.onCommand = (c) => switch (c['type']) {
        'host_restart' => {'restarting': false},
        _ => null,
      };
      await tester.runAsync(() => agent.client.start());
      await show(tester, ServerUpdateBanner(agent: agent));
      await tester.pump();
    }

    testWidgets('a server agent from another bundle offers the update; it waits until the agent is done', (
      tester,
    ) async {
      await openChat(tester, serverStamp: '1.3.0 1700000000000');
      expect(find.text('The agent on the server is not the version this app carries.'), findsOneWidget);
      await tester.tap(find.text('Update'));
      for (var i = 0; i < 10 && setup.installs == 0; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(setup.installs, 1);
      expect(backend.sent.map((c) => c['type']), contains('host_restart'), reason: 'restarts once idle, not at once');
      expect(find.text('The server agent updates once it finishes its current work.'), findsOneWidget);
      expect(find.text('Update'), findsNothing);
    });

    testWidgets('the same bundle on both sides: nothing to say', (tester) async {
      await openChat(tester, serverStamp: '1.4.0 1800000000000');
      expect(find.textContaining('not the version'), findsNothing);
    });

    testWidgets('an older host that does not name its bundle counts as another version', (tester) async {
      await openChat(tester, serverStamp: null);
      expect(find.text('The agent on the server is not the version this app carries.'), findsOneWidget);
    });
  });

  group('ServerScreen', () {
    Future<void> open(WidgetTester tester) async {
      tall(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: ServerScreen(agent: agent),
        ),
      );
      await tester.pump();
    }

    testWidgets('with no server: shows the app\'s key in a command to run on the server, and asks for the code', (
      tester,
    ) async {
      configure();
      await open(tester);
      expect(find.text('This phone runs the agent'), findsOneWidget);
      expect(find.textContaining("sh griphub-setup.sh --pubkey '$pubKey'"), findsOneWidget);
      expect(find.text('Setup code'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Server address (name or IP)'), 'agent.example.com');
      await tester.pump();
      expect(find.textContaining("--address 'agent.example.com'"), findsOneWidget);
    });

    testWidgets('the setup files come with the app: one paste for the server\'s terminal, or the file to share', (
      tester,
    ) async {
      final script = File('${tmp.path}/host/server/griphub-setup.sh')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\necho the server files\n');
      final platform = <MethodCall>[];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(PlatformBackend.method, (call) async {
        platform.add(call);
        return null;
      });
      String? clipboard;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      configure();
      await open(tester);
      expect(find.textContaining('nothing has to be downloaded'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Server address (name or IP)'), '85.9.194.68');
      await tester.pump();

      await tester.tap(find.text('Copy setup command'));
      // Reading the script is real I/O: let it finish, then let the copy go out.
      for (var i = 0; i < 10 && clipboard == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(
        clipboard,
        "cat > griphub-setup.sh <<'GRIPHUB_SETUP'\n#!/bin/sh\necho the server files\nGRIPHUB_SETUP\n"
        "sh griphub-setup.sh --pubkey '$pubKey' --address '85.9.194.68'\n",
      );

      await tester.tap(find.text('Share the setup file instead'));
      await tester.pump();
      expect(platform.where((c) => c.method == 'shareFile').single.arguments, {'path': script.path});
    });

    testWidgets('an app without the setup files (a build without the agent bundle) points to the repository instead', (
      tester,
    ) async {
      configure();
      await open(tester);
      expect(find.textContaining('server/ folder of the GripHub repository'), findsOneWidget);
      expect(find.text('Copy setup command'), findsNothing);
      expect(find.text('Share the setup file instead'), findsNothing);
    });

    testWidgets('a bad code says what is wrong; a good one saves the server, writes its ssh files and shows it', (
      tester,
    ) async {
      configure();
      await open(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Setup code'), 'hello');
      await tester.tap(find.text('Save server'));
      await tester.pump();
      expect(find.textContaining('not a setup code'), findsOneWidget);
      expect(store.load(), isNull);

      await tester.enterText(find.widgetWithText(TextField, 'Setup code'), 'Done. Paste this:\n\n  ${setupCode()}\n');
      await tester.tap(find.text('Save server'));
      await tester.pump();
      expect(find.textContaining('not a setup code'), findsNothing);
      expect(find.text('agent.example.com'), findsOneWidget);
      expect(find.text('user griphub'), findsOneWidget);
      final saved = store.load()!;
      expect([saved.host, saved.active], ['agent.example.com', false]);
      expect(File(setup.configPath).readAsStringSync(), contains('HostName agent.example.com'));
      expect(File(setup.knownHostsPath).readAsStringSync(), 'agent.example.com $hostKey\n');
      expect(agent.client.isRemote, isFalse, reason: 'saving a server does not switch to it');
    });

    testWidgets('testing the connection shows the verdict, with the way out when it is bad', (tester) async {
      configure(saved: true);
      await open(tester);
      await tester.tap(find.text('Test connection'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Connected. The agent is running on the server.'), findsOneWidget);
      expect(setup.checks, 1);

      setup.result = const ServerCheck(
        ServerProblem.authRejected,
        'The server did not accept this app\'s key.',
        detail: 'Permission denied (publickey).',
      );
      await tester.tap(find.text('Test connection'));
      await tester.pump();
      await tester.pump();
      expect(find.text('The server did not accept this app\'s key.'), findsOneWidget);
      expect(find.text('Permission denied (publickey).'), findsOneWidget);
    });

    testWidgets('installing shows what it did, and tests the server afterwards', (tester) async {
      configure(saved: true);
      await open(tester);
      await tester.tap(find.text('Install / update agent'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Installed (12 files). The agent was restarted.'), findsOneWidget);
      expect(setup.installs, 1);
      expect(setup.checks, 1, reason: 'a successful install is followed by a check');

      setup.installResult = const InstallResult(
        ok: false,
        message: 'Copying failed: rsync: connection unexpectedly closed',
      );
      await tester.tap(find.text('Install / update agent'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Copying failed: rsync: connection unexpectedly closed'), findsOneWidget);
      expect(setup.checks, 1);
    });

    testWidgets('switching to the server asks first, and cancelling changes nothing', (tester) async {
      configure(saved: true);
      await open(tester);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Use the server agent?'), findsOneWidget);
      expect(find.textContaining('stay here, untouched'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.load()!.active, isFalse);
      expect(agent.client.isRemote, isFalse);
    });

    testWidgets('forgetting a server asks first, then removes the key and the ssh files', (tester) async {
      configure(saved: true);
      setup.write(store.load()!);
      await open(tester);
      await tester.ensureVisible(find.text('Forget this server'));
      await tester.tap(find.text('Forget this server'));
      await tester.pumpAndSettle();
      expect(find.text('Forget this server?'), findsOneWidget);
      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();
      expect(store.load(), isNull);
      expect(File(setup.configPath).existsSync(), isFalse);
      expect(find.text('Setup code'), findsOneWidget, reason: 'back to the set-up steps');
    });
  });

  group('ServerScreen on a connected server', () {
    Map<String, Object?> notify = {'enabled': false, 'url': 'https://ntfy.sh', 'topic': null};

    Future<void> openConnected(WidgetTester tester, {String diskLevel = 'ok', Map<String, Object?>? box}) async {
      configure(saved: true, active: true);
      notify = {'enabled': false, 'url': 'https://ntfy.sh', 'topic': null};
      backend.onCommand = (c) => switch (c['type']) {
        'health' => {
          'disk': {'freeBytes': 13421772800, 'totalBytes': 53687091200, 'level': diskLevel},
          'memory': {'rssBytes': 300 * 1024 * 1024},
          'runs': {'running': 1, 'queued': 2},
          'uptimeSec': 7500,
          'subagents': true,
          'node': 'v24.22.0',
          'box': ?box,
        },
        'settings_get' => {'notify': notify},
        'settings_set' => () {
          notify = ((c['settings'] as Map)['notify'] as Map).cast<String, Object?>();
          return {'notify': notify};
        }(),
        _ => null,
      };
      await tester.runAsync(() => agent.client.start());
      tall(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: ServerScreen(agent: agent),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('shows how the server is doing', (tester) async {
      await openConnected(tester);
      expect(find.text('Your server runs the agent'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('Server health'), findsOneWidget);
      expect(find.text('Disk free  12.5 GB / 50.0 GB'), findsOneWidget);
      expect(find.text('Agent memory  0.3 GB'), findsOneWidget);
      expect(find.text('Running  1 · queued 2'), findsOneWidget);
      expect(find.text('Up for  2 h 5 min'), findsOneWidget);
      expect(find.text('Subagents  working'), findsOneWidget);
      expect(find.textContaining('almost full'), findsNothing);
    });

    testWidgets('says where the agent\'s commands run', (tester) async {
      await openConnected(tester, box: {'available': true, 'installed': true, 'enabled': true});
      expect(find.text('Box  ready · commands run inside it'), findsOneWidget);
      expect(find.text('Build the box'), findsNothing);
    });

    testWidgets('a box that is not built is a problem with a way out', (tester) async {
      await openConnected(tester, box: {'available': true, 'installed': false, 'enabled': true});
      expect(find.text('Box  not built · commands are refused'), findsOneWidget);
      expect(find.text('The agent cannot run commands until the box is built.'), findsOneWidget);
      expect(find.text('Build the box'), findsOneWidget);
    });

    testWidgets('warns when the disk is getting full', (tester) async {
      await openConnected(tester, diskLevel: 'critical');
      expect(find.textContaining('The disk is almost full'), findsOneWidget);
    });

    testWidgets('makes a secret topic, saves it with the server address, and reads it back', (tester) async {
      await openConnected(tester);
      expect(find.text('Not set up yet'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Make a new one'));
      await tester.tap(find.byTooltip('Make a new one'));
      await tester.pump();
      final field = tester.widget<TextField>(find.widgetWithText(TextField, 'Topic (keep it secret)'));
      final topic = field.controller!.text;
      expect(topic, matches(RegExp(r'^griphub-[0-9a-f]{32}$')), reason: '128 bits, so nobody can guess it');

      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      final sent = backend.sent.lastWhere((c) => c['type'] == 'settings_set');
      expect(((sent['settings'] as Map)['notify'] as Map), {'enabled': true, 'url': 'https://ntfy.sh', 'topic': topic});
      expect(find.text('Notifications saved'), findsOneWidget);
      expect(find.text('Not set up yet'), findsNothing);
    });
  });

  group('switching agents', () {
    setUp(() {
      backend.onCommand = (c) => switch (c['type']) {
        'messages' || 'providers' || 'models' || 'sessions' => <Object?>[],
        _ => <String, Object?>{'workspace': '/srv/work'},
      };
    });

    test('using the server points the client at it; using the phone undoes it', () async {
      configure(saved: true);
      expect(agent.client.isRemote, isFalse);

      await agent.remote.use(true);
      expect(agent.remote.active, isTrue);
      expect(store.load()!.active, isTrue, reason: 'remembered for the next start');
      expect(agent.client.isRemote, isTrue);
      expect(agent.client.remote!.argv, containsAllInOrder(['ssh', '-F', setup.configPath, '-T', 'griphub-vps']));
      expect(agent.status, BootStatus.ready, reason: agent.bootError);
      expect(backend.sent.where((c) => c['type'] == 'resume'), hasLength(1), reason: 'it connected as a server agent');

      await agent.remote.use(false);
      expect(agent.client.isRemote, isFalse);
      expect(store.load()!.active, isFalse);
    });

    test('forgetting the server in use puts the phone\'s agent back', () async {
      configure(saved: true, active: true);
      expect(agent.client.isRemote, isTrue);
      await agent.remote.forget();
      expect(agent.client.isRemote, isFalse);
      expect(agent.remote.configured, isFalse);
    });

    test('a saved server in use is picked up at start', () {
      configure(saved: true, active: true);
      expect(agent.client.isRemote, isTrue);
    });
  });
}
