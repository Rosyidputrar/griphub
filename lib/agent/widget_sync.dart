import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'agent_controller.dart';
import 'features.dart';
import 'models.dart';

/// The home-screen widgets' view of the app (Fitur 7; android Widgets.kt): the real state of the chat, background
/// jobs, subagents, tasks, approvals and credits, sent to the widgets whenever it changes. Nothing polls: the
/// snapshot follows the app's own change notifications, a second apart at most.
class WidgetSync {
  WidgetSync(
    this.agent, {
    required this.translate,
    String Function(String)? number,
    this.dark,
    this.private,
    this.send,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       number = number ?? ((s) => s);

  final AgentController agent;

  /// The app's language for the widgets' texts.
  final String Function(String) translate;

  /// A number in the app's language ("1,5" in Indonesian), as the app shows it (i18n.dart localNumber).
  final String Function(String) number;

  /// The app's theme: dark or not (the widgets follow it).
  final bool Function()? dark;

  /// App lock is on: the home screen (outside the lock) shows that work goes on, never what it is about (no chat,
  /// job, task or schedule names). Commands are never shown there, lock or not.
  final bool Function()? private;

  /// Where the snapshot goes; the platform side by default.
  final Future<void> Function(String json)? send;
  final DateTime Function() _now;

  Timer? _debounce;
  String? _last;
  Listenable? _listening;

  static const _method = MethodChannel('griphub/agent');

  /// Starts following the app; [also] are more things to follow (settings, theme).
  void start({List<Listenable> also = const []}) {
    _listening = Listenable.merge([agent, agent.features, agent.integrations, ...also]);
    _listening!.addListener(_changed);
    _changed();
  }

  void dispose() {
    _listening?.removeListener(_changed);
    _debounce?.cancel();
  }

  void _changed() {
    if (_debounce?.isActive ?? false) return;
    _debounce = Timer(const Duration(milliseconds: 800), push);
  }

  /// Sends the snapshot now, when it differs from the last one sent.
  Future<void> push() async {
    final json = jsonEncode(snapshot());
    // The time alone changing is not a change.
    final key = json.replaceFirst(RegExp(r'"at":\d+'), '');
    if (key == _last) return;
    try {
      await (send ?? (j) => _method.invokeMethod('widgetState', j))(json);
      // Only what reached the widgets counts as sent: after a failure the next change (or the same state) goes again.
      _last = key;
    } on MissingPluginException {
      // No platform side (tests, desktop).
      _last = key;
    } catch (_) {
      // The widgets keep their last snapshot; this one is sent again on the next push.
    }
  }

  /// What the widgets show now.
  @visibleForTesting
  Map<String, dynamic> snapshot() {
    final t = translate;
    final now = _now();
    final hide = private?.call() ?? false;
    final rows = <Map<String, dynamic>>[];
    Map<String, dynamic> chat(String? path) => {'action': 'open_chat', 'path': ?path};
    const tasks = {'action': 'open_tasks'};

    // The chat at work.
    if (agent.busy) {
      final started = agent.turnStartedAt;
      rows.add({
        'kind': 'session',
        'title': hide ? t('The agent is working') : t('Working in {chat}').replaceAll('{chat}', agent.chatTitle),
        'sub': agent.verifying != null
            ? t('Running the project\'s check')
            : started == null
            ? ''
            : t('For {time}').replaceAll('{time}', _duration(now.difference(started))),
        'launch': chat(agent.sessionFile),
      });
    }
    // Background jobs, newest first.
    final jobs = agent.jobStore.all.where((j) => j.running).toList()..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    for (final j in jobs.take(2)) {
      rows.add({
        'kind': 'job',
        'title': hide || j.label.isEmpty ? t('Background job') : j.label,
        // The kind is said once: in the title when the job has no name of its own.
        'sub': (hide || j.label.isEmpty ? t('For {time}') : t('Background job · {time}')).replaceAll('{time}', _duration(now.difference(j.startedAt))),
        'launch': chat(j.sessionFile),
      });
    }
    if (jobs.length > 2) {
      rows.add({'kind': 'job', 'title': t('{n} more background jobs').replaceAll('{n}', '${jobs.length - 2}'), 'sub': '', 'launch': tasks});
    }
    // Subagents, by the chat they work for.
    final subs = agent.subagentStore.all.where((s) => s.isActive).toList();
    final byChat = <String, List<dynamic>>{};
    for (final s in subs) {
      byChat.putIfAbsent(s.parentSessionFile, () => []).add(s);
    }
    for (final e in byChat.entries) {
      final title = hide || (e.value.first.parentTitle as String).isEmpty ? t('a chat') : e.value.first.parentTitle as String;
      rows.add({
        'kind': 'subagent',
        'title': e.value.length == 1 ? t('A subagent is working') : t('{n} subagents are working').replaceAll('{n}', '${e.value.length}'),
        'sub': t('For {chat}').replaceAll('{chat}', title),
        'launch': chat(e.key),
      });
    }
    // Background tasks running now.
    for (final r in agent.features.runs.where((r) => r.active).take(2)) {
      rows.add({'kind': 'job', 'title': hide ? t('Background task') : r.title, 'sub': hide ? '' : t('Background task'), 'launch': tasks});
    }
    // The next scheduled task.
    final next = nextScheduled(agent.features.schedules, now);
    if (next != null) {
      rows.add({
        'kind': 'schedule',
        'title': hide ? t('Scheduled task') : next.$1.name,
        'sub': t('Next at {time}').replaceAll('{time}', _clock(next.$2, now)),
        'launch': tasks,
      });
    }

    final model = agent.smartRouter.auto
        ? (agent.routingLog.lastWhere((d) => d.kind == 'route', orElse: () => RoutingDecision(const {})).modelName ?? agent.model?.name)
        : agent.model?.name;
    final balance = agent.integrations.router?.balance;
    final approvals = agent.features.approvals.length;
    return {
      'at': now.millisecondsSinceEpoch,
      if (dark != null) 'dark': dark!(),
      'credits': balance == null ? '' : t('{n} credits').replaceAll('{n}', _credits(balance)),
      'model': model == null ? '' : (agent.smartRouter.auto ? '$model · ${t('automatic')}' : model),
      'approvals': approvals,
      'approvalsLabel': t('{n} waiting for your approval').replaceAll('{n}', '$approvals'),
      'approvalsLaunch': chat(agent.sessionFile),
      'rows': rows,
      'empty': t('Nothing running'),
      'emptySub': next == null
          ? ''
          : hide
          ? t('Next task at {time}').replaceAll('{time}', _clock(next.$2, now))
          : t('Next task: {name} at {time}').replaceAll('{name}', next.$1.name).replaceAll('{time}', _clock(next.$2, now)),
      'askHint': t('Ask anything…'),
      'askLabel': t('Ask'),
      'voiceLabel': t('Voice'),
      'modelLabel': t('Choose model'),
      'updatedLabel': t('Updated {time}'),
    };
  }

  /// The scheduled task that runs next, and when; null when none is on.
  static (ScheduleInfo, DateTime)? nextScheduled(List<ScheduleInfo> schedules, DateTime now) {
    (ScheduleInfo, DateTime)? best;
    for (final s in schedules.where((s) => s.enabled)) {
      DateTime? at;
      final daily = s.dailyAt;
      if (daily != null && RegExp(r'^\d{1,2}:\d{2}$').hasMatch(daily)) {
        final [h, m] = daily.split(':').map(int.parse).toList();
        at = DateTime(now.year, now.month, now.day, h, m);
        if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
      } else if (s.everyMinutes case final every? when every > 0) {
        final last = s.lastRun ?? now;
        at = last.add(Duration(minutes: every));
        if (at.isBefore(now)) at = now;
      }
      if (at != null && (best == null || at.isBefore(best.$2))) best = (s, at);
    }
    return best;
  }

  /// "1h 5m", "12m", "40s" in the app's language.
  String _duration(Duration d) {
    if (d.inHours >= 1) return translate('{h}h {m}m').replaceAll('{h}', '${d.inHours}').replaceAll('{m}', '${d.inMinutes % 60}');
    if (d.inMinutes >= 1) return translate('{m}m').replaceAll('{m}', '${d.inMinutes}');
    return translate('{s}s').replaceAll('{s}', '${d.inSeconds.clamp(0, 59)}');
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// "14:00", with the day when it is not today.
  static String _clock(DateTime at, DateTime now) {
    final time = '${_two(at.hour)}:${_two(at.minute)}';
    final sameDay = at.year == now.year && at.month == now.month && at.day == now.day;
    return sameDay ? time : '${at.day}/${at.month} $time';
  }

  String _credits(double v) => number(v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(v >= 10 ? 1 : 2));
}
