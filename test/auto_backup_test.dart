import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_backend.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/remote_profile.dart';

import 'support/remote_rig.dart';

/// Automatic server backups end to end (agent/src/autobackup.ts, lib/agent/remote_mode.dart): the app turns them on
/// with a key it makes, the real daemon writes them, and they come to the phone over the real ssh chain.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(PlatformBackend.method, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(PlatformBackend.method, null));
  });

  final skip = RemoteRig.skip;

  test('turned on from the app: a key made on the phone, a backup on the server, a copy fetched to the phone', () async {
    final rig = await RemoteRig.start();
    addTearDown(rig.dispose);
    final remote = rig.agent.remote;
    File('${rig.daemon.home.path}/workspace/site/index.html')
      ..createSync(recursive: true)
      ..writeAsStringSync('<h1>Halo</h1>');

    await remote.refreshAutoBackup();
    expect(remote.autoBackup!['enabled'], isFalse);
    expect(remote.profile!.backupKey, isNull);

    await remote.setAutoBackup(true);
    final key = remote.profile!.backupKey!;
    expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
    // Kept with the profile, so it is there after the app restarts.
    expect(RemoteProfileStore(File('${rig.app.path}/.griphub/remote.json')).load()!.backupKey, key);
    expect(remote.autoBackup!['enabled'], isTrue);

    final fetched = await remote.backupNow(force: true);
    expect(fetched, isNotNull);
    expect(fetched!.path, startsWith(remote.backupsDir.path));
    // Turning it on also made one in the background; the newest is the one fetched.
    final serverCopy = (Directory('${rig.daemon.home.path}/.griphub/backups')
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.ghb'))
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path)))
        .first;
    expect(fetched.readAsBytesSync(), serverCopy.readAsBytesSync(), reason: 'the same bytes as on the server');
    expect(String.fromCharCodes(fetched.readAsBytesSync().take(4)), 'GHB1');
    expect(fetched.readAsStringSync(encoding: latin1).contains('<h1>Halo</h1>'), isFalse, reason: 'encrypted');
    expect(remote.localBackups().first.path, fetched.path);

    // Already here: not fetched again.
    final before = fetched.lastModifiedSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect((await remote.pullLatestBackup())!.lastModifiedSync(), before);

    // Off: the server's copies go, the phone keeps its own and the key.
    await remote.setAutoBackup(false);
    expect(remote.autoBackup!['backups'], isEmpty);
    expect(remote.localBackups(), isNotEmpty);
    expect(remote.profile!.backupKey, key);
    // A restore needs the phone's own agent.
    await expectLater(remote.restoreOnPhone(fetched), throwsA(isA<AgentError>()));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
