import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'agent_client.dart';
import 'agent_controller.dart';
import 'agent_fs.dart';
import 'msg.dart';
import 'port_forward.dart';
import 'remote_fs.dart';
import 'remote_profile.dart';

/// Which agent the app uses: the one on this phone, or the one on the user's own server. Owns the saved server, the
/// key, the ssh files, putting the host on the server, and switching between the two.
///
/// Adapted from CoderRa's server mode (seseegy/coderra lib/agent/remote_mode.dart); files and previews over the link
/// come in later phases (server_agent.md).
class RemoteMode extends ChangeNotifier {
  RemoteMode(this.agent);

  final AgentController agent;

  RemoteSetup? setup;
  RemoteProfileStore? store;
  RemoteProfile? profile;
  Map<String, String> env = const {};

  /// The agent bundle on this phone (the same files the phone's own agent runs), copied to the server by [install].
  String? hostDir;

  /// The phone's own folder for files fetched from the server (to share, save or open them on the phone).
  Directory? phoneCache;

  PortForwards? _forwards;

  /// The ports of the server that are reachable from this phone while the server is in use.
  PortForwards? get forwards {
    final s = setup;
    if (s == null || !active) return null;
    return _forwards ??= PortForwards(setup: s, env: env);
  }

  /// Where a dev server on the server's [port] can be opened on this phone, or null if there is no server agent in use.
  Future<String?> devServerUrl(int port) async {
    final f = forwards;
    if (f == null) return null;
    return 'http://127.0.0.1:${await f.open(port)}/';
  }

  /// A URL the phone can open for the web page [path] on the server (and the files next to it): the host serves the
  /// folder (`preview_serve`), and the app reaches it through a forward. [root] is the folder to serve when it contains
  /// [path] (the project, so `../style.css` from a subfolder works); otherwise the page's own folder.
  Future<String?> previewUrl(String path, {String? root}) async {
    final f = forwards;
    if (f == null) return null;
    final base = (root != null && path.startsWith(root.endsWith('/') ? root : '$root/')) ? root : parentPath(path);
    final served = (await agent.client.call<Map>('preview_serve', {'dir': base})).cast<String, dynamic>();
    final local = await f.open(served['port'] as int);
    final rel = path.substring(base.length).split('/').where((p) => p.isNotEmpty).map(Uri.encodeComponent).join('/');
    return 'http://127.0.0.1:$local/${served['token']}/$rel';
  }

  /// Whether the app is set to use the server.
  bool get active => profile?.active == true;

  /// Whether a server has been set up (used or not).
  bool get configured => profile != null;

  /// Reads the saved server and tells the client how to reach it. Call before the first boot.
  Future<void> load() async {
    try {
      env = await agent.client.environment();
    } catch (_) {
      return; // no platform (desktop run, tests): the phone's agent
    }
    final home = env['HOME'];
    if (home == null) return;
    final bin = '${env['PI_CODING_AGENT_DIR']}/bin';
    configure(
      setup: RemoteSetup(home: home, ssh: '$bin/ssh', sshKeygen: '$bin/ssh-keygen', rsync: '$bin/rsync'),
      store: RemoteProfileStore(File('$home/.griphub/remote.json')),
      hostDir: env['GRIPHUB_FILES'] == null ? null : '${env['GRIPHUB_FILES']}/agent',
      phoneCache: Directory('$home/.cache/griphub-remote'),
    );
  }

  /// Sets the pieces up by hand (the tests do this). Applies the saved choice.
  void configure({
    required RemoteSetup setup,
    required RemoteProfileStore store,
    String? hostDir,
    Directory? phoneCache,
  }) {
    this.setup = setup;
    this.store = store;
    this.hostDir = hostDir;
    this.phoneCache = phoneCache ?? Directory('${setup.home}/.cache/griphub-remote');
    profile = store.load();
    _apply();
    notifyListeners();
  }

  Map<String, String>? get _env => env.isEmpty ? null : env;

  /// The app's public key for the server, made on first use.
  Future<String> publicKey() => setup!.ensureKey(env: _env);

  /// The command the user runs on their server, next to the setup script.
  Future<String> bootstrapCommand({String? address}) async =>
      setup!.bootstrapCommand(await publicKey(), address: address);

  String? _localStamp;
  String? _stampDir;

  /// The `.stamp` of the agent bundle this app carries (null without one). Read once per bundle folder.
  String? get localStamp {
    if (_stampDir != hostDir || _stampDir == null) {
      _stampDir = hostDir;
      final dir = hostDir;
      try {
        _localStamp = dir == null ? null : File('$dir/.stamp').readAsStringSync().trim();
      } catch (_) {
        _localStamp = null;
      }
    }
    return _localStamp;
  }

  /// Whether the agent on the server is another version than the one this app carries: the server names the bundle it
  /// came from when the link comes up (`hello_server.bundleStamp`; older hosts do not, and count as other). Null when it
  /// cannot be told (not on a server, not connected yet, no bundle here).
  bool? get serverOutdated {
    if (!active) return null;
    final hello = agent.client.serverHello;
    final local = localStamp;
    if (hello == null || local == null || local.isEmpty) return null;
    return (hello['bundleStamp'] as String?)?.trim() != local;
  }

  /// The setup script this app carries (the server/ folder in one file, built into the agent bundle), or null when
  /// the bundle has none.
  File? get setupScript {
    final dir = hostDir;
    if (dir == null) return null;
    final f = File('$dir/server/${RemoteSetup.setupFileName}');
    return f.existsSync() ? f : null;
  }

  /// Everything the server needs, as one paste for its terminal: the setup script and the command that runs it. Null
  /// when this app carries no setup script.
  Future<String?> setupPaste({String? address}) async {
    final script = setupScript;
    if (script == null) return null;
    return RemoteSetup.setupPaste(await script.readAsString(), await bootstrapCommand(address: address));
  }

  /// Reads a pasted setup code and keeps the server, not in use yet: it is tested and has the agent installed before
  /// the app switches to it. A server that was in use is let go (the app goes back to the agent on this phone), so the
  /// chat never talks to the old server while the terminal and files already go to the new one. Throws
  /// [FormatException] ([SetupCodeError]) with the reason.
  RemoteProfile saveCode(String text) {
    final saved = RemoteProfile.fromSetupCode(SetupCode.parse(text));
    final wasActive = active;
    setup!.write(saved);
    store!.save(saved);
    profile = saved;
    _apply();
    notifyListeners();
    if (wasActive) unawaited(agent.restart());
    return saved;
  }

  Future<ServerCheck> test() => setup!.check(profile!, env: _env);

  /// Whether the agent on the server is the one this app carries (`.stamp` of the bundle). Null when it cannot tell.
  Future<bool?> upToDate() async {
    final dir = hostDir;
    if (dir == null || profile == null) return null;
    final local = File('$dir/.stamp');
    if (!local.existsSync()) return null;
    final remote = await setup!.remoteStamp(env: _env);
    if (remote == null) return false;
    return remote.trim() == local.readAsStringSync().trim();
  }

  /// Copies the agent to the server and starts it with the new files. A server agent the app is connected to is asked
  /// to restart itself once the chat, subagents and background runs are done (`host_restart`), so nothing is cut off;
  /// otherwise the service is restarted at once.
  Future<InstallResult> install({void Function(String line)? onProgress}) async {
    final dir = hostDir;
    if (dir == null) {
      return const InstallResult(ok: false, says: [Msg('This app does not have an agent bundle to copy.')]);
    }
    final client = agent.client;
    final connected = active && client.isRemote && client.connection.value.connected;
    final copied = await setup!.install(dir, env: _env, onProgress: onProgress, restart: !connected);
    if (!copied.ok || !connected) return copied;
    try {
      final r = (await client.call<Map>('host_restart', {'whenIdle': true})).cast<String, dynamic>();
      if (r['restarting'] == true) {
        return InstallResult(
          ok: true,
          filesSent: copied.filesSent,
          says: [...copied.says, const Msg('The agent is restarting.')],
        );
      }
      return InstallResult(
        ok: true,
        filesSent: copied.filesSent,
        says: [
          ...copied.says,
          const Msg('The agent restarts with the new version once it is done with the current work.'),
        ],
      );
    } catch (e) {
      return InstallResult(
        ok: false,
        filesSent: copied.filesSent,
        says: [
          ...copied.says,
          Msg('Restarting the agent failed: {error}', {'error': e}),
        ],
      );
    }
  }

  /// Uses the server (true) or this phone (false) from now on, and restarts the connection to match.
  Future<void> use(bool server) async {
    if (profile == null) return;
    if (server == active) return;
    _pullTimer?.cancel();
    // Back on the phone with a backup of the server here: the home screen offers it once the phone's agent is up.
    _offerRestore = !server && profile!.backupKey != null && localBackups().isNotEmpty;
    profile = profile!.copyWith(active: server);
    store!.save(profile!);
    _apply();
    notifyListeners();
    await agent.restart();
  }

  // -------------------------------------------------------------------------
  // Automatic backups (agent/src/autobackup.ts)

  /// What the server said about its automatic backups the last time it was asked; null before that.
  Map<String, dynamic>? autoBackup;

  /// Why fetching the newest backup failed the last time, if it did.
  String? backupPullError;

  /// A backup is being fetched to this phone.
  bool pullingBackup = false;

  Timer? _pullTimer;

  /// Where this phone keeps the server's backups (private to the app; they hold API keys).
  Directory get backupsDir => Directory('${setup!.home}/.griphub/server-backups');

  /// How many fetched backups the phone keeps.
  static const keepBackups = 3;

  /// The server's backups on this phone, newest first.
  List<File> localBackups() {
    if (setup == null || !backupsDir.existsSync()) return const [];
    final files = backupsDir.listSync().whereType<File>().where((f) => RegExp(r'/auto-\d+\.ghb$').hasMatch(f.path)).toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  /// When a backup on this phone was made on the server, from its name.
  static DateTime backupTime(File f) =>
      DateTime.fromMillisecondsSinceEpoch(int.tryParse(RegExp(r'auto-(\d+)\.ghb$').firstMatch(f.path)?[1] ?? '') ?? 0);

  /// Asks the server how its backups stand (only with the server in use).
  Future<Map<String, dynamic>?> refreshAutoBackup() async {
    if (!active) return null;
    autoBackup = (await agent.client.call<Map>('auto_backup_status')).cast<String, dynamic>();
    notifyListeners();
    return autoBackup;
  }

  /// Turns the server's hourly backups on (with a key made here the first time) or off. Off deletes the server's
  /// copies; the ones on this phone stay, and so does their key.
  Future<void> setAutoBackup(bool on) async {
    final p = profile;
    if (p == null || !active) return;
    String? key;
    if (on) {
      key = p.backupKey ?? _newKey();
      if (p.backupKey == null) {
        profile = p.copyWith(backupKey: key);
        store!.save(profile!);
      }
    }
    autoBackup = (await agent.client.call<Map>('auto_backup_configure', {'key': key})).cast<String, dynamic>();
    notifyListeners();
    if (on) unawaited(backupNow().catchError((_) => null));
  }

  /// Makes a backup on the server now (if anything changed since the last one), then fetches it.
  Future<File?> backupNow({bool force = false}) async {
    autoBackup = (await agent.client.call<Map>('auto_backup_now', {'force': force})).cast<String, dynamic>()
      ..remove('made');
    notifyListeners();
    return pullLatestBackup();
  }

  /// The fetch under way: a second asker (the hourly timer, "Back up now") shares it instead of writing the same file.
  Future<File?>? _pull;

  /// Fetches the server's newest backup to this phone unless it is already here; keeps the newest few. Returns it.
  Future<File?> pullLatestBackup({Progress? onProgress, CancelToken? cancel}) {
    if (!active) return Future.value(null);
    return _pull ??= _pullLatest(onProgress: onProgress, cancel: cancel).whenComplete(() => _pull = null);
  }

  Future<File?> _pullLatest({Progress? onProgress, CancelToken? cancel}) async {
    final status = await refreshAutoBackup();
    final list = (status?['backups'] as List? ?? const []).whereType<Map>().toList();
    if (status?['enabled'] != true || list.isEmpty) return null;
    final latest = list.first.cast<String, dynamic>();
    final target = File('${backupsDir.path}/${latest['name']}');
    if (target.existsSync() && target.lengthSync() == (latest['size'] as num?)?.toInt()) return target;
    pullingBackup = true;
    backupPullError = null;
    notifyListeners();
    try {
      final fetched = await agent.fs.toPhoneFile(latest['path'] as String, onProgress: onProgress, cancel: cancel);
      backupsDir.createSync(recursive: true);
      final part = File('${target.path}.part');
      await File(fetched).copy(part.path);
      await part.rename(target.path);
      // The download cache needs no second copy of it.
      unawaited(File(fetched).delete().then((_) {}, onError: (_) {}));
      for (final old in localBackups().skip(keepBackups)) {
        old.deleteSync();
      }
      return target;
    } catch (e) {
      backupPullError = '$e';
      rethrow;
    } finally {
      pullingBackup = false;
      notifyListeners();
    }
  }

  /// While the server is in use: fetch its newest backup soon after connecting, then every hour the app is open.
  void startBackupPulls() {
    _pullTimer?.cancel();
    if (!active || profile?.backupKey == null) return;
    Future<void> pull() => pullLatestBackup().then((_) {}, onError: (_) {});
    _pullTimer = Timer.periodic(const Duration(hours: 1), (_) => pull());
    Future<void>.delayed(const Duration(seconds: 15), () {
      if (active) pull();
    });
  }

  /// Puts a server backup on the agent on this phone (decrypted there with the key), then restarts it to read it all.
  Future<Map<String, dynamic>> restoreOnPhone(File backup) async {
    final key = profile?.backupKey;
    if (key == null) throw AgentError('This phone has no key for the server\'s backups.');
    if (active) throw AgentError('Switch to the agent on this phone first.');
    final r = (await agent.client.call<Map>('backup_restore_server', {'path': backup.path, 'key': key}))
        .cast<String, dynamic>();
    await agent.restart();
    return r;
  }

  bool _offerRestore = false;

  /// Whether to offer the server's newest backup now (once, after switching back to the phone).
  bool takeRestoreOffer() {
    final offer = _offerRestore && !active;
    _offerRestore = false;
    return offer;
  }

  static String _newKey() {
    final r = Random.secure();
    return [for (var i = 0; i < 32; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  /// Forgets the server: stops using it, deletes the ssh files and the key.
  Future<void> forget() async {
    _pullTimer?.cancel();
    final wasActive = active;
    profile = null;
    store!.clear();
    setup!
      ..remove()
      ..forgetKey();
    _apply();
    notifyListeners();
    if (wasActive) await agent.restart();
  }

  void _apply() {
    // Forwards belong to the server they were opened for.
    final old = _forwards;
    _forwards = null;
    if (old != null) unawaited(old.closeAll());
    final p = profile;
    final s = setup;
    final client = agent.client;
    if (p != null && p.active && s != null) {
      client.remote = s.launch(p, env: env);
      agent.fs = RemoteFs(client.call, phoneCache: phoneCache!, waitOnline: client.whenConnected);
    } else {
      client.remote = null;
      agent.fs = const LocalFs();
    }
  }
}
