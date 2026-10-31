import 'dart:async';

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/pricing.dart';
import '../agent/updater.dart';
import 'accounts_screen.dart';
import 'backup_screen.dart';
import 'chat_extras.dart';
import 'container_screen.dart';
import 'errors.dart';
import 'server_screen.dart';
import 'kit.dart';
import 'links.dart';
import 'i18n.dart';
import 'illustration.dart';
import 'image_gen_screen.dart';
import 'mcp_screen.dart';
import 'mesh.dart';
import 'network_screen.dart';
import 'settings_screen.dart';
import 'skills_screen.dart';
import 'subagent_settings_screen.dart';
import 'sync_screen.dart';
import 'tasks_screen.dart';
import 'templates_screen.dart';
import 'theme.dart';
import 'update_sheet.dart';
import 'usage_screen.dart';

/// The settings home: everything the agent can use, grouped.
class SettingsHub extends StatefulWidget {
  const SettingsHub({super.key, required this.agent});
  final AgentController agent;

  @override
  State<SettingsHub> createState() => _SettingsHubState();
}

class _SettingsHubState extends State<SettingsHub> {
  /// The approval mode being saved: shown as chosen, with a spinner, until the host has it (or put back if it failed).
  String? _approvalSaving;

  Future<void> _setApprovalMode(String v) async {
    if (_approvalSaving != null) return;
    if (v == 'auto' && !await confirmBypass(context)) return;
    if (!mounted) return;
    setState(() => _approvalSaving = v);
    try {
      await widget.agent.setApprovalMode(v);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('Could not change approvals')}: ${friendlyError(e)}')));
      }
    } finally {
      if (mounted) setState(() => _approvalSaving = null);
    }
  }

  int? skillCount;

  AgentController get agent => widget.agent;

  @override
  void initState() {
    super.initState();
    final it = agent.integrations;
    it.refresh().catchError((_) {});
    // Offline (a server out of reach) these fail before anything was loaded: the rows show what is known.
    it.refreshContainer().then((_) {}, onError: (_) {});
    it.refreshSettings().then((_) {}, onError: (_) {});
    it.refreshSync().catchError((_) {});
    it.skills().then((s) {
      if (mounted) setState(() => skillCount = s.length);
    }, onError: (_) {});
  }

  void _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (!mounted) return;
    // A screen may have switched between this phone and a server: the container row follows.
    agent.integrations.refreshContainer().then((_) {}, onError: (_) {});
    agent.integrations.skills().then((s) {
      if (mounted) setState(() => skillCount = s.length);
    }, onError: (_) {});
  }

  Future<void> _setAppLock(bool on) async {
    if (on) {
      // Confirm the phone can unlock before turning it on, so nobody locks themselves out.
      try {
        final auth = LocalAuthentication();
        if (!await auth.isDeviceSupported()) throw tr('No screen lock is set on this phone.');
        if (!await auth.authenticate(localizedReason: tr('Unlock GripHub AI Agent'))) return;
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
        return;
      }
    }
    Appearance.instance.update(appLock: on);
    // FLAG_SECURE must follow the setting, not just the lock screen: the
    // leak is the Recents snapshot taken while the app is backgrounded.
    unawaited(agent.client.setSecure(on).catchError((_) {}));
  }

  Future<void> _pickFallbacks() async {
    final it = agent.integrations;
    final chosen = [
      for (final m in it.settings?.fallbackModels ?? const <Map<String, dynamic>>[]) '${m['provider']}/${m['model']}',
    ];
    final models = agent.models;
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (context, scroll) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
                child: Row(
                  children: [
                    Expanded(child: Text(tr('Fallback models'), style: Theme.of(context).textTheme.titleLarge)),
                    TextButton(onPressed: () => Navigator.pop(context, chosen), child: Text(tr('Save'))),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  tr('Used when the current model hits a limit or errors'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scroll,
                  children: [
                    for (final m in models)
                      CheckboxListTile(
                        value: chosen.contains(m.key),
                        title: Text(m.name),
                        subtitle: Text(
                          chosen.contains(m.key) ? '#${chosen.indexOf(m.key) + 1} · ${m.provider}' : m.provider,
                        ),
                        onChanged: (v) => setSheet(() => v == true ? chosen.add(m.key) : chosen.remove(m.key)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result == null) return;
    await it.updateSettings({
      'fallbackModels': [
        for (final k in result) {'provider': k.substring(0, k.indexOf('/')), 'model': k.substring(k.indexOf('/') + 1)},
      ],
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([
        agent,
        agent.integrations,
        agent.features,
        agent.remote,
        agent.client.connection,
        Appearance.instance,
        Updater.instance,
      ]),
      builder: (context, _) {
        final it = agent.integrations;
        final look = Appearance.instance;
        final connected = agent.providers.where((x) => x.configured).toList();
        final c = it.container;
        final dnsLabel = switch (it.settings?.dns) {
          'system' => tr('System DNS'),
          'google' => 'Google DoH',
          'custom' => tr('Custom DoH'),
          _ => 'Cloudflare DoH',
        };
        return Scaffold(
          appBar: AppBar(title: Text(tr('Settings'))),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
            children: [
              SurfaceCard(
                child: Row(
                  children: [
                    const LogoMark(size: 48),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tr('GripHub AI Agent'), style: text.titleLarge),
                          const SizedBox(height: 2),
                          Text(
                            Updater.instance.currentVersion.isEmpty
                                ? tr('Coding agent on your phone')
                                : '${tr('Version')} ${Updater.instance.currentVersion}',
                            style: TextStyle(fontSize: 12.5, color: p.muted),
                          ),
                        ],
                      ),
                    ),
                    Pill(agent.busy ? tr('Working') : tr('Ready'), color: agent.busy ? p.warning : p.success, dot: true),
                  ],
                ),
              ),
              // Where the agent runs, first thing on the page: the way to the server agent, whichever it is.
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SettingsGroup(
                  children: [
                    SettingsRow(
                      icon: agent.remote.active ? LucideIcons.server : LucideIcons.smartphone,
                      color: agent.remote.active ? const Color(0xFF0F766E) : p.muted,
                      title: agent.remote.active ? tr('Agent: your server') : tr('Agent: this phone'),
                      subtitle: agent.remote.active
                          ? (agent.client.connection.value.connected
                                ? tr('Connected')
                                : tr('Not connected to the server'))
                          : agent.remote.configured
                          ? tr('A server is set up; tap to switch')
                          : tr('Run the agent on your own VPS, around the clock'),
                      onTap: () => _open(ServerScreen(agent: agent)),
                    ),
                  ],
                ),
              ),
              SectionLabel(tr('AI')),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.brain,
                    color: p.accent,
                    title: tr('Models & providers'),
                    subtitle: connected.isEmpty
                        ? tr('Connect a provider to start')
                        : '${connected.map((x) => x.name).join(', ')}${agent.model != null ? ' · ${agent.model!.name}' : ''}',
                    onTap: () => _open(SettingsScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.puzzle,
                    color: const Color(0xFFEC4899),
                    title: tr('Skills'),
                    subtitle: skillCount == null
                        ? tr('Instructions the agent loads on demand')
                        : tr('{n} installed').replaceAll('{n}', '$skillCount'),
                    onTap: () => _open(SkillsScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.image,
                    color: const Color(0xFF7C3AED),
                    title: tr('Generate image'),
                    subtitle: tr('Make pictures with GripHub image models'),
                    onTap: () => _open(ImageGenScreen(agent: agent)),
                  ),
                ],
              ),
              SectionLabel(tr('Workspace')),
              SettingsGroup(
                children: [
                  SettingsRow(
                    // On a server the row is the agent's box even before its status has come in.
                    icon: (c?.isBox ?? agent.remote.active)
                        ? LucideIcons.container
                        : c?.distro == 'alpine'
                        ? SimpleIcons.alpinelinux
                        : SimpleIcons.debian,
                    color: (c?.isBox ?? agent.remote.active)
                        ? p.accent
                        : c?.distro == 'alpine'
                        ? const Color(0xFF0D597F)
                        : const Color(0xFFD70A53),
                    // On a server this is the agent's box (Podman), not a Linux on the phone.
                    title: tr((c?.isBox ?? agent.remote.active) ? 'The agent\'s box' : 'Linux container'),
                    subtitle: c == null
                        ? (agent.remote.active ? tr('Where the agent\'s commands run') : tr('Debian or Alpine with apt / apk'))
                        : c.installed
                        ? '${c.image}${c.enabled ? ' · ${tr('agent shell')}' : ''}'
                        : c.isBox
                        ? tr('Not built · rebuild it on its screen')
                        : tr('Not installed · run apt, pip, npm and more'),
                    trailing: c?.enabled == true ? Pill(tr('On'), color: p.success, dot: true) : null,
                    onTap: () => _open(ContainerScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.keyRound,
                    color: const Color(0xFFF59E0B),
                    title: tr('Accounts & servers'),
                    subtitle: [
                      if (it.github != null) 'GitHub @${it.github!.login}',
                      if (it.vercelUser != null) 'Vercel',
                      if (it.cloudflareConnected) 'Cloudflare',
                      if (it.hosts.isNotEmpty) serverCount(it.hosts.length),
                    ].join(' · ').ifEmpty(tr('GitHub, Vercel, Cloudflare, SSH keys and servers')),
                    onTap: () => _open(AccountsScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.globe,
                    color: const Color(0xFF06B6D4),
                    title: tr('Web & DNS'),
                    subtitle: '$dnsLabel · ${tr('web search for the agent')}',
                    onTap: () => _open(NetworkScreen(agent: agent)),
                  ),
                ],
              ),
              SectionLabel(tr('Agent behaviour')),
              _Segmented<String>(
                label: tr('Approvals'),
                value: _approvalSaving ?? it.settings?.approvalMode ?? agent.approvalMode,
                options: {'ask_all': tr('Ask all'), 'ask_risky': tr('Risky only'), 'auto': tr('Bypass all')},
                busy: _approvalSaving != null,
                onChanged: _setApprovalMode,
              ),
              // What the setting is: questions before common risky actions. Not a wall against a page or file that tells the
              // agent what to do, so it is not described as one.
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Text(
                  tr('Approvals are prompts for common risky actions, not a security boundary: a model can still reach things they do not list. Open only what you trust.'),
                  key: const ValueKey('approvals-caption'),
                  style: text.bodySmall?.copyWith(color: p.muted),
                ),
              ),
              if ((it.settings?.approvalMode ?? agent.approvalMode) == 'auto')
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                  child: Row(
                    children: [
                      Icon(LucideIcons.shieldOff, size: 14, color: p.warning),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          tr('All permissions bypassed: the agent never asks before acting.'),
                          style: text.bodySmall?.copyWith(color: p.warning),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.lifeBuoy,
                    color: const Color(0xFF8B5CF6),
                    title: tr('Fallback models'),
                    subtitle: (it.settings?.fallbackModels ?? const []).isEmpty
                        ? tr('Used when the current model hits a limit or errors')
                        : it.settings!.fallbackModels.map((m) => m['model']).join(' → '),
                    onTap: _pickFallbacks,
                  ),
                  SettingsRow(
                    icon: LucideIcons.chartColumn,
                    color: const Color(0xFF10B981),
                    title: tr('Usage & budget'),
                    subtitle: (it.settings?.dailyBudget ?? 0) > 0
                        ? tr('{n} per day').replaceAll(
                            '{n}',
                            '${localNumber(formatCredits(it.settings!.dailyBudget))} ${tr('credits')}',
                          )
                        : tr('Tokens, cost and a daily limit'),
                    onTap: () => _open(UsageScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.bot,
                    color: const Color(0xFF7C3AED),
                    title: tr('Subagent'),
                    subtitle: subagentLimitsSummary(it.settings),
                    onTap: () => _open(SubagentSettingsScreen(agent: agent)),
                  ),
                ],
              ),
              SectionLabel(tr('Automation')),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.listTodo,
                    color: context.palette.accentAlt,
                    title: tr('Background tasks'),
                    subtitle: tr('Queue, parallel agents and schedules'),
                    onTap: () => _open(TasksScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.plug,
                    color: const Color(0xFFF97316),
                    title: tr('MCP servers'),
                    subtitle: agent.features.mcpServers.isEmpty
                        ? tr('Extra tools from Model Context Protocol servers')
                        : serverCount(agent.features.mcpServers.length),
                    onTap: () => _open(McpScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.squareSlash,
                    color: const Color(0xFF64748B),
                    title: tr('Prompt templates'),
                    subtitle: tr('Slash commands like /review and /test'),
                    onTap: () => _open(TemplatesScreen(agent: agent)),
                  ),
                ],
              ),
              SectionLabel(tr('Data & security')),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.server,
                    color: const Color(0xFF0F766E),
                    title: tr('Agent on a VPS / server'),
                    subtitle: agent.remote.active
                        ? tr('The agent runs on your server')
                        : agent.remote.configured
                        ? tr('Set up; this phone runs the agent')
                        : tr('Run the agent on your own VPS, around the clock'),
                    onTap: () => _open(ServerScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.refreshCw,
                    color: const Color(0xFF16A34A),
                    title: tr('GitHub sync'),
                    subtitle: it.sync?.enabled == true
                        ? (it.sync!.lastError != null
                              ? tr('Sync failed; tap for details')
                              : '${tr('Last synced')}: ${syncAgo(it.sync!.lastSync)}')
                        : tr('Chats and projects on all your phones'),
                    onTap: () => _open(SyncScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.archive,
                    color: const Color(0xFF0EA5E9),
                    title: tr('Backup & restore'),
                    subtitle: tr('Chats, skills and schedules in one file'),
                    onTap: () => _open(BackupScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.link,
                    color: const Color(0xFF6366F1),
                    title: tr('Trusted domains'),
                    subtitle: look.trustedDomains.isEmpty
                        ? tr('Links ask before leaving the app')
                        : tr('{n} open without asking').replaceAll('{n}', '${look.trustedDomains.length}'),
                    onTap: () => _open(const TrustedDomainsScreen()),
                  ),
                  SettingsRow(
                    icon: LucideIcons.fingerprint,
                    color: const Color(0xFFE11D48),
                    title: tr('App lock'),
                    subtitle: tr('Fingerprint or screen lock when opening GripHub AI Agent'),
                    trailing: LabeledSwitch(label: tr('App lock'), value: look.appLock, onChanged: _setAppLock),
                    onTap: () => _setAppLock(!look.appLock),
                  ),
                ],
              ),
              SectionLabel(tr('Appearance')),
              _Segmented<ThemeMode>(
                value: look.value,
                options: {ThemeMode.light: tr('Light'), ThemeMode.dark: tr('Dark'), ThemeMode.system: tr('System')},
                onChanged: look.set,
              ),
              const SizedBox(height: 10),
              _Segmented<double>(
                label: tr('Text size'),
                value: look.textScale,
                options: {0.9: tr('Small'), 1.0: tr('Default'), 1.12: tr('Large'), 1.25: tr('Huge')},
                onChanged: (v) => look.update(textScale: v),
              ),
              const SizedBox(height: 10),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.rows3,
                    color: p.muted,
                    title: tr('Compact layout'),
                    subtitle: tr('Tighter spacing, more on screen'),
                    trailing: LabeledSwitch(
                      label: tr('Compact layout'),
                      value: look.compact,
                      onChanged: (v) => look.update(compact: v),
                    ),
                    onTap: () => look.update(compact: !look.compact),
                  ),
                  // The title on its own line and the swatches under it, so neither starves on a narrow phone; each swatch
                  // is a 48 dp target that says its colour and whether it is the one chosen.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr('Accent colour'), style: text.titleSmall),
                        const SizedBox(height: 4),
                        Wrap(
                          children: [
                            for (var i = 0; i < accentChoices.length; i++)
                              Semantics(
                                button: true,
                                selected: look.accent == i,
                                label: tr(accentNames[i]),
                                child: TapTarget(
                                  onTap: () => look.update(accent: i),
                                  child: Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Theme.of(context).brightness == Brightness.light
                                          ? accentChoices[i].$1
                                          : accentChoices[i].$2,
                                      border: Border.all(color: look.accent == i ? p.text : Colors.transparent, width: 2.5),
                                    ),
                                    child: look.accent == i ? Icon(LucideIcons.check, size: 14, color: p.inverse) : null,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _Segmented<String>(
                label: tr('Language'),
                value: look.language,
                options: languages,
                onChanged: (v) => look.update(language: v),
              ),
              SectionLabel(tr('Powered by')),
              _GripHubCard(openUrl: agent.client.openUrl),
              SectionLabel(tr('About')),
              SettingsGroup(
                children: [
                  if (Updater.instance.supported) _updatesRow(context),
                  _InfoRow('Workspace', agent.info['workspace']?.toString() ?? '—'),
                  _InfoRow('Agent directory', agent.info['agentDir']?.toString() ?? '—'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: StorysetCredit(openUrl: agent.client.openUrl),
                  ),
                  SettingsRow(
                    icon: LucideIcons.rotateCcw,
                    color: p.muted,
                    title: tr('Restart agent'),
                    subtitle: tr('Reload the runtime, keeping your chats'),
                    onTap: agent.busy ? null : agent.restart,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

extension on _SettingsHubState {
  Widget _updatesRow(BuildContext context) {
    final p = context.palette;
    final u = Updater.instance;
    final d = u.download;
    final status = switch (u.phase) {
      UpdatePhase.checking => tr('Checking for updates…'),
      UpdatePhase.available => '${tr('Update available')}: ${u.latest!.version}',
      UpdatePhase.downloading =>
        d.progress != null ? '${tr('Downloading')} ${(d.progress! * 100).round()}%' : tr('Downloading'),
      UpdatePhase.ready => tr('Update ready to install'),
      UpdatePhase.failed => tr('Download failed'),
      UpdatePhase.upToDate => tr('GripHub AI Agent is up to date'),
      UpdatePhase.idle => tr('Check for updates'),
    };
    final attention = u.phase == UpdatePhase.available || u.phase == UpdatePhase.ready;
    return SettingsRow(
      icon: LucideIcons.download,
      color: attention ? p.accent : p.muted,
      title: tr('App updates'),
      subtitle: '${tr('Version')} ${u.currentVersion}  ·  $status',
      trailing: attention ? Pill(tr('New'), color: p.accent, dot: true) : null,
      onTap: () =>
          showUpdateSheet(context, agent, check: u.phase == UpdatePhase.idle || u.phase == UpdatePhase.upToDate),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr(label), style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 3),
          SelectableText(
            value,
            style: TextStyle(fontFamily: mono, fontSize: 12, height: 1.5, color: p.text),
          ),
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// A full-width segmented control with an optional caption above it.
class _Segmented<T> extends StatelessWidget {
  const _Segmented({
    required this.value,
    required this.options,
    required this.onChanged,
    this.label,
    this.busy = false,
  });
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  final String? label;

  /// The choice is being saved: a spinner by the label, and no other choice until it is.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 0, 8),
            child: Row(
              children: [
                Text(label!, style: Theme.of(context).textTheme.labelMedium),
                if (busy) ...[const SizedBox(width: 8), const BusySpinner(size: 12)],
              ],
            ),
          ),
        IgnorePointer(
          ignoring: busy,
          child: PillSegments<T>(value: value, options: options, onChanged: onChanged),
        ),
      ],
    );
  }
}

/// Who builds GripHub AI Agent, with links to their GitHub and site.
/// The service this special build is powered by: GripHub Router.
class _GripHubCard extends StatelessWidget {
  const _GripHubCard({required this.openUrl});
  final Future<void> Function(String url) openUrl;

  static const site = 'https://griphubrouter.web.id';

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return SurfaceCard(
      onTap: () => openUrl(site),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Avatar(name: 'GripHub', size: 52),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('GripHub AI Agent', style: text.titleLarge),
                    Text(
                      'griphubrouter.web.id',
                      style: TextStyle(fontFamily: mono, fontSize: 12.5, color: p.muted),
                    ),
                  ],
                ),
              ),
              Icon(LucideIcons.globe, size: 22, color: p.text),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            tr('A special build powered by GripHub Router \u2014 Claude, GPT, Gemini, DeepSeek and more behind one API key. This app talks to GripHub only: add your key and start building.'),
            style: text.bodyMedium?.copyWith(color: p.muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _LinkChip(icon: LucideIcons.globe, label: 'griphubrouter.web.id', onTap: () => openUrl(site)),
            ],
          ),
        ],
      ),
    );
  }
}

class _LinkChip extends StatelessWidget {
  const _LinkChip({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.raised,
      borderRadius: BorderRadius.circular(Radii.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.pill),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: p.text),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: p.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "1 server" / "3 servers" in the app's language (an English plural used to be built in place).
String serverCount(int n) => n == 1 ? tr('1 server') : tr('{n} servers').replaceAll('{n}', '$n');
