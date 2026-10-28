import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/remote_rig.dart';

/// The app's server agent switch and its "Install / update agent" over a real ssh chain (private sshd, real attach, real
/// daemon): updating a server the app is connected to asks the host to restart once it is idle (`host_restart`), so a
/// chat or subagent at work is never cut off; the version check compares the bundle stamps (server_agent.md 4.10).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = RemoteRig.skip;

  late RemoteRig rig;
  late Directory bundle;

  setUp(() async {
    rig = await RemoteRig.start();
    // The agent bundle this app carries (on the phone: filesDir/agent).
    bundle = Directory.systemTemp.createTempSync('gh-bundle-');
    File('${bundle.path}/host.mjs').writeAsStringSync('// new host\n');
    File('${bundle.path}/.stamp').writeAsStringSync('1.3.0 1700000000000');
    Directory('${bundle.path}/skills').createSync();
    File('${bundle.path}/skills/README.md').writeAsStringSync('skills');
    rig.agent.remote.hostDir = bundle.path;
  });

  tearDown(() async {
    await rig.dispose();
    bundle.deleteSync(recursive: true);
  });

  test('connected through ssh, the client is the server agent and the link is up', () {
    expect(rig.agent.remote.active, isTrue);
    expect(rig.agent.client.isRemote, isTrue);
    expect(rig.agent.client.connection.value.connected, isTrue);
    expect(rig.agent.client.serverHello?['mode'], 'server');
  }, skip: skip);

  test('updating a connected server copies the agent and lets the host restart itself once it is idle', () async {
    expect(await rig.agent.remote.upToDate(), isFalse, reason: 'nothing installed on the server yet');
    final r = await rig.agent.remote.install();
    expect(r.ok, isTrue, reason: r.message);
    expect(r.message, contains('restarting'));
    expect(File('${rig.remoteDir}/host/host.mjs').readAsStringSync(), '// new host\n');
    expect(File('${rig.remoteDir}/host/skills/README.md').existsSync(), isTrue);
    // The daemon was asked, not killed: it exits on its own (systemd would start the new files).
    expect(await rig.daemon.process!.exitCode.timeout(const Duration(seconds: 10)), 0);
    expect(await rig.agent.remote.upToDate(), isTrue);
  }, skip: skip);

  test('switching to the phone and back changes where the client connects', () async {
    rig.agent.remote.profile = rig.agent.remote.profile!.copyWith(active: false);
    rig.agent.remote.store!.save(rig.agent.remote.profile!);
    rig.agent.remote.configure(setup: rig.setup, store: rig.agent.remote.store!, hostDir: bundle.path);
    expect(rig.agent.client.isRemote, isFalse);
    rig.agent.remote.profile = rig.agent.remote.profile!.copyWith(active: true);
    rig.agent.remote.store!.save(rig.agent.remote.profile!);
    rig.agent.remote.configure(setup: rig.setup, store: rig.agent.remote.store!, hostDir: bundle.path);
    expect(rig.agent.client.isRemote, isTrue);
    expect(rig.agent.client.remote!.argv, contains('griphub-vps'));
    expect(rig.agent.client.remote!.argv.last, '${rig.remoteDir}/bin/griphub-attach');
  }, skip: skip);

  test('forgetting the server removes the key and the ssh files, and the app is back on the phone', () async {
    final key = rig.setup.keyPath;
    expect(File(key).existsSync(), isTrue);
    // On this machine there is no phone host to start afterwards, so the restart that follows fails; what matters
    // here is what is left behind.
    await rig.agent.remote.forget();
    expect(rig.agent.remote.configured, isFalse);
    expect(rig.agent.client.isRemote, isFalse);
    expect(File(key).existsSync(), isFalse);
    expect(File(rig.setup.configPath).existsSync(), isFalse);
    expect(File(rig.setup.knownHostsPath).existsSync(), isFalse);
    expect(rig.agent.remote.store!.load(), isNull);
  }, skip: skip);
}
