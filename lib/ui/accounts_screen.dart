import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';
import 'package:flutter/services.dart';

import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import 'code_view.dart';
import 'errors.dart';
import 'kit.dart';
import 'task_log.dart';
import 'i18n.dart';
import 'theme.dart';

/// GitHub, Vercel, Cloudflare, the device SSH key and saved servers.
class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  Integrations get it => widget.agent.integrations;

  @override
  void initState() {
    super.initState();
    it.refresh();
  }

  void _snack(String message) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(message))));

  /// Disconnects after a confirmation: a token can't be read back, so reconnecting means pasting it again.
  Future<void> _disconnect(String service, Future<void> Function() action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Disconnect {service}?').replaceAll('{service}', service)),
        content: Text(tr('Its token is removed from this device. To reconnect you will need to paste a token again.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: context.palette.danger),
            child: Text(tr('Disconnect')),
          ),
        ],
      ),
    );
    if (ok == true) await _guard(action, success: tr('{service} disconnected').replaceAll('{service}', service));
  }

  Future<void> _guard(Future<void> Function() action, {String? success}) async {
    try {
      await action();
      if (success != null && mounted) _snack(success);
    } catch (e) {
      if (mounted) _snack(friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: it,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(tr('Accounts & servers')),
        ),
        body: !it.loaded
            ? const Center(child: BusySpinner(size: 18))
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  // Each agent keeps its own accounts, on its own machine: a sign-in made while the phone's agent was in
                  // use is not on the server, and the other way round.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                    child: Text(
                      tr(
                        widget.agent.client.isRemote
                            ? "These accounts are the server's: the agent there signs in to them, so what you connect on this phone's own agent does not carry over."
                            : "These accounts are for this phone's agent. A server agent keeps its own: connect there too if you use one.",
                      ),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  _Header(tr('GitHub')),
                  it.github == null
                      ? _GithubConnect(
                          agent: widget.agent,
                          onError: _snack,
                          onDone: () => _snack('GitHub connected'),
                          tokenFallback: _TokenConnect(
                            icon: SimpleIcons.github,
                            title: tr('Connect GitHub'),
                            body:
                                'Clone your repositories, push commits and publish to GitHub Pages. '
                                'Create a classic token with the repo and workflow scopes, then paste it here.',
                            linkLabel: 'Create a token',
                            onLink: () => widget.agent.client.openUrl(
                              'https://github.com/settings/tokens/new?scopes=repo,workflow,read:org&description=GripHub AI Agent',
                            ),
                            hint: 'ghp_… or github_pat_…',
                            onConnect: (t) => _guard(() => it.githubLogin(t), success: 'GitHub connected'),
                          ),
                        )
                      : _Connected(
                          avatarUrl: it.github!.avatarUrl,
                          icon: SimpleIcons.github,
                          title: it.github!.name ?? it.github!.login,
                          subtitle: '@${it.github!.login} · ${tr(it.github!.expired ? 'sign-in expired' : 'git push and Pages enabled')}',
                          onDisconnect: () => _disconnect('GitHub', it.githubLogout),
                          // GitHub rejected the sign-in and it couldn't be refreshed: say so, and offer the way back.
                          footer: it.github!.expired ? _GithubExpired(onSignIn: () => _guard(it.githubLogout)) : null,
                        ),
                  _Header(tr('Vercel')),
                  it.vercelUser == null
                      ? _TokenConnect(
                          icon: SimpleIcons.vercel,
                          title: tr('Connect Vercel'),
                          body: 'Deploy any project folder to Vercel from the chat. Create an access token and paste it here.',
                          linkLabel: 'Create a token',
                          onLink: () => widget.agent.client.openUrl('https://vercel.com/account/tokens'),
                          hint: 'Vercel access token',
                          onConnect: (t) => _guard(() => it.vercelLogin(t), success: 'Vercel connected'),
                        )
                      : _Connected(
                          icon: SimpleIcons.vercel,
                          title: it.vercelUser!,
                          subtitle: tr('Deploys enabled'),
                          onDisconnect: () => _disconnect('Vercel', it.vercelLogout),
                        ),
                  _Header(tr('Cloudflare')),
                  if (!it.cloudflareConnected)
                    _TokenConnect(
                      icon: SimpleIcons.cloudflare,
                      title: tr('Connect Cloudflare'),
                      body:
                          'Deploy to Workers and Pages from the chat. Create an API token with the '
                          '"Edit Cloudflare Workers" template (it covers Pages too) and paste it here.',
                      linkLabel: 'Create a token',
                      onLink: () => widget.agent.client.openUrl('https://dash.cloudflare.com/profile/api-tokens'),
                      hint: 'Cloudflare API token',
                      onConnect: (t) => _guard(() => it.cloudflareLogin(t), success: 'Cloudflare connected'),
                    )
                  else
                    _Connected(
                      icon: SimpleIcons.cloudflare,
                      title: it.cloudflareAccountName ?? 'Cloudflare',
                      subtitle: tr('Workers and Pages deploys enabled'),
                      onDisconnect: () => _disconnect('Cloudflare', it.cloudflareLogout),
                      footer: it.cloudflareAccounts.length > 1
                          ? DropdownButtonFormField<String>(
                              initialValue: it.cloudflareAccountId,
                              isExpanded: true,
                              decoration: InputDecoration(labelText: tr('Deploy to account')),
                              items: [
                                for (final a in it.cloudflareAccounts)
                                  DropdownMenuItem(
                                    value: a.id,
                                    child: Text(a.name, overflow: TextOverflow.ellipsis),
                                  ),
                              ],
                              onChanged: (id) {
                                if (id == null) return;
                                _guard(
                                  () => it.cloudflareSelectAccount(id),
                                  success: tr('Deploys now go to this account'),
                                );
                              },
                            )
                          : null,
                    ),
                  _Header(tr('SSH key')),
                  _SshKeyCard(integrations: it, openUrl: widget.agent.client.openUrl),
                  _Header(
                    tr('Servers'),
                    trailing: TextButton.icon(
                      onPressed: () => _editHost(null),
                      icon: const Icon(LucideIcons.plus, size: 18),
                      label: Text(tr('Add')),
                    ),
                  ),
                  if (it.hosts.isEmpty)
                    _Card(
                      child: Text(
                        tr('Save a server to deploy over SSH. The agent can reach it too, as `ssh <name>`.'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  for (final h in it.hosts) _HostTile(host: h, onEdit: () => _editHost(h), onTest: () => _testHost(h)),
                  // Build configuration, not something to set up first: last and folded.
                  _Header(tr('Advanced')),
                  _GithubClientIdField(agent: widget.agent, onSaved: _snack),
                ],
              ),
      ),
    );
  }

  Future<void> _testHost(SshHost h) async {
    if (it.publicKey == null) await it.ensureSshKey();
    if (!mounted) return;
    await runWithLog<void>(
      context,
      title: '${tr('Connecting to')} ${h.name}',
      task: (log, _) => it.testHost(h.id, onLine: log),
    );
  }

  Future<void> _editHost(SshHost? h) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _HostSheet(host: h),
    );
    if (result == null) return;
    if (result['delete'] == true) {
      await _guard(() => it.deleteHost(h!.id));
    } else {
      await _guard(() => it.saveHost({if (h != null) 'id': h.id, ...result}));
    }
  }
}

class _Header extends StatelessWidget {
  const _Header(this.label, {this.trailing});
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(4, 24, 0, trailing == null ? 8 : 0),
    child: Row(
      children: [
        Expanded(child: Text(label.toUpperCase(), style: Theme.of(context).textTheme.labelSmall)),
        if (trailing != null) SectionAction(child: trailing!),
      ],
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The same card as the rest of the app (Web & DNS, Settings).
    return SurfaceCard(padding: const EdgeInsets.all(16), child: child);
  }
}

/// Signs in to GitHub with the device flow: show a short code, the user approves it on github.com.
/// Pasting a personal access token stays available underneath.
class _GithubConnect extends StatefulWidget {
  const _GithubConnect({required this.agent, required this.onError, required this.onDone, required this.tokenFallback});
  final AgentController agent;
  final void Function(String message) onError;
  final VoidCallback onDone;
  final Widget tokenFallback;

  @override
  State<_GithubConnect> createState() => _GithubConnectState();
}

class _GithubConnectState extends State<_GithubConnect> {
  bool starting = false;
  bool showToken = false;
  GithubDeviceFlow? flow;
  int attempt = 0;

  @override
  void initState() {
    super.initState();
    _resume();
  }

  /// Leaving the screen only stops watching: the host goes on waiting for the approval, and signs in by itself when it
  /// comes (the app is told).
  @override
  void dispose() {
    attempt++;
    super.dispose();
  }

  /// A sign-in the host is still waiting on (the screen was left, or the app closed, before it was approved): its code
  /// is shown again and the wait goes on.
  Future<void> _resume() async {
    final f = await widget.agent.integrations.githubDeviceStatus();
    if (f == null || !mounted || starting) return;
    final mine = ++attempt;
    setState(() {
      starting = true;
      flow = f;
    });
    await _watch(f, mine);
  }

  Future<void> _start() async {
    final it = widget.agent.integrations;
    final mine = ++attempt;
    setState(() => starting = true);
    try {
      final f = await it.githubDeviceStart();
      if (!mounted || mine != attempt) return;
      setState(() => flow = f);
      await Clipboard.setData(ClipboardData(text: f.userCode));
      await widget.agent.client.openUrl(f.verificationUri);
      await _watch(f, mine);
    } catch (e) {
      if (mounted && mine == attempt) {
        widget.onError(friendlyError(e));
        setState(() {
          starting = false;
          flow = null;
        });
      }
    }
  }

  Future<void> _watch(GithubDeviceFlow f, int mine) async {
    try {
      final ok = await widget.agent.integrations.githubDeviceWait(f, cancelled: () => !mounted || mine != attempt);
      if (ok && mounted) widget.onDone();
    } catch (e) {
      if (mounted && mine == attempt) widget.onError(friendlyError(e));
    } finally {
      if (mounted && mine == attempt) {
        setState(() {
          starting = false;
          flow = null;
        });
      }
    }
  }

  /// Gives the sign-in up: the host stops waiting too, so approving on github.com later signs in nothing.
  void _cancel() {
    unawaited(widget.agent.integrations.githubDeviceCancel());
    setState(() {
      attempt++;
      starting = false;
      flow = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final f = flow;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconTile(icon: SimpleIcons.github, color: p.text, size: 36),
                  const SizedBox(width: 10),
                  Text(tr('Connect GitHub'), style: text.titleSmall),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                f == null
                    ? 'Clone your repositories, push commits and publish to GitHub Pages. '
                          'Sign in on github.com with a one-time code; no token to create.'
                    : 'Enter this code on GitHub. It is already copied, just paste it and approve.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 14),
              if (f == null)
                PrimaryButton(
                  label: tr('Sign in with GitHub'),
                  icon: SimpleIcons.github,
                  busy: starting,
                  onPressed: starting ? null : _start,
                )
              else ...[
                GestureDetector(
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: f.userCode));
                    widget.onError('Code copied');
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.lg)),
                    alignment: Alignment.center,
                    child: Text(
                      f.userCode,
                      style: TextStyle(
                        fontFamily: mono,
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 4,
                        color: p.text,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => widget.agent.client.openUrl(f.verificationUri),
                        icon: const Icon(LucideIcons.externalLink, size: 16),
                        label: Text(tr('Open GitHub')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(onPressed: _cancel, child: Text(tr('Cancel'))),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    BusySpinner(size: 12),
                    const SizedBox(width: 8),
                    Text(tr('Waiting for you to approve on GitHub…'), style: text.bodySmall),
                  ],
                ),
              ],
              if (f == null)
                TextButton(
                  onPressed: () => setState(() => showToken = !showToken),
                  style: TextButton.styleFrom(foregroundColor: p.muted),
                  child: Text(tr(showToken ? 'Hide token option' : 'Use a personal access token instead')),
                ),
            ],
          ),
        ),
        if (showToken && f == null) ...[const SizedBox(height: 10), widget.tokenFallback],
      ],
    );
  }
}

class _TokenConnect extends StatefulWidget {
  const _TokenConnect({
    required this.icon,
    required this.title,
    required this.body,
    required this.linkLabel,
    required this.onLink,
    required this.hint,
    required this.onConnect,
  });
  final IconData icon;
  final String title;
  final String body;
  final String linkLabel;
  final VoidCallback onLink;
  final String hint;
  final Future<void> Function(String token) onConnect;

  @override
  State<_TokenConnect> createState() => _TokenConnectState();
}

class _TokenConnectState extends State<_TokenConnect> {
  final token = TextEditingController();
  bool busy = false;

  @override
  void dispose() {
    token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (token.text.trim().isEmpty) return;
    setState(() => busy = true);
    await widget.onConnect(token.text);
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconTile(icon: widget.icon, color: p.text, size: 36),
              const SizedBox(width: 10),
              Text(tr(widget.title), style: text.titleSmall),
            ],
          ),
          const SizedBox(height: 8),
          Text(tr(widget.body), style: text.bodySmall),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: widget.onLink,
              style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: p.text),
              icon: const Icon(LucideIcons.externalLink, size: 15),
              label: Text(tr(widget.linkLabel)),
            ),
          ),
          TextField(
            controller: token,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(hintText: tr(widget.hint)),
            onSubmitted: (_) => _connect(),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: busy ? null : _connect,
            child: busy
                ? const BusySpinner()
                : Text(tr('Connect')),
          ),
        ],
      ),
    );
  }
}

/// The GitHub OAuth App Client ID for the device flow. This is how a
/// distributed build points GitHub login at its own OAuth App without a
/// rebuild: create an OAuth App with Device Flow enabled, paste its Client
/// ID here. The ID is public, not a secret. Empty means GitHub login is
/// not configured.
class _GithubClientIdField extends StatefulWidget {
  const _GithubClientIdField({required this.agent, required this.onSaved});
  final AgentController agent;
  final void Function(String message) onSaved;

  @override
  State<_GithubClientIdField> createState() => _GithubClientIdFieldState();
}

class _GithubClientIdFieldState extends State<_GithubClientIdField> {
  late final TextEditingController _id = TextEditingController(
    text: widget.agent.integrations.settings?.githubClientId ?? '',
  );
  bool _saving = false;
  bool _open = false;
  bool _edited = false;

  /// What the agent uses now; the field may hold an unsaved edit.
  String get _saved => widget.agent.integrations.settings?.githubClientId?.trim() ?? '';
  bool get _builtIn => widget.agent.integrations.settings?.githubClientIdBuiltIn ?? false;

  @override
  void initState() {
    super.initState();
    // Opened straight from Home, the settings may not be loaded yet. Fill the field once they
    // are, so saving an untouched box can't replace a custom client ID with an empty one.
    if (widget.agent.integrations.settings == null) {
      widget.agent.integrations.refreshSettings().then((_) {
        if (mounted && !_edited) setState(() => _id.text = _saved);
      }, onError: (_) {});
    }
  }

  @override
  void dispose() {
    _id.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.agent.integrations.updateSettings({'githubClientId': _id.text.trim()});
      if (mounted) widget.onSaved('OAuth client ID saved');
    } catch (e) {
      if (mounted) widget.onSaved(friendlyError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: BorderRadius.circular(Radii.md),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr('GitHub OAuth client ID'), style: text.titleSmall),
                        const SizedBox(height: 2),
                        Text(
                          _saved.isNotEmpty
                              ? _saved
                              : (_builtIn ? tr('Built-in GripHub app') : tr('Not set: sign-in with a code is off')),
                          style: text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: Motion.of(context, const Duration(milliseconds: 200)),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Icon(LucideIcons.chevronDown, size: 18, color: p.faint),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 4, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _builtIn
                        ? tr('Only for your own GitHub OAuth App (Device Flow enabled): paste its Client ID here. It is public, not a secret. Leave empty to sign in with the built-in app.')
                        : tr('Sign-in with a code needs the Client ID of a GitHub OAuth App with Device Flow enabled: paste it here (it is public, not a secret). Without one, sign in with a token instead.'),
                    style: text.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _id,
                          autocorrect: false,
                          style: const TextStyle(fontFamily: mono, fontSize: 14),
                          decoration: const InputDecoration(hintText: 'Ov23…'),
                          onChanged: (_) => _edited = true,
                          onSubmitted: (_) => _save(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: _saving ? null : _save, child: Text(tr('Save'))),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Connected extends StatelessWidget {
  const _Connected({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onDisconnect,
    this.avatarUrl,
    this.footer,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onDisconnect;
  final String? avatarUrl;

  /// Shown under the account, inside the card (e.g. which Cloudflare account deploys go to).
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: p.raised,
                foregroundImage: avatarUrl == null ? null : NetworkImage(avatarUrl!),
                child: Icon(icon, size: 18, color: p.text),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.titleSmall),
                    const SizedBox(height: 2),
                    Text(subtitle, style: text.bodySmall),
                  ],
                ),
              ),
              TextButton(
                onPressed: onDisconnect,
                style: TextButton.styleFrom(foregroundColor: p.danger),
                child: Text(tr('Disconnect')),
              ),
            ],
          ),
          if (footer != null) ...[const SizedBox(height: 12), footer!],
        ],
      ),
    );
  }
}

/// Under an expired GitHub account: why git and Pages stopped working, and a button back to sign-in.
class _GithubExpired extends StatelessWidget {
  const _GithubExpired({required this.onSignIn});
  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(LucideIcons.triangleAlert, size: 16, color: p.warning),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tr('This sign-in expired or was revoked. Sign in again to keep cloning, pushing and publishing.'),
                style: text.bodySmall?.copyWith(color: p.warning),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: onSignIn,
          icon: const Icon(SimpleIcons.github, size: 16),
          label: Text(tr('Sign in again')),
        ),
      ],
    );
  }
}

class _SshKeyCard extends StatefulWidget {
  const _SshKeyCard({required this.integrations, required this.openUrl});
  final Integrations integrations;
  final Future<void> Function(String url) openUrl;

  @override
  State<_SshKeyCard> createState() => _SshKeyCardState();
}

class _SshKeyCardState extends State<_SshKeyCard> {
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final key = widget.integrations.publicKey;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr(
              key == null
                  ? 'Generate a key for this device, then add its public half to your servers or GitHub.'
                  : 'Add this public key to ~/.ssh/authorized_keys on your servers, or to GitHub for SSH remotes.',
            ),
            style: text.bodySmall,
          ),
          const SizedBox(height: 12),
          if (key == null)
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      try {
                        await widget.integrations.ensureSshKey();
                      } finally {
                        if (mounted) setState(() => busy = false);
                      }
                    },
              icon: const Icon(LucideIcons.keyRound, size: 18),
              label: Text(tr('Generate key')),
            )
          else ...[
            CodeBox(text: key, label: 'id_ed25519.pub', lineNumbers: false),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: key));
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Public key copied'))));
                    },
                    icon: const Icon(LucideIcons.copy, size: 16),
                    label: Text(tr('Copy')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: key));
                      widget.openUrl('https://github.com/settings/ssh/new');
                    },
                    icon: const Icon(LucideIcons.externalLink, size: 16),
                    label: Text(tr('Add to GitHub')),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _HostTile extends StatelessWidget {
  const _HostTile({required this.host, required this.onEdit, required this.onTest});
  final SshHost host;
  final VoidCallback onEdit;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      // The same borderless card and icon tile as every other row on this screen.
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.xl)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onEdit,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                IconTile(icon: LucideIcons.server, color: p.muted),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(host.name, style: text.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        [host.address, if (host.path != null) host.path!].join('  ·  '),
                        style: TextStyle(fontFamily: mono, fontSize: 11.5, color: p.muted),
                      ),
                    ],
                  ),
                ),
                TextButton(onPressed: onTest, child: Text(tr('Test'))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HostSheet extends StatefulWidget {
  const _HostSheet({this.host});
  final SshHost? host;

  @override
  State<_HostSheet> createState() => _HostSheetState();
}

class _HostSheetState extends State<_HostSheet> {
  late final name = TextEditingController(text: widget.host?.name);
  late final host = TextEditingController(text: widget.host?.host);
  late final port = TextEditingController(text: '${widget.host?.port ?? 22}');
  late final user = TextEditingController(text: widget.host?.user);
  late final path = TextEditingController(text: widget.host?.path);

  @override
  void dispose() {
    for (final c in [name, host, port, user, path]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    Widget field(TextEditingController c, String label, {String? hint, TextInputType? type, bool monospace = false}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: c,
            keyboardType: type,
            autocorrect: false,
            style: monospace ? const TextStyle(fontFamily: mono, fontSize: 14) : null,
            decoration: InputDecoration(labelText: tr(label), hintText: hint),
          ),
        );
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr(widget.host == null ? 'Add server' : 'Edit server'), style: text.titleLarge),
              const SizedBox(height: 16),
              field(name, 'Name', hint: 'my-vps'),
              Row(
                children: [
                  Expanded(flex: 3, child: field(host, 'Host', hint: '203.0.113.10', monospace: true)),
                  const SizedBox(width: 10),
                  Expanded(child: field(port, 'Port', type: TextInputType.number, monospace: true)),
                ],
              ),
              field(user, 'User', hint: 'root', monospace: true),
              field(path, 'Deploy folder (optional)', hint: '/var/www/html', monospace: true),
              const SizedBox(height: 6),
              FilledButton(
                onPressed: () => Navigator.of(context).pop({
                  'name': name.text,
                  'host': host.text,
                  'port': int.tryParse(port.text) ?? 22,
                  'user': user.text,
                  'path': path.text,
                }),
                child: Text(tr('Save')),
              ),
              if (widget.host != null) ...[
                const SizedBox(height: 8),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: p.danger),
                  onPressed: () => Navigator.of(context).pop({'delete': true}),
                  child: Text(tr('Remove server')),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
