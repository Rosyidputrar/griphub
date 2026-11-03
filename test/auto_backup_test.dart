import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
    expect(fetched.path, endsWith('.ghs'), reason: 'a server backs up as snapshots of blobs');
    // Turning it on also made one in the background; the newest is the one fetched.
    final serverDir = Directory('${rig.daemon.home.path}/.griphub/backups');
    final newest = (serverDir.listSync().whereType<File>().where((f) => f.path.endsWith('.ghs')).toList()
          ..sort((a, b) => b.path.compareTo(a.path)))
        .first;
    expect(fetched.readAsBytesSync(), newest.readAsBytesSync(), reason: 'the same snapshot as on the server');
    expect(String.fromCharCodes(fetched.readAsBytesSync().take(4)), 'GHS1');
    final blobs = Directory('${remote.backupsDir.path}/blobs').listSync().whereType<File>().toList();
    expect(blobs, isNotEmpty);
    for (final b in blobs) {
      expect(b.readAsBytesSync(), File('${serverDir.path}/blobs/${b.uri.pathSegments.last}').readAsBytesSync());
      expect(b.readAsStringSync(encoding: latin1).contains('<h1>Halo</h1>'), isFalse, reason: 'encrypted');
    }
    expect(remote.localBackups().first.path, fetched.path);

    // Already here: not fetched again.
    final before = fetched.lastModifiedSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect((await remote.pullLatestBackup())!.lastModifiedSync(), before);

    final noise = Random(1); // does not compress
    // A large file comes over once; after that a small edit does not bring it again. (Only "less than that file": the
    // host may still be copying its starter skills in, whose fonts are a few hundred KB that are new too. The exact
    // bytes are counted in backup_sync_test.dart and agent/test/autobackup.test.mjs.)
    File('${rig.daemon.home.path}/workspace/site/big.bin').writeAsBytesSync(List.generate(1024 * 1024, (_) => noise.nextInt(256)));
    await remote.backupNow(force: true);
    expect(remote.lastPull!.bytes, greaterThan(1000 * 1000), reason: 'the new file came over');
    File('${rig.daemon.home.path}/workspace/site/index.html').writeAsStringSync('<h1>Halo lagi</h1>');
    final third = await remote.backupNow(force: true);
    final whole = ((remote.autoBackup!['backups'] as List).first as Map)['size'] as int;
    expect(whole, greaterThan(1000 * 1000), reason: 'the backup is the whole tree');
    expect(remote.lastPull!.bytes, lessThan(1000 * 1000), reason: 'the changed files only, not the 1 MB again (${remote.lastPull!.bytes} of $whole bytes)');
    expect(remote.localBackups().first.path, third!.path);
    expect(remote.localBackups().length, 3, reason: 'the newest three are kept');

    // Off: the server's copies go, the phone keeps its own and the key.
    await remote.setAutoBackup(false);
    expect(remote.autoBackup!['backups'], isEmpty);
    expect(remote.localBackups(), isNotEmpty);
    expect(remote.profile!.backupKey, key);
    // A restore needs the phone's own agent.
    await expectLater(remote.restoreOnPhone(fetched), throwsA(isA<AgentError>()));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
