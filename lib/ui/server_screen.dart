import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_client.dart';
import '../agent/agent_controller.dart';
import '../agent/remote_profile.dart';
import 'backup_screen.dart';
import 'box_screen.dart';
import 'errors.dart';
import 'server_guide.dart';
import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

Color _stateColor(Palette p, Connection c) => switch (c.state) {
  LinkState.connected => p.success,
  LinkState.connecting || LinkState.reconnecting => p.warning,
  LinkState.offline => p.danger,
};

// Adapted from CoderRa's server mode (seseegy/coderra lib/ui/server_screen.dart); see server_agent.md.

/// Which agent this is and whether it can be reached: a small badge for the chat's title bar. Only shown once a server
/// has been set up, so someone who never uses one never sees it.
class ConnectionChip extends StatelessWidget {
  const ConnectionChip({super.key, required this.agent});

  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([agent.remote, agent.client.connection]),
      builder: (context, _) {
        if (!agent.remote.configured) return const SizedBox.shrink();
        final p = context.palette;
        final server = agent.remote.active;
        final c = agent.client.connection.value;
        // Short, so the chat's title and buttons keep their room on a narrow phone; the whole state is in the tooltip
        // and, while the link is down, in the banner under the bar.
        final label = !server
            ? tr('Phone')
            : switch (c.state) {
                LinkState.connected => tr('Server'),
                LinkState.connecting || LinkState.reconnecting => '…',
                LinkState.offline => tr('Offline'),
              };
        final full = !server
            ? tr('The agent on this phone')
            : switch (c.state) {
                LinkState.connected => tr('Connected to the server'),
                LinkState.connecting => tr('Connecting to the server…'),
                LinkState.reconnecting => tr('Reconnecting to the server'),
                LinkState.offline => tr('Not connected to the server'),
              };
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Tooltip(
            message: full,
            child: InkWell(
              borderRadius: BorderRadius.circular(99),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServerScreen(agent: agent))),
              // With very large text on a narrow phone the word would take the title's room: the icon alone, its colour
              // still saying the state (the words are in the tooltip, and read out).
              child: MediaQuery.sizeOf(context).width / MediaQuery.textScalerOf(context).scale(1) < 220
                  ? Semantics(
                      label: full,
                      child: ExcludeSemantics(
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: (server ? _stateColor(p, c) : p.muted).withValues(alpha: 0.12),
                          ),
                          child: Icon(
                            server ? LucideIcons.server : LucideIcons.smartphone,
                            size: 14,
                            color: server ? _stateColor(p, c) : p.muted,
                          ),
                        ),
                      ),
                    )
                  : Pill(
                      label,
                      color: server ? _stateColor(p, c) : p.muted,
                      icon: server ? LucideIcons.server : LucideIcons.smartphone,
                    ),
            ),
          ),
        );
      },
    );
  }
}

/// Shown above the chat while the server cannot be reached: what is happening and a way to hurry it along.
class ConnectionBanner extends StatefulWidget {
  const ConnectionBanner({super.key, required this.agent});

  final AgentController agent;

  @override
  State<ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends State<ConnectionBanner> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // The countdown to the next attempt.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.agent.client.connection.value.retryAt != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;
    return ValueListenableBuilder<Connection>(
      valueListenable: agent.client.connection,
      builder: (context, c, _) {
        if (!agent.client.isRemote || c.connected) return const SizedBox.shrink();
        final p = context.palette;
        final color = _stateColor(p, c);
        final wait = c.retryAt?.difference(DateTime.now());
        final String title;
        final String action;
        if (c.kicked) {
          title = tr('Another device is using the server agent');
          action = tr('Take over');
        } else if (c.state == LinkState.offline) {
          title = tr('Not connected to the server');
          action = tr('Reconnect');
        } else {
          title = c.attempt <= 1 && wait == null
              ? tr('Connecting to the server…')
              : '${tr('Reconnecting to the server')}${wait != null && wait.inSeconds > 0 ? ' · ${tr('{n} s').replaceAll('{n}', '${wait.inSeconds}')}' : '…'}';
          action = tr('Retry');
        }
        return Material(
          color: color.withValues(alpha: 0.12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                if (c.state == LinkState.offline)
                  Icon(LucideIcons.cloudOff, size: 16, color: color)
                else
                  BusySpinner(size: 14, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      if (c.reason != null && c.reason!.trim().isNotEmpty && !c.kicked)
                        Text(
                          c.reason!.trim().split('\n').last,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: p.muted),
                        ),
                      Text(
                        tr('The agent keeps working on the server.'),
                        style: TextStyle(fontSize: 11.5, color: p.muted),
                      ),
                    ],
                  ),
                ),
                TextButton(onPressed: agent.client.reconnectNow, child: Text(action)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Under the chat's connection banner: the agent on the server is not the version this app carries (the app was updated,
/// the server was not), with the update one tap away. The update waits until the agent is done with its work.
class ServerUpdateBanner extends StatefulWidget {
  const ServerUpdateBanner({super.key, required this.agent});

  final AgentController agent;

  @override
  State<ServerUpdateBanner> createState() => _ServerUpdateBannerState();
}

class _ServerUpdateBannerState extends State<ServerUpdateBanner> {
  bool _updating = false;

  /// After an update the host restarts once it is idle; until the new one says hello, the banner says so.
  bool _waiting = false;

  Future<void> _update() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _updating = true);
    try {
      final r = await widget.agent.remote.install();
      if (!mounted) return;
      setState(() => _waiting = r.ok);
      messenger.showSnackBar(SnackBar(content: Text(trMsgs(r.says))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;
    return ListenableBuilder(
      listenable: Listenable.merge([agent.client.connection, agent.remote]),
      builder: (context, _) {
        if (!agent.client.connection.value.connected || agent.remote.serverOutdated != true) {
          _waiting = false;
          return const SizedBox.shrink();
        }
        final p = context.palette;
        return Material(
          color: p.accent.withValues(alpha: 0.10),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
            child: Row(
              children: [
                Icon(LucideIcons.circleArrowUp, size: 16, color: p.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _waiting
                        ? tr('The server agent updates once it finishes its current work.')
                        : tr('The agent on the server is not the version this app carries.'),
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                if (_updating)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: BusySpinner(),
                  )
                else if (!_waiting)
                  TextButton(onPressed: _update, child: Text(tr('Update'))),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The app opened on a server it could not reach (the phone offline, the server down): unlike a link that drops later
/// there is nothing to show yet. Says why in plain words, tries again on its own with the banner's backoff, and keeps
/// the raw output under Details. The server settings and the agent on this phone are one tap away.
class ServerBootFailed extends StatefulWidget {
  const ServerBootFailed({super.key, required this.agent});

  final AgentController agent;

  @override
  State<ServerBootFailed> createState() => _ServerBootFailedState();
}

class _ServerBootFailedState extends State<ServerBootFailed> {
  late final DateTime _retryAt;
  Timer? _tick;

  AgentController get agent => widget.agent;

  @override
  void initState() {
    super.initState();
    _retryAt = DateTime.now().add(agent.client.backoff(agent.bootFailures));
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!DateTime.now().isBefore(_retryAt)) {
        _retry();
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _retry() {
    _tick?.cancel();
    agent.boot();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final raw = agent.bootError ?? '';
    final profile = agent.remote.profile;
    final setup = agent.remote.setup;
    final why = profile != null && setup != null
        ? trMsg(setup.classify(profile, 255, '', raw).say)
        : tr('Could not reach the server agent');
    final wait = (_retryAt.difference(DateTime.now()).inMilliseconds / 1000).ceil();
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 24),
            Icon(LucideIcons.cloudOff, size: 36, color: p.warning),
            const SizedBox(height: 14),
            Text(tr('Could not reach the server agent'), style: text.headlineSmall),
            const SizedBox(height: 10),
            Text(why, style: text.bodyMedium),
            const SizedBox(height: 10),
            Text(tr('The agent keeps working on the server.'), style: text.bodySmall?.copyWith(color: p.muted)),
            const SizedBox(height: 18),
            Row(
              children: [
                BusySpinner(size: 14, color: p.warning),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tr('Trying again in {n} s').replaceAll('{n}', '${wait < 1 ? 1 : wait}'),
                    style: text.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _retry, child: Text(tr('Try now'))),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => ServerScreen(agent: agent))),
              child: Text(tr('Server agent settings')),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => agent.remote.use(false), child: Text(tr('Use the agent on this phone'))),
            if (raw.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(tr('Details'), style: text.titleSmall),
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: p.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: p.border),
                      ),
                      child: SelectableText(
                        raw.trim(),
                        style: TextStyle(fontFamily: mono, fontSize: 11.5, height: 1.5, color: p.text),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Set up, check, install and switch to the agent on the user's server.
class ServerScreen extends StatefulWidget {
  const ServerScreen({super.key, required this.agent});

  final AgentController agent;

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> {
  AgentController get agent => widget.agent;
  final address = TextEditingController();
  final code = TextEditingController();
  final topic = TextEditingController();
  final ntfyUrl = TextEditingController(text: 'https://ntfy.sh');
  String? command;
  String? codeError;
  String? setupError;
  ServerCheck? checked;
  bool testing = false;
  bool installing = false;
  String? installNote;
  bool? installOk;
  Map<String, dynamic>? health;
  bool changingServer = false;

  /// Whether the agent on the server is the one this app carries; null until known.
  bool? upToDate;

  @override
  void initState() {
    super.initState();
    _loadCommand();
    agent.client.connection.addListener(_onLink);
    _loadHealth();
    _checkVersion();
    // A saved server not in use yet: test it at once, so the next step (install, or switch) is plain.
    if (agent.remote.configured && !agent.remote.active) _test();
  }

  Future<void> _checkVersion() async {
    if (!agent.remote.configured) return;
    try {
      final v = await agent.remote.upToDate();
      if (mounted) setState(() => upToDate = v);
    } catch (_) {}
  }

  @override
  void dispose() {
    agent.client.connection.removeListener(_onLink);
    for (final c in [address, code, topic, ntfyUrl]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onLink() {
    if (agent.client.connection.value.connected) _loadHealth();
    if (mounted) setState(() {});
  }

  Future<void> _loadCommand() async {
    if (agent.remote.setup == null) return;
    try {
      final c = await agent.remote.bootstrapCommand(address: address.text.trim());
      if (mounted) setState(() => command = c);
    } catch (e) {
      if (mounted) setState(() => setupError = friendlyError(e));
    }
  }

  Future<void> _loadHealth() async {
    if (!agent.remote.active || !agent.client.connection.value.connected) return;
    try {
      final h = (await agent.client.call<Map>('health')).cast<String, dynamic>();
      final s = await agent.integrations.refreshSettings();
      if (!mounted) return;
      setState(() {
        health = h;
        // Not set up yet: a fresh secret topic is ready, so Save is the only step.
        topic.text = s.notifyTopic ?? (topic.text.isEmpty ? _newTopic() : topic.text);
        ntfyUrl.text = s.notifyUrl;
      });
    } catch (_) {}
  }

  void _saveCode() {
    try {
      agent.remote.saveCode(code.text);
      setState(() {
        codeError = null;
        code.clear();
        changingServer = false;
        checked = null;
        installOk = null;
        upToDate = null;
        health = null;
      });
      // Straight on to step 3: whether the app gets in, and whether the agent is there yet.
      _test();
      _checkVersion();
    } on SetupCodeError catch (e) {
      setState(() => codeError = trMsg(e.say));
    } on FormatException catch (e) {
      setState(() => codeError = e.message);
    }
  }

  Future<void> _test() async {
    setState(() {
      testing = true;
      checked = null;
    });
    final r = await agent.remote.test();
    if (mounted) {
      setState(() {
        testing = false;
        checked = r;
      });
    }
  }

  Future<void> _install() async {
    setState(() {
      installing = true;
      installOk = null;
      installNote = tr('Preparing…');
    });
    final r = await agent.remote.install(onProgress: (l) => mounted ? setState(() => installNote = tr(l)) : null);
    if (!mounted) return;
    setState(() {
      installing = false;
      installOk = r.ok;
      installNote = trMsgs(r.says);
    });
    if (r.ok) {
      unawaited(_test());
      unawaited(_checkVersion());
    }
  }

  Future<void> _use(bool server) async {
    if (server) {
      // Whatever the agent on this phone is doing stops with the switch.
      final working = agent.working;
      final text = Theme.of(context).textTheme;
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) {
          final p = context.palette;
          return AlertDialog(
            title: Text(tr('Use the server agent?')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (working) ...[
                    Text(
                      tr('The agent on this phone is working. Switching now stops it.'),
                      style: TextStyle(color: p.danger, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 10),
                  ],
                  Text(
                    tr(
                      'Chats, files and projects will be the ones on your server. The ones on this phone stay here, untouched, and come back when you switch back.',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    tr(
                      'Models, API keys and accounts (GitHub, Cloudflare…) are not on the server: connect them again there. To take chats along, make a backup on this phone first and restore it on the server (Settings > Backup & restore).',
                    ),
                    style: text.bodySmall,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      icon: const Icon(LucideIcons.archive, size: 16),
                      label: Text(tr('Back up this phone first')),
                      onPressed: () {
                        Navigator.pop(context, false);
                        Navigator.of(
                          this.context,
                        ).push(MaterialPageRoute(builder: (_) => BackupScreen(agent: agent)));
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
              FilledButton(
                style: working
                    ? FilledButton.styleFrom(backgroundColor: p.danger, foregroundColor: Colors.white)
                    : null,
                onPressed: () => Navigator.pop(context, true),
                child: Text(tr(working ? 'Stop and switch' : 'Use the server')),
              ),
            ],
          );
        },
      );
      if (ok != true) return;
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('Use the agent on this phone?')),
          content: Text(
            tr(
              'The agent on the server keeps running: schedules, background tasks and notifications go on. What it asks you to approve shows again when you switch back to it. The chats on this phone come back.',
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Use this phone'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    await agent.remote.use(server);
    if (mounted) {
      setState(() => health = null);
      _loadHealth();
    }
  }

  Future<void> _forget() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Forget this server?')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('The app deletes its key for the server and the saved address. Nothing on the server is touched.'),
              ),
              const SizedBox(height: 10),
              Text(
                tr(
                  'The agent on the server keeps running, with its schedules and notifications, and the app goes back to the agent on this phone. To connect again, run the setup command on the server again.',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  icon: const Icon(LucideIcons.copy, size: 16),
                  label: Text(tr('Copy the commands that remove it from the server')),
                  onPressed: () => _copy(removeCommands, tr('removal commands')),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Forget'))),
        ],
      ),
    );
    if (ok == true) {
      await agent.remote.forget();
      _loadCommand();
      if (mounted) setState(() => checked = null);
    }
  }

  /// Saves the server and topic; saving them turns notifications on (the switch below turns them off again).
  Future<void> _saveNotify({bool? enabled}) async {
    try {
      await agent.integrations.updateSettings({
        'notify': {
          'enabled': enabled ?? true,
          'url': ntfyUrl.text.trim(),
          'topic': topic.text.trim(),
        },
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Notifications saved'))));
    } on AgentError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
    if (mounted) setState(() {});
  }

  /// What server/README.md ("Menghapus") says to run as root to take the agent off the server: everything of it goes,
  /// chats and the workspace too.
  static const removeCommands =
      '# Removes the GripHub agent and everything of it (chats, ~/workspace, the box). Make a backup first.\n'
      'runuser -u griphub -- env XDG_RUNTIME_DIR=/run/user/\$(id -u griphub) systemctl --user disable --now griphub-hostd\n'
      'loginctl disable-linger griphub\n'
      'userdel -r griphub\n';

  bool _testingNotify = false;

  Future<void> _testNotify() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _testingNotify = true);
    String said;
    try {
      final r = (await agent.client.call<Map>('notify_test')).cast<String, dynamic>();
      final detail = r['detail'] as String?;
      said = switch (r['ok'] == true ? 'ok' : r['reason']) {
        'ok' => tr('Sent. It should arrive in a few seconds; if not, check the topic in the ntfy app.'),
        'off' => tr('Notifications are off. Save the topic first.'),
        'config' => '${tr('The settings are not usable:')} ${tr(detail ?? '')}',
        'http' => tr('The ntfy server refused it (status {status}).').replaceAll('{status}', detail ?? '?'),
        _ => '${tr('The server could not reach ntfy:')} ${detail ?? ''}',
      };
    } on AgentError catch (e) {
      said = tr(e.message);
    }
    if (!mounted) return;
    setState(() => _testingNotify = false);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(said)));
  }

  /// Opens the topic in the ntfy app (subscribing to it there), or on the web without the app.
  Future<void> _openNtfy() async {
    final base = Uri.tryParse(ntfyUrl.text.trim());
    final t = topic.text.trim();
    if (base == null || t.isEmpty) return;
    final host = base.host.isEmpty ? 'ntfy.sh' : base.host;
    try {
      await agent.client.openUrl('ntfy://$host/$t');
    } catch (_) {
      await agent.client.openUrl('${ntfyUrl.text.trim().replaceAll(RegExp(r'/+$'), '')}/$t');
    }
  }

  static String _newTopic() {
    final r = Random.secure();
    return 'griphub-${List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }

  /// Sends the setup script to another app (an SFTP client, say), to put it on the server that way.
  Future<void> _shareSetup() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await agent.client.shareFile(agent.remote.setupScript!.path);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  /// Copies the setup script and the command that runs it as one paste for the server's terminal.
  Future<void> _copySetup() async {
    try {
      final paste = await agent.remote.setupPaste(address: address.text.trim());
      if (paste != null) await _copy(paste, tr('setup command'));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('Copied')}: $what')));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([agent.remote, agent.integrations]),
      builder: (context, _) {
        final mode = agent.remote;
        final profile = mode.profile;
        final link = agent.client.connection.value;
        return Scaffold(
          appBar: AppBar(
            title: Text(tr('Server agent')),
            actions: [
              IconButton(
                tooltip: tr('Server guide'),
                icon: const Icon(LucideIcons.bookOpen, size: 20),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ServerGuideScreen())),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
            children: [
              SurfaceCard(
                child: Row(
                  children: [
                    IconTile(icon: mode.active ? LucideIcons.server : LucideIcons.smartphone, color: p.accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            mode.active ? tr('Your server runs the agent') : tr('This phone runs the agent'),
                            style: text.titleSmall,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            mode.active
                                ? tr('It keeps working when the app is closed or the phone is off.')
                                : tr('Set up a server to let the agent work around the clock.'),
                            style: text.bodySmall,
                          ),
                          // Under the text, not beside it: a narrow phone keeps whole words in the title.
                          if (mode.active) ...[
                            const SizedBox(height: 8),
                            Pill(
                              switch (link.state) {
                                LinkState.connected => tr('Connected'),
                                LinkState.connecting => tr('Connecting…'),
                                LinkState.reconnecting => tr('Reconnecting'),
                                LinkState.offline => link.kicked ? tr('Another device') : tr('Offline'),
                              },
                              color: _stateColor(p, link),
                              dot: true,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (mode.active && !link.connected && link.reason != null && profile != null && mode.setup != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: _Result(
                    ok: false,
                    message: trMsg(mode.setup!.classify(profile, 255, '', link.reason!).say),
                    detail: link.reason,
                  ),
                ),
              if (mode.active && health != null) _healthCard(context, health!),
              if (mode.active && link.connected && health != null) _checklist(context),
              if (profile == null || changingServer) ..._setup(context),
              if (profile != null) ..._server(context, profile),
              if (mode.active && link.connected && agent.integrations.settings != null) ..._notifications(context),
              ..._help(context),
            ],
          ),
        );
      },
    );
  }

  Widget _healthCard(BuildContext context, Map<String, dynamic> h) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    String gb(num? bytes) => bytes == null ? '?' : '${localNumber((bytes / (1 << 30)).toStringAsFixed(1))} GB';
    final disk = (h['disk'] as Map?)?.cast<String, dynamic>() ?? const {};
    final mem = (h['memory'] as Map?)?.cast<String, dynamic>() ?? const {};
    final runs = (h['runs'] as Map?)?.cast<String, dynamic>() ?? const {};
    final uptime = Duration(seconds: (h['uptimeSec'] as num?)?.toInt() ?? 0);
    final low = disk['level'] != null && disk['level'] != 'ok';
    final memoryHigh = mem['level'] != null && mem['level'] != 'ok';
    // Where the agent's commands run. A box without an image refuses them all, so that is said, with the way out.
    final box = (h['box'] as Map?)?.cast<String, dynamic>();
    final boxMissing = box != null && box['available'] == true && box['installed'] != true;
    final boxText = box == null
        ? null
        : box['available'] != true
        ? tr('none · commands run on the server')
        : box['installed'] != true
        ? tr('not built · commands are refused')
        : box['enabled'] == true
        ? tr('ready · commands run inside it')
        : tr('off · commands run on the server');
    final rows = <(String, String, Color?)>[
      // A copied update waits for the chat, subagents and runs to end before the agent restarts: say so, because the files
      // on the server are already the new ones while the process still runs the old.
      if (h['restartPending'] == true)
        (tr('Agent version'), tr('Update copied · restarts when the current work is done'), p.warning)
      else if (upToDate != null)
        (tr('Agent version'), upToDate! ? tr('Up to date') : tr('A newer one is in this app'), upToDate! ? null : p.warning),
      (tr('Disk free'), '${gb(disk['freeBytes'] as num?)} ${tr('of')} ${gb(disk['totalBytes'] as num?)}', low ? p.warning : null),
      (tr('Agent memory'), gb(mem['rssBytes'] as num?), memoryHigh ? p.warning : null),
      (tr('Running'), '${runs['running'] ?? 0} · ${tr('queued')} ${runs['queued'] ?? 0}', null),
      (tr('Subagents'), h['subagents'] == true ? tr('working') : tr('not active'), null),
      (tr('Up for'), _upFor(uptime), null),
      (tr('Node'), '${h['node'] ?? '?'}', null),
      if (boxText != null) (tr('Box'), boxText, boxMissing ? p.warning : null),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('Server health'), style: text.titleSmall),
            const SizedBox(height: 8),
            // Two columns, so a value that needs a second line wraps under itself, not under its name.
            Table(
              columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              children: [
                for (final (name, value, color) in rows)
                  TableRow(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 14, top: 3, bottom: 3),
                        child: Text(name, style: text.bodySmall?.copyWith(color: p.muted)),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(
                          value,
                          style: text.bodySmall?.copyWith(color: color ?? p.text, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            if (boxMissing)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('The agent cannot run commands until the box is built.'),
                      style: TextStyle(color: p.warning, fontSize: 12.5),
                    ),
                    TextButton.icon(
                      icon: const Icon(LucideIcons.hammer, size: 16),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                      onPressed: () => Navigator.of(
                        context,
                      ).push(MaterialPageRoute(builder: (_) => BoxScreen(agent: agent))).then((_) => _loadHealth()),
                      label: Text(tr('Build the box')),
                    ),
                  ],
                ),
              ),
            if (low)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  disk['level'] == 'critical'
                      ? tr('The disk is almost full. New work is refused until space is freed.')
                      : tr('Disk space is getting low.'),
                  style: TextStyle(color: p.warning, fontSize: 12.5),
                ),
              ),
            if (memoryHigh)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  tr('The agent is using a lot of memory. Fewer subagents at once, or a restart, frees it.'),
                  style: TextStyle(color: p.warning, fontSize: 12.5),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// "2 h 5 min" / "2 j 5 mnt", or minutes alone under an hour.
  static String _upFor(Duration d) {
    final id = Appearance.instance.language == 'id';
    if (d.inHours >= 24) return id ? '${d.inDays} hr ${d.inHours % 24} j' : '${d.inDays} d ${d.inHours % 24} h';
    if (d.inHours >= 1) return id ? '${d.inHours} j ${d.inMinutes % 60} mnt' : '${d.inHours} h ${d.inMinutes % 60} min';
    return id ? '${d.inMinutes} mnt' : '${d.inMinutes} min';
  }

  List<Widget> _setup(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return [
      SectionLabel(tr('1 · Set up the server')),
      Text(
        tr(
          agent.remote.setupScript != null
              ? 'On the server (Ubuntu or Debian), as root or an account with sudo: paste the setup command into its terminal. It carries the setup files and this app\'s key; nothing has to be downloaded.'
              : 'On the server (Ubuntu or Debian) run bootstrap.sh from the server/ folder of the GripHub repository, as root, with this app\'s key:',
        ),
        style: text.bodySmall,
      ),
      const SizedBox(height: 10),
      TextField(
        controller: address,
        autocorrect: false,
        keyboardType: TextInputType.url,
        style: const TextStyle(fontFamily: mono, fontSize: 13.5),
        decoration: InputDecoration(
          labelText: tr('Server address (name or IP)'),
          hintText: 'agent.example.com',
          helperText: tr('Needed: the address this phone reaches the server at.'),
          helperMaxLines: 2,
        ),
        onChanged: (_) {
          setState(() {});
          _loadCommand();
        },
      ),
      const SizedBox(height: 10),
      if (command == null && setupError == null)
        const Center(child: BusySpinner(size: 18))
      else if (setupError != null)
        Text(setupError!, style: TextStyle(color: p.danger))
      else ...[
        // With the setup file in the app, this line is what the paste ends with; copying it alone would fail on a
        // server that does not have the file yet, so only the full paste is copied (the button below).
        if (agent.remote.setupScript != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(tr('What the paste runs at the end'), style: text.labelMedium),
          ),
        Container(
          padding: EdgeInsets.fromLTRB(12, 10, agent.remote.setupScript != null ? 12 : 4, 10),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: p.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  command!,
                  style: TextStyle(fontFamily: mono, fontSize: 12, color: p.text),
                ),
              ),
              if (agent.remote.setupScript == null)
                IconButton(
                  tooltip: tr('Copy'),
                  icon: const Icon(LucideIcons.copy, size: 18),
                  onPressed: () => _copy(command!, tr('command')),
                ),
            ],
          ),
        ),
      ],
      if (command != null && agent.remote.setupScript != null) ...[
        const SizedBox(height: 10),
        PrimaryButton(
          label: tr('Copy setup command'),
          icon: LucideIcons.clipboardCopy,
          onPressed: address.text.trim().isEmpty ? null : _copySetup,
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: address.text.trim().isEmpty ? null : _shareSetup,
            icon: const Icon(LucideIcons.share2, size: 16),
            label: Text(tr('Share the setup file instead')),
          ),
        ),
        Text(
          tr(
            'The setup command is the setup file and that line in one paste. Or send the file to the server (for example with an SFTP app) and run that line next to it.',
          ),
          style: text.bodySmall,
        ),
      ],
      SectionLabel(tr('2 · Paste the setup code')),
      Text(
        tr('The script prints it at the end. The app trusts exactly that server and nothing that only looks like it.'),
        style: text.bodySmall,
      ),
      const SizedBox(height: 10),
      TextField(
        controller: code,
        autocorrect: false,
        enableSuggestions: false,
        minLines: 2,
        maxLines: 5,
        style: const TextStyle(fontFamily: mono, fontSize: 12.5),
        decoration: InputDecoration(
          labelText: tr('Setup code'),
          hintText: 'griphub1:…',
          errorText: codeError,
          errorMaxLines: 4,
        ),
        onChanged: (_) {
          if (codeError != null) setState(() => codeError = null);
        },
      ),
      const SizedBox(height: 10),
      if (changingServer && agent.remote.active)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            tr(
              'Saving goes back to the agent on this phone until the new server is tested and switched on. The current server keeps its chats and keeps running.',
            ),
            style: text.bodySmall?.copyWith(color: p.warning),
          ),
        ),
      Row(
        children: [
          Expanded(
            child: PrimaryButton(label: tr('Save server'), icon: LucideIcons.check, onPressed: _saveCode),
          ),
          if (changingServer)
            TextButton(onPressed: () => setState(() => changingServer = false), child: Text(tr('Cancel'))),
        ],
      ),
    ];
  }

  List<Widget> _server(BuildContext context, RemoteProfile profile) {
    final p = context.palette;
    final mode = agent.remote;
    // Until the server is in use the rows are the next steps of the setup, in order; switching waits for a test that
    // found the agent running there.
    String step(int n, String title) => mode.active ? title : '$n · $title';
    final ready = mode.active || checked?.ok == true;
    return [
      SectionLabel(tr('Server')),
      SettingsGroup(
        children: [
          SettingsRow(
            icon: LucideIcons.globe,
            color: p.accent,
            title: profile.address,
            subtitle: '${tr('user')} ${profile.user}',
          ),
          SettingsRow(
            icon: LucideIcons.fingerprint,
            color: p.muted,
            title: tr('Host key'),
            subtitle:
                '${profile.hostKey.split(' ').first} · …${profile.hostKey.substring(profile.hostKey.length - 12)}',
            trailing: IconButton(
              icon: const Icon(LucideIcons.copy, size: 18),
              tooltip: tr('Copy'),
              onPressed: () => _copy(profile.hostKey, tr('host key')),
            ),
          ),
          SettingsRow(
            icon: LucideIcons.plugZap,
            color: p.accent,
            title: step(3, tr('Test connection')),
            subtitle: testing ? tr('Connecting…') : tr('Checks the key, the host key and the agent'),
            trailing: testing
                // The subtitle already says "Connecting…".
                ? const BusySpinner(semanticsLabel: '')
                : null,
            onTap: testing ? null : _test,
          ),
          SettingsRow(
            icon: LucideIcons.download,
            color: p.accent,
            title: step(4, tr('Install / update agent')),
            subtitle: installing
                ? (installNote ?? '')
                : upToDate == false
                ? tr('A newer agent is in this app: install it on the server')
                : tr('Copies the agent, then restarts it when idle'),
            trailing: installing
                ? const BusySpinner()
                : null,
            onTap: installing ? null : _install,
          ),
        ],
      ),
      if (checked != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: _Result(
            ok: checked!.ok,
            // Reached, with the agent still to install: the next step, not a failure.
            next: checked!.problem == ServerProblem.hostMissing,
            message: trMsg(checked!.say),
            detail: checked!.detail,
          ),
        ),
      if (installOk != null && !installing)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: _Result(ok: installOk!, message: installNote ?? ''),
        ),
      const SizedBox(height: 12),
      SettingsGroup(
        children: [
          SettingsRow(
            icon: LucideIcons.server,
            color: p.accent,
            title: step(5, tr('Use the server agent')),
            subtitle: mode.active
                ? tr('Chats and files are the server\'s')
                : ready
                ? tr('Chats and files are on this phone')
                : tr('Test the connection and install the agent first'),
            trailing: LabeledSwitch(label: tr('Use the server agent'), value: mode.active, onChanged: ready ? _use : null),
            onTap: ready ? () => _use(!mode.active) : null,
          ),
          SettingsRow(
            icon: LucideIcons.refreshCw,
            color: p.muted,
            title: tr('Use a different server'),
            onTap: () => setState(() {
              changingServer = true;
              _loadCommand();
            }),
          ),
          SettingsRow(
            icon: LucideIcons.trash2,
            color: p.danger,
            title: tr('Forget this server'),
            destructive: true,
            onTap: _forget,
          ),
        ],
      ),
    ];
  }

  /// Is everything in place? One look at what makes the server agent useful, each with its way to fix it.
  Widget _checklist(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final h = health!;
    final box = (h['box'] as Map?)?.cast<String, dynamic>();
    final settings = agent.integrations.settings;
    final items = <(bool, String, String?)>[
      (true, tr('This phone reaches the server'), null),
      if (upToDate != null)
        (upToDate!, tr('The agent on the server is this app\'s version'), tr('Press Install / update agent.')),
      if (box != null && box['available'] == true)
        (box['installed'] == true, tr('The box is built'), tr('Build it: Settings > The agent\'s box.')),
      (
        agent.providers.any((x) => x.configured),
        tr('A model is connected on the server'),
        tr('The server keeps its own keys: connect one in Settings > Models & providers.'),
      ),
      (
        settings?.notifyTopic != null && settings!.notifyEnabled,
        tr('Notifications reach this phone'),
        tr('Save a topic below, then send a test notification.'),
      ),
    ];
    final done = items.where((i) => i.$1).length;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(tr('Checklist'), style: text.titleSmall)),
                Text(
                  tr('{done} of {all} ready').replaceAll('{done}', '$done').replaceAll('{all}', '${items.length}'),
                  style: text.bodySmall?.copyWith(color: done == items.length ? p.success : p.warning),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final (ok, what, fix) in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      ok ? LucideIcons.circleCheck : LucideIcons.circleDashed,
                      size: 18,
                      color: ok ? p.success : p.warning,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(what, style: text.bodyMedium),
                          if (!ok && fix != null) Text(fix, style: text.bodySmall),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// What to do when something goes wrong (server_guide.dart), with the whole guide one tap away.
  List<Widget> _help(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final entries = serverTroubleshooting();
    return [
      SectionLabel(tr('When something goes wrong')),
      SurfaceCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: Column(
            children: [
              for (final (title, body) in entries)
                ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                  childrenPadding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                  expandedAlignment: Alignment.centerLeft,
                  title: Text(title, style: text.bodyMedium),
                  children: [Text(body, style: text.bodySmall)],
                ),
            ],
          ),
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(LucideIcons.bookOpen, size: 16),
          label: Text(tr('Read the server guide')),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ServerGuideScreen())),
        ),
      ),
    ];
  }

  List<Widget> _notifications(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final s = agent.integrations.settings!;
    return [
      SectionLabel(tr('Notifications')),
      Text(
        tr(
          'When the app is closed the server can push a short message (no project names, no content) through ntfy. Install the ntfy app on this phone and subscribe to the topic below.',
        ),
        style: text.bodySmall,
      ),
      const SizedBox(height: 10),
      TextField(
        controller: ntfyUrl,
        autocorrect: false,
        keyboardType: TextInputType.url,
        style: const TextStyle(fontFamily: mono, fontSize: 13),
        decoration: InputDecoration(labelText: tr('ntfy server')),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: topic,
        autocorrect: false,
        style: const TextStyle(fontFamily: mono, fontSize: 13),
        decoration: InputDecoration(
          labelText: tr('Topic (keep it secret)'),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: tr('Make a new one'),
                icon: const Icon(LucideIcons.dices, size: 18),
                onPressed: () => setState(() => topic.text = _newTopic()),
              ),
              IconButton(
                tooltip: tr('Copy'),
                icon: const Icon(LucideIcons.copy, size: 18),
                onPressed: topic.text.isEmpty ? null : () => _copy(topic.text, tr('topic')),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: PrimaryButton(label: tr('Save'), onPressed: topic.text.trim().isEmpty ? null : () => _saveNotify()),
          ),
        ],
      ),
      if (s.notifyTopic != null)
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              icon: _testingNotify
                  ? const BusySpinner(size: 14)
                  : const Icon(LucideIcons.bellRing, size: 16),
              label: Text(tr('Send a test notification')),
              onPressed: _testingNotify || !s.notifyEnabled ? null : _testNotify,
            ),
            TextButton.icon(
              icon: const Icon(LucideIcons.externalLink, size: 16),
              label: Text(tr('Open in ntfy')),
              onPressed: _openNtfy,
            ),
          ],
        ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(tr('Send notifications')),
        subtitle: s.notifyTopic == null ? Text(tr('Not set up yet'), style: TextStyle(color: p.muted)) : null,
        value: s.notifyEnabled && s.notifyTopic != null,
        onChanged: s.notifyTopic == null ? null : (v) => _saveNotify(enabled: v),
      ),
    ];
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.ok, required this.message, this.detail, this.next = false});

  final bool ok;

  /// Not done yet rather than wrong: shown as a step to take.
  final bool next;
  final String message;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = ok
        ? p.success
        : next
        ? p.warning
        : p.danger;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok
                ? LucideIcons.circleCheck
                : next
                ? LucideIcons.circleArrowRight
                : LucideIcons.circleAlert,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message, style: const TextStyle(fontSize: 13.5)),
                if (detail != null && detail!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SelectableText(
                      detail!,
                      style: TextStyle(fontFamily: mono, fontSize: 11, color: p.muted),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
