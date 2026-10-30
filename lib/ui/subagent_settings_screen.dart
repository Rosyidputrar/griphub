import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import '../agent/pricing.dart';
import 'chat_extras.dart';
import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// Default limits, mirrored from the host (integrations.ts publicSettings).
const subagentDefaultCredits = 50.0;
const subagentDefaultMinutes = 30.0;

/// Longest time limit the custom field accepts (a day).
const _maxMinutes = 1440;

/// Highest cost limit the custom field accepts.
const _maxCredits = 100000;

String _credits(double v) => '${localNumber(formatCredits(v))} ${tr('credits')}';
String _minutes(double v) => '${v.toInt()} ${tr('min')}';

/// One line for both limits ("50 credits • 30 min", "No cost limit • No time limit"),
/// shared by this screen and its row in Settings.
String subagentLimitsSummary(AppSettings? s) {
  final cost = s?.subagentCreditLimit ?? subagentDefaultCredits;
  final time = s?.subagentMinutesLimit ?? subagentDefaultMinutes;
  return '${cost == 0 ? tr('No cost limit') : _credits(cost)} • ${time == 0 ? tr('No time limit') : _minutes(time)}';
}

/// The chat's approval modes, labelled like Settings → Agent behaviour.
Map<String, String> _approvalModes() => {'ask_all': tr('Ask all'), 'ask_risky': tr('Risky only'), 'auto': tr('Bypass all')};

/// Subagent settings: global cost/time limits (presets + free custom input),
/// approval mode (follow the chat, or its own), and notification toggles.
///
/// Limits are global for all subagents and are read by the host from Settings
/// at subagent start. There is deliberately no per-creation form: creating a
/// subagent is purely the parent's automatic action.
class SubagentSettingsScreen extends StatefulWidget {
  const SubagentSettingsScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<SubagentSettingsScreen> createState() => _SubagentSettingsScreenState();
}

class _SubagentSettingsScreenState extends State<SubagentSettingsScreen> {
  AgentController get agent => widget.agent;
  Integrations get it => agent.integrations;

  @override
  void initState() {
    super.initState();
    // Opened straight after boot, or after another device changed them.
    it.refreshSettings().catchError((_) => it.settings ?? AppSettings(const {}));
  }

  /// The subagents' approval setting being saved (`follow` for the switch, or a mode), shown as chosen with a spinner
  /// until the host has it; put back when saving failed.
  String? _approvalSaving;

  Future<void> _saveApproval(String pending, Map<String, dynamic> patch) async {
    if (_approvalSaving != null) return;
    setState(() => _approvalSaving = pending);
    try {
      await _save(patch);
    } finally {
      if (mounted) setState(() => _approvalSaving = null);
    }
  }

  Future<bool> _save(Map<String, dynamic> patch) async {
    try {
      await it.updateSettings(patch);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(e.toString()))));
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: it,
      builder: (context, _) {
        final s = it.settings;
        final cost = s?.subagentCreditLimit ?? subagentDefaultCredits;
        final time = s?.subagentMinutesLimit ?? subagentDefaultMinutes;
        final chatMode = s?.approvalMode ?? agent.approvalMode;
        final saving = _approvalSaving;
        final override = saving == null ? s?.subagentApprovalOverride ?? false : saving != 'follow';
        final mode = saving != null && saving != 'follow'
            ? saving
            : override
            ? (s?.subagentApprovalMode ?? chatMode)
            : chatMode;
        final compact = Appearance.instance.compact;
        final gap = compact ? 8.0 : 12.0;
        EdgeInsets label() => EdgeInsets.fromLTRB(4, compact ? 14 : 22, 4, compact ? 8 : 10);
        return Scaffold(
          appBar: AppBar(title: Text(tr('Subagent'))),
          body: ListView(
            padding: EdgeInsets.fromLTRB(16, 4, 16, compact ? 24 : 40),
            children: [
              SurfaceCard(
                padding: EdgeInsets.all(compact ? 14 : 18),
                child: Row(
                  children: [
                    IconTile(icon: LucideIcons.bot, color: p.accent, size: compact ? 36 : 40),
                    SizedBox(width: compact ? 12 : 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tr('Active limits'), style: text.titleMedium),
                          const SizedBox(height: 2),
                          AnimatedSwitcher(
                            duration: Motion.of(context, Motion.fast),
                            layoutBuilder: (current, previous) =>
                                Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                            child: Text(
                              subagentLimitsSummary(s),
                              key: ValueKey(subagentLimitsSummary(s)),
                              style: text.bodyMedium,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(tr('Limits apply to every subagent. Costs are estimates.'), style: text.bodySmall),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SectionLabel(tr('Cost limit'), padding: label()),
              _LimitChooser(
                key: const ValueKey('cost'),
                value: cost,
                presets: const [10, 25, 50],
                format: _credits,
                hint: tr('Credits, e.g. 40'),
                decimals: true,
                max: _maxCredits.toDouble(),
                onSave: (v) => _save({'subagentCreditLimit': v}),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(4, gap - 4, 4, 0),
                child: Text(
                  tr('A subagent stops at its next step once its estimated cost reaches the limit.'),
                  style: text.bodySmall,
                ),
              ),
              SectionLabel(tr('Time limit'), padding: label()),
              _LimitChooser(
                key: const ValueKey('time'),
                value: time,
                presets: const [15, 30, 60],
                format: _minutes,
                hint: tr('Minutes, e.g. 45'),
                decimals: false,
                max: _maxMinutes.toDouble(),
                onSave: (v) => _save({'subagentMinutesLimit': v}),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(4, gap - 4, 4, 0),
                child: Text(
                  tr('Counted from when the subagent starts; it then stops with a partial report.'),
                  style: text.bodySmall,
                ),
              ),
              SectionLabel(tr('Approvals'), padding: label()),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.link,
                    color: p.accent,
                    title: tr('Same as the chat'),
                    subtitle: '${tr('Chat setting')}: ${_approvalModes()[chatMode] ?? chatMode}',
                    onTap: saving != null ? null : () => _setFollow(override, chatMode),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (saving != null) ...[const BusySpinner(), const SizedBox(width: 8)],
                        Switch(
                          value: !override,
                          onChanged: saving != null ? null : (v) => _setFollow(v, chatMode),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              AnimatedSize(
                duration: Motion.of(context, Motion.normal),
                curve: Motion.curve,
                alignment: Alignment.topCenter,
                child: override
                    ? Padding(
                        padding: EdgeInsets.only(top: gap),
                        child: IgnorePointer(
                          ignoring: saving != null,
                          child: PillSegments<String>(
                            value: mode,
                            options: _approvalModes(),
                            onChanged: (v) async {
                              if (v == 'auto' && !await confirmBypass(context)) return;
                              await _saveApproval(v, {'subagentApprovalMode': v});
                            },
                          ),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              AnimatedSize(
                duration: Motion.of(context, Motion.normal),
                curve: Motion.curve,
                alignment: Alignment.topCenter,
                child: mode == 'auto'
                    ? Padding(
                        padding: EdgeInsets.fromLTRB(4, gap, 4, 0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Icon(LucideIcons.shieldOff, size: 14, color: p.warning),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                tr('Subagents run every command and edit any file without asking.'),
                                style: text.bodySmall?.copyWith(color: p.warning),
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              SectionLabel(tr('Notifications'), padding: label()),
              SettingsGroup(
                children: [
                  _Toggle(
                    icon: LucideIcons.loaderCircle,
                    color: p.accent,
                    title: tr('Subagent running'),
                    subtitle: tr('While their chat is not on screen'),
                    value: s?.subagentNotifyRunning ?? true,
                    onChanged: (v) => _save({'subagentNotifyRunning': v}),
                  ),
                  _Toggle(
                    icon: LucideIcons.circleCheck,
                    color: p.success,
                    title: tr('Subagent finished'),
                    value: s?.subagentNotifyDone ?? true,
                    onChanged: (v) => _save({'subagentNotifyDone': v}),
                  ),
                  _Toggle(
                    icon: LucideIcons.circleX,
                    color: p.danger,
                    title: tr('Subagent failed'),
                    value: s?.subagentNotifyFailed ?? true,
                    onChanged: (v) => _save({'subagentNotifyFailed': v}),
                  ),
                  _Toggle(
                    icon: LucideIcons.shieldQuestion,
                    color: p.warning,
                    title: tr('Approval requested'),
                    value: s?.subagentNotifyApproval ?? true,
                    onChanged: (v) => _save({'subagentNotifyApproval': v}),
                  ),
                ],
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(4, gap, 4, 0),
                child: Text(
                  tr(
                    'Notifications never show the chat, the task or results; tapping one opens the parent chat. They appear when that chat is not on screen.',
                  ),
                  style: text.bodySmall,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// On: forget the subagent mode so subagents follow the chat. Off: start
  /// from the chat's current mode, which the segments below then change.
  Future<void> _setFollow(bool follow, String chatMode) async {
    HapticFeedback.selectionClick();
    await _saveApproval(follow ? 'follow' : chatMode, {'subagentApprovalMode': follow ? null : chatMode});
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.icon,
    required this.color,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SettingsRow(
    icon: icon,
    color: color,
    title: title,
    subtitle: subtitle,
    onTap: () => onChanged(!value),
    trailing: Switch(value: value, onChanged: onChanged),
  );
}

/// Preset chips, "No limit" and "Custom". Exactly one chip is selected: the
/// value's preset, No limit, or Custom (also while the custom field is open).
/// The custom field opens prefilled with the current value and checks the
/// number inline.
class _LimitChooser extends StatefulWidget {
  const _LimitChooser({
    super.key,
    required this.value,
    required this.presets,
    required this.format,
    required this.hint,
    required this.decimals,
    required this.max,
    required this.onSave,
  });

  final double value;
  final List<int> presets;
  final String Function(double) format;
  final String hint;
  final bool decimals;
  final double max;
  final Future<bool> Function(num value) onSave;

  @override
  State<_LimitChooser> createState() => _LimitChooserState();
}

class _LimitChooserState extends State<_LimitChooser> {
  final _field = TextEditingController();
  final _focus = FocusNode();
  bool _open = false;
  String? _error;

  bool get _isPreset => widget.presets.any((p) => p == widget.value);
  bool get _isNone => widget.value == 0;
  bool get _isCustom => !_isPreset && !_isNone;

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _toggleCustom() {
    setState(() {
      _open = !_open;
      _error = null;
      if (_open) {
        // Start from the current value; a preset is a fine starting point too.
        final v = widget.value;
        _field.text = v == 0 ? '' : localNumber(widget.decimals ? formatCredits(v) : '${v.toInt()}');
        _field.selection = TextSelection(baseOffset: 0, extentOffset: _field.text.length);
      }
    });
    if (_open) _focus.requestFocus();
  }

  Future<void> _pick(num v) async {
    HapticFeedback.selectionClick();
    setState(() {
      _open = false;
      _error = null;
    });
    await widget.onSave(v);
  }

  Future<void> _apply() async {
    final v = parseLocalNumber(_field.text);
    String? error;
    if (v == null || v <= 0) {
      error = widget.decimals ? tr('Enter a number above 0.') : tr('Enter a whole number of minutes, 1 or more.');
    } else if (!widget.decimals && v != v.roundToDouble()) {
      error = tr('Enter a whole number of minutes, 1 or more.');
    } else if (v > widget.max) {
      error = tr('At most {n}.').replaceAll('{n}', localNumber(formatCredits(widget.max)));
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final value = widget.decimals ? v! : v!.round();
    if (await widget.onSave(value) && mounted) {
      _focus.unfocus();
      setState(() {
        _open = false;
        _error = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget chip(String label, bool selected, VoidCallback onTap, {IconData? icon}) => ChoiceChip(
      label: Text(label),
      avatar: icon == null ? null : Icon(icon, size: 16, color: selected ? p.inverse : p.text),
      selected: selected,
      showCheckmark: false,
      labelStyle: Theme.of(context).textTheme.labelLarge?.copyWith(color: selected ? p.inverse : p.text),
      onSelected: (_) => onTap(),
    );

    final customSelected = _open || _isCustom;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Chips keep their 48dp tap target, which already spaces the rows.
        Wrap(
          spacing: 8,
          children: [
            for (final preset in widget.presets)
              chip(widget.format(preset.toDouble()), !_open && widget.value == preset, () => _pick(preset)),
            chip(tr('No limit'), !_open && _isNone, () => _pick(0), icon: LucideIcons.infinity),
            chip(
              _isCustom && !_open ? '${tr('Custom')}: ${widget.format(widget.value)}' : tr('Custom'),
              customSelected,
              _toggleCustom,
              icon: LucideIcons.pencil,
            ),
          ],
        ),
        AnimatedSize(
          duration: Motion.of(context, Motion.normal),
          curve: Motion.curve,
          alignment: Alignment.topCenter,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _field,
                          focusNode: _focus,
                          keyboardType: TextInputType.numberWithOptions(decimal: widget.decimals),
                          textInputAction: TextInputAction.done,
                          decoration: InputDecoration(hintText: widget.hint, errorText: _error, errorMaxLines: 2),
                          onChanged: (_) {
                            if (_error != null) setState(() => _error = null);
                          },
                          onSubmitted: (_) => _apply(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: _apply, child: Text(tr('Use'))),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
