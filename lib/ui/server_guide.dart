import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// What to do when something goes wrong with the server agent, for someone who has never used a VPS. The repository
/// with the server notes is private, so the app carries them; the server screen and the guide show the same list.
List<(String, String)> serverTroubleshooting() => [
  (
    tr('Getting to the server\'s terminal'),
    tr(
      'Use the web console in your VPS provider\'s control panel, or an SSH app (Termius, JuiceSSH) with the address and the root password or key the provider gave you.',
    ),
  ),
  (
    tr('The paste "arrived damaged"'),
    tr('The terminal changed the text on the way. Use "Share the setup file instead", or paste in another SSH app.'),
  ),
  (
    tr('No sudo, or "run this as root"'),
    tr('Log in as root, or as an account that may use sudo; the setup needs it once.'),
  ),
  (
    tr('"rootless podman does not work", or the box is not built'),
    tr(
      'Paste the setup command again: it repairs Podman on Ubuntu 24.04. Then build the box in Settings > The agent\'s box.',
    ),
  ),
  (
    tr('"Could not reach" the server'),
    tr('Check the address, that this phone is online, and that the provider\'s firewall lets SSH in (port 22).'),
  ),
  (
    tr('"Host key" warning'),
    tr('Do not continue unless you reinstalled the server; then run the setup again and paste the new code.'),
  ),
  (
    tr('This phone was lost'),
    tr(
      'On the server, remove the line ending in griphub-app from /home/griphub/.ssh/authorized_keys. Then set up the new phone with the setup command.',
    ),
  ),
  (
    tr('The agent says commands are refused'),
    tr(
      'The box is switched on but its image is not built yet. Build it in Settings > The agent\'s box, or turn the box off there to run commands on the server itself.',
    ),
  ),
  (
    tr('Commands hang and never answer'),
    tr(
      'With the box on, a command that waits for ever with no output, or is refused with "the agent\'s box did not answer", means the box is stuck, not the agent. Reset the box in Settings > The agent\'s box and try again; if that does not help, turn the box off there: commands then run on the server itself.',
    ),
  ),
  (
    tr('Disk space warnings'),
    tr(
      'Under 5 GB free the agent takes no new work. Delete what you no longer need (old projects, build output, node_modules you can install again), or empty the box\'s home folder.',
    ),
  ),
  (
    tr('The agent uses a lot of memory'),
    tr(
      'The agent and its subagents share 2 GB. Let fewer subagents work at once; "Install / update agent" also restarts it, once nothing is running.',
    ),
  ),
  (
    tr('An update says it restarts when the work is done'),
    tr(
      'The new files are on the server; the agent switches to them once no chat, subagent or background task is running. Stop the work if it should happen now.',
    ),
  ),
  (
    tr('Notifications do not arrive'),
    tr(
      'Install the ntfy app, subscribe to the exact topic shown on the server screen, and use "Send a test notification". Notifications only come while the app is closed or in the background.',
    ),
  ),
  (
    tr('The automatic backup failed'),
    tr(
      'Its reason is under Settings > Backup & restore. Usually the disk is full; free some space and use "Back up now".',
    ),
  ),
];

/// The user's guide to the server agent and its box: what they are, how to set them up, what the switches and the
/// health table mean, and what to do when something goes wrong. In the app, so it is there without the internet.
class ServerGuideScreen extends StatefulWidget {
  const ServerGuideScreen({super.key, this.section});

  /// The section to start at ('box' opens on the box), or null for the top.
  final String? section;

  @override
  State<ServerGuideScreen> createState() => _ServerGuideScreenState();
}

class _ServerGuideScreenState extends State<ServerGuideScreen> {
  final _boxKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Every section is built at once (it is one page of text), so the box's is there to scroll to.
    if (widget.section == 'box') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _boxKey.currentContext;
        if (ctx != null) Scrollable.ensureVisible(ctx, duration: Duration.zero);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final boxKey = _boxKey;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Server guide'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Section(
              icon: LucideIcons.server,
              title: tr('What the server agent is'),
              paragraphs: [
                tr(
                  'The agent can run on a server of your own (a VPS) instead of on this phone. It then keeps working when the phone is off or the app is closed, and this app is its remote control: chats, files, previews, the terminal and deploys all go over one SSH connection.',
                ),
                tr(
                  'Everything lives on the server: chats, projects and background tasks. The agent on this phone keeps its own chats; switch between the two from the Agent row in Settings.',
                ),
              ],
            ),
            _Section(
              icon: LucideIcons.listOrdered,
              title: tr('Setting it up'),
              paragraphs: [
                tr(
                  'You need an Ubuntu or Debian server (x86_64 or arm64) with at least 2 cores, 4 GB of memory and 20 GB of disk, and root access once. Use a server for the agent only: its box shares the server\'s network.',
                ),
              ],
              steps: [
                tr('In the app: Settings, the Agent row. Enter the server\'s address.'),
                tr('Tap "Copy setup command". It holds the setup files and this phone\'s key.'),
                tr(
                  'On the server, as root, paste it into the terminal. It takes a few minutes and prints a setup code (griphub1:…). Run it again any time: it only repairs and updates.',
                ),
                tr('Paste the setup code in the app, then tap "Install / update agent".'),
                tr('Build the box on its screen, so the agent\'s commands run inside it.'),
              ],
            ),
            _Section(
              key: boxKey,
              icon: LucideIcons.box,
              title: tr('The box'),
              paragraphs: [
                tr(
                  'The box is a container (rootless Podman) on your server where the agent\'s commands run. Root inside it is only the griphub account outside, so a command cannot touch the rest of the server.',
                ),
              ],
              items: [
                (
                  tr('Run the agent\'s commands in the box'),
                  tr(
                    'On: every command the agent runs happens inside the box. Off: commands run directly on the server as the griphub account, without the box\'s walls. Leave it on unless the box cannot be built, or its commands hang (see When something goes wrong).',
                  ),
                ),
                (tr('Stop the box'), tr('Frees its memory. Nothing is lost; the next command starts it again.')),
                (
                  tr('Reset the box'),
                  tr('Throws the running container away and makes a fresh one. Projects in the workspace stay.'),
                ),
                (
                  tr('Rebuild the image'),
                  tr(
                    'Builds it again from the Containerfile on the server: after an update, or when tools are missing.',
                  ),
                ),
                (
                  tr('Empty the box\'s home folder'),
                  tr('Deletes its ssh and git settings, shell history and caches. Projects in the workspace stay.'),
                ),
                (tr('Limits'), tr('Memory, swap and CPUs for the box are set in ~/.griphub/box.conf on the server.')),
              ],
            ),
            _Section(
              icon: LucideIcons.activity,
              title: tr('Server health'),
              paragraphs: [tr('The table on the server screen, row by row:')],
              items: [
                (
                  tr('Agent version'),
                  tr(
                    '"Up to date", or "A newer one is in this app": tap "Install / update agent" on the same screen. "Restarts when the current work is done": the update is copied and waits for the work to end.',
                  ),
                ),
                (
                  tr('Disk free'),
                  tr(
                    'Turns orange under 10 GB free. Under 5 GB the agent refuses new prompts and tasks until you free space.',
                  ),
                ),
                (
                  tr('Agent memory'),
                  tr('How much the agent uses. Orange above 1.6 GB: the agent and its subagents share 2 GB.'),
                ),
                (tr('Running'), tr('Background tasks running now, and how many wait their turn.')),
                (tr('Subagents'), tr('Whether subagents are working right now.')),
                (tr('Up for'), tr('How long the agent has run since it last started.')),
                (
                  tr('Box'),
                  tr(
                    '"ready": commands run inside it. "off": on the server itself. "not built": commands are refused until you build it. "none": this server has no box.',
                  ),
                ),
              ],
            ),
            _Section(
              icon: LucideIcons.shieldCheck,
              title: tr('Automatic server backup'),
              paragraphs: [
                tr(
                  'Turn it on in Settings > Backup & restore. Every hour, when something changed, the server writes an encrypted backup of everything, API keys and each project\'s .git included, without dependencies. The newest comes to this phone while the app is open, and is offered when you switch back to the agent on this phone.',
                ),
                tr(
                  'The key is made on this phone and given to the server: the server needs it to write backups. A copy that leaves the phone or the server cannot be read without it.',
                ),
              ],
            ),
            SectionLabel(tr('When something goes wrong')),
            SurfaceCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: Column(
                  children: [
                    for (final (title, body) in serverTroubleshooting())
                      ExpansionTile(
                        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                        childrenPadding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                        expandedAlignment: Alignment.centerLeft,
                        title: Text(title, style: Theme.of(context).textTheme.bodyMedium),
                        children: [Text(body, style: Theme.of(context).textTheme.bodySmall)],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.icon,
    required this.title,
    this.paragraphs = const [],
    this.steps = const [],
    this.items = const [],
  });
  final IconData icon;
  final String title;
  final List<String> paragraphs;

  /// Numbered, in order.
  final List<String> steps;

  /// A name and what it means.
  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconTile(icon: icon, color: p.accent),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: text.titleSmall)),
              ],
            ),
            for (final para in paragraphs) ...[const SizedBox(height: 10), Text(para, style: text.bodyMedium)],
            for (final (i, step) in steps.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: p.raised, shape: BoxShape.circle),
                      child: Text('${i + 1}', style: text.labelSmall),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(step, style: text.bodyMedium)),
                  ],
                ),
              ),
            for (final (name, meaning) in items)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: text.labelLarge),
                    const SizedBox(height: 2),
                    Text(meaning, style: text.bodySmall),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
