import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/models.dart';
import 'i18n.dart';
import 'kit.dart';
import 'sheet.dart';
import 'theme.dart';

/// The status of a check in words, for the evidence block and the closing message's footer.
String verifyStatusLabel(String status) => switch (status) {
  'passed' => tr('Tests passed'),
  'failed' => tr('Tests failed'),
  'tests-changed' => tr('Not accepted: tests were changed'),
  'passed-tests-changed' => tr('Passed, with tests this task changed'),
  'setup-changed' => tr('Not run: the task changed how tests run'),
  'unmeasured' => tr('Not checked: changes could not be measured'),
  'declined' => tr('Not run: not allowed'),
  _ => tr('No test could be run for this project'),
};

Color _statusColor(Palette p, String status) => switch (status) {
  'passed' => p.success,
  'failed' || 'tests-changed' => p.danger,
  _ => p.warning,
};

IconData _statusIcon(String status) => switch (status) {
  'passed' => LucideIcons.circleCheck,
  'failed' || 'tests-changed' => LucideIcons.circleX,
  _ => LucideIcons.circleDashed,
};

String _seconds(Duration d) => '${localNumber((d.inMilliseconds / 1000).toStringAsFixed(1))} ${tr('s')}';

/// Evidence of self-verification in the chat (agent/src/verify.ts): what ran, how it ended, the end of its output and
/// how long it took. A block of its own, set apart from tool cards by its frame; the whole output opens in a sheet.
class VerifyEvidenceView extends StatelessWidget {
  const VerifyEvidenceView(this.entry, {super.key, this.agent});
  final VerifyEntry entry;
  final AgentController? agent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final e = entry;
    final color = _statusColor(p, e.status);
    final ran = e.exitCode != null || e.status == 'passed' || e.status == 'failed' || e.status == 'passed-tests-changed';
    final meta = [
      if (e.command != null) e.command!,
      if (ran) _seconds(e.took),
      if (ran && e.exitCode != null) tr('exit code {n}').replaceAll('{n}', '${e.exitCode}'),
      if (e.timedOut) tr('stopped: took too long'),
    ].join(' · ');
    final after = e.next == 'fix'
        ? tr('The agent fixes it now; the check runs again ({n} of {max}).')
              .replaceAll('{n}', '${e.round + 1}')
              .replaceAll('{max}', '${e.maxRounds}')
        : null;
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The status is the title; its icon sits on that line.
          // What this block is, quietly above; the status is the title, at full width, its icon on its first line.
          Text(tr('Verification evidence'), style: text.bodySmall?.copyWith(color: p.muted)),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: Icon(_statusIcon(e.status), size: 18, color: color)),
              const SizedBox(width: 8),
              Expanded(child: Text(verifyStatusLabel(e.status), style: text.titleSmall)),
            ],
          ),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(meta, style: text.bodySmall?.copyWith(color: p.muted, fontFamily: mono)),
          ],
          if (e.status == 'none')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                tr('The changes were not checked by tests. You can set a check command for this project in its tools.'),
                style: text.bodySmall?.copyWith(color: p.muted),
              ),
            ),
          if (e.status == 'declined')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(tr('The check was not allowed to run, so the changes are not verified.'), style: text.bodySmall?.copyWith(color: p.muted)),
            ),
          if (e.status == 'unmeasured' || e.status == 'setup-changed')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                tr(e.status == 'unmeasured'
                    ? 'The app could not tell what changed in the folder, so nothing was checked.'
                    : 'A test setup the task changed is not run by the app. Check it yourself before trusting the change.'),
                style: text.bodySmall?.copyWith(color: p.muted),
              ),
            ),
          if (e.testsTouched.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${tr(e.status == 'tests-changed' ? 'Test files changed while fixing:' : 'Tests changed by this task:')} ${e.testsTouched.join(', ')}',
                style: text.bodySmall?.copyWith(color: p.muted),
              ),
            ),
          if (ran && e.summary.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.md)),
              child: Text(
                _lastLines(e.summary, 8),
                style: TextStyle(fontFamily: mono, fontSize: 12, color: p.text, height: 1.35),
              ),
            ),
            if (e.outputId != null && agent != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _showFull(context),
                  icon: const Icon(LucideIcons.scrollText, size: 16),
                  label: Text(tr('Full output')),
                ),
              ),
          ],
          if (after != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(after, style: text.bodySmall?.copyWith(color: p.muted)),
            ),
        ],
      ),
    );
  }

  static String _lastLines(String s, int n) {
    final lines = s.split('\n');
    return lines.length <= n ? s : lines.sublist(lines.length - n).join('\n');
  }

  Future<void> _showFull(BuildContext context) => showSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _FullOutput(agent: agent!, id: entry.outputId!, command: entry.command ?? ''),
  );
}

class _FullOutput extends StatefulWidget {
  const _FullOutput({required this.agent, required this.id, required this.command});
  final AgentController agent;
  final String id;
  final String command;

  @override
  State<_FullOutput> createState() => _FullOutputState();
}

class _FullOutputState extends State<_FullOutput> {
  late final Future<String> _output = widget.agent.verifyOutput(widget.id);

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SheetExtent(
      initial: 0.8,
      max: 0.95,
      builder: (context, scroll) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(widget.command, style: TextStyle(fontFamily: mono, fontSize: 13, color: p.muted)),
          ),
          Expanded(
            child: FutureBuilder<String>(
              future: _output,
              builder: (context, snap) {
                if (snap.hasError) return Center(child: ErrorNotice(error: snap.error));
                if (!snap.hasData) return const Center(child: BusySpinner.page());
                return SingleChildScrollView(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  child: SelectableText(snap.data!, style: TextStyle(fontFamily: mono, fontSize: 12, color: p.text, height: 1.35)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The closing message's word on the turn's last evidence: one quiet line above its footer.
class VerifyStatusNote extends StatelessWidget {
  const VerifyStatusNote({super.key, required this.entry});
  final VerifyEntry entry;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // On the first line, however many lines the note takes.
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(_statusIcon(entry.status), size: 13, color: p.faint)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${tr('Verification')}: ${verifyStatusLabel(entry.status)}${entry.command == null ? '' : ' · ${entry.command}'}',
            style: TextStyle(fontSize: 11.5, color: p.faint),
          ),
        ),
      ],
    );
  }
}
