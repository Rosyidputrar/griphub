import 'dart:async';

import 'package:flutter/foundation.dart';

import 'agent_client.dart';
import 'agent_fs.dart';
import 'features.dart';
import 'integrations.dart';
import 'models.dart';
import 'remote_mode.dart';
import 'sent_attachments.dart';
import 'subagent_notifications.dart';
import 'subagents.dart';
import 'todos.dart';

enum BootStatus { starting, ready, failed }

/// App-wide agent state: boot, the active session's transcript rebuilt from
/// pi's event stream, and model/provider selection.
class AgentController extends ChangeNotifier {
  AgentController(this.client) : features = Features(client) {
    client.records.listen(_onRecord);
  }

  final AgentClient client;
  late final integrations = Integrations(client);

  /// Made with the controller, not on first use: it keeps approvals and runs from the host's records, and one that
  /// arrived before anything looked at it would be lost.
  final Features features;

  /// The server agent, when the user set one up (server_agent.md). The phone's own agent otherwise.
  late final remote = RemoteMode(this);

  /// The files the agent works on: this phone's, or the server's over the link ([RemoteMode] sets it).
  AgentFs fs = const LocalFs();

  BootStatus status = BootStatus.starting;
  String? bootError;

  /// Failed starts in a row (0 once one works): how long the server boot screen waits before trying again.
  int bootFailures = 0;
  Map<String, dynamic> info = const {};

  // Session state
  ModelInfo? model;
  String thinkingLevel = 'off';
  List<String> thinkingLevels = const ['off'];
  String? sessionId;
  String? sessionName;
  String? sessionFile;
  String cwd = '';
  bool busy = false;

  /// Set when the current model is billed differently than the user may expect.
  String? billingNotice;

  /// Plan mode: the agent plans first and changes nothing until approved.
  bool planMode = false;
  String approvalMode = 'ask_risky';

  final entries = <ChatEntry>[];
  final tools = <String, ToolRun>{};

  /// Live subagents, mirrored from the host's subagent_* records. They are
  /// never transcript entries: the card list is rendered from here.
  final subagentStore = SubagentStore();

  /// The UI language for texts the controller produces (notifications). The
  /// app sets it to `tr`; tests and the default keep English.
  String Function(String) translate = (s) => s;

  late final subagentNotifier = SubagentNotifier(
    notify: client.notify,
    cancel: client.cancelNotification,
    translate: (s) => translate(s),
  );

  /// Set by the home shell from the app lifecycle. While the app is in the
  /// background nothing is on screen, so the open chat's subagents notify too.
  bool get inBackground => _inBackground;
  bool _inBackground = false;
  set inBackground(bool v) {
    if (v == _inBackground) return;
    _inBackground = v;
    // A server agent hears it in its next ping and pushes instead of staying quiet (notify.ts).
    client.inBackground = v;
    unawaited(_syncRunningNotification());
  }

  /// Whether [s] belongs to the open chat.
  bool _subagentIsOpen(SubagentState s) => s.parentSessionFile == sessionFile || s.parentSessionFile == sessionId;

  /// Whether nobody is looking at [s]'s card right now.
  bool _subagentUnseen(SubagentState s) => _inBackground || !_subagentIsOpen(s);

  /// Settings drive the notification toggles. They are loaded at boot, but a
  /// record can arrive first; then they are fetched before deciding.
  Future<AppSettings?> _subagentSettings() async =>
      integrations.settings ?? await integrations.refreshSettings().then<AppSettings?>((s) => s).catchError((_) => null);

  Future<void> _syncRunningNotification() async {
    final settings = await _subagentSettings();
    await subagentNotifier.syncRunning(
      subagentStore.all.where((s) => s.isActive && _subagentUnseen(s)).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
      enabled: settings?.subagentNotifyRunning ?? true,
    );
  }

  /// Drives notifications from a subagent record. Only subagents nobody is
  /// looking at notify; an open chat in the foreground already shows its cards.
  /// [answeredApproval] is the request the record ended (if any).
  Future<void> _syncSubagentNotifications(Map<String, dynamic> record, String? answeredApproval) async {
    if (answeredApproval != null) unawaited(subagentNotifier.cancelApproval(answeredApproval));
    switch (record['type']) {
      // Membership changes only: tool events stream far too often to
      // re-post a notification for, and they never change the set.
      case 'subagent_started' || 'subagent_status' || 'subagent_queued':
        await _syncRunningNotification();
      case 'subagent_finished':
        final s = subagentStore[(record['subagent'] as Map)['id'] as String? ?? ''];
        await _syncRunningNotification();
        if (s != null && _subagentUnseen(s)) {
          final settings = await _subagentSettings();
          await subagentNotifier.notifyFinished(
            s,
            notifyDone: settings?.subagentNotifyDone ?? true,
            notifyFailed: settings?.subagentNotifyFailed ?? true,
          );
        }
      case 'subagent_approval_request':
        final s = subagentStore[record['subagentId'] as String? ?? ''];
        final ap = s?.approval;
        if (s != null && ap != null && _subagentUnseen(s)) {
          final settings = await _subagentSettings();
          // Still pending after the settings round-trip?
          if (s.approval?.approvalId != ap.approvalId) return;
          await subagentNotifier.notifyApproval(s, ap, enabled: settings?.subagentNotifyApproval ?? true);
        }
    }
  }

  /// Re-reads the host's live subagents (after a reconnect or restart of the app side).
  Future<void> refreshSubagents() async {
    final list = await client.call<List>('subagent_list');
    for (final r in list.whereType<Map>()) {
      final rec = r.cast<String, dynamic>();
      subagentStore.applyRecord({'type': 'subagent_started', 'subagent': rec});
      if (rec['status'] != 'queued' && rec['status'] != 'running' && rec['status'] != 'waiting_approval' && rec['status'] != 'stopping') {
        subagentStore.applyRecord({'type': 'subagent_finished', 'subagent': rec});
      }
    }
    notifyListeners();
  }

  /// Reloads everything after a server link came back without being able to replay what it missed (the buffer had
  /// moved on, or the server's host was restarted): the chat, subagents, approvals still waiting, and background runs.
  /// On the phone this never happens.
  Future<void> resync() async {
    try {
      _applyState(await client.call<Map<String, dynamic>>('state'));
      _streaming = null;
      await loadHistory();
      await refreshSubagents();
      await restoreApprovals();
      await features.refreshRuns().catchError((_) {});
      unawaited(integrations.refresh().catchError((_) {}));
      notifyListeners();
    } catch (_) {
      // Dropped again before it finished: the next reconnect asks again.
    }
  }

  /// Shows again what still waits for an answer, chat and subagents alike (`approvals_pending`), and forgets cards the
  /// host no longer waits on.
  Future<void> restoreApprovals() async {
    final pending = (await client.call<List>('approvals_pending'))
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    features.replaceApprovals(pending);
    final waiting = {
      for (final r in pending.where((r) => r['type'] == 'subagent_approval_request')) r['subagentId'] as String?: r,
    };
    for (final s in subagentStore.all) {
      final r = waiting[s.id];
      if (r != null) {
        subagentStore.applyRecord(r);
      } else if (s.approval != null) {
        subagentStore.applyRecord({
          'type': 'subagent_approval_dismiss',
          'subagentId': s.id,
          'approvalId': s.approval!.approvalId,
        });
      }
    }
    notifyListeners();
  }

  /// Subagents of the open chat, oldest first.
  List<SubagentState> get subagentsForCurrent => subagentStore.forParent(file: sessionFile, id: sessionId);

  /// Active subagents of other chats (for the cross-chat banner).
  List<SubagentState> get subagentsElsewhere => subagentStore.runningElsewhere(file: sessionFile, id: sessionId);

  /// Stops a subagent gracefully ([force] aborts it immediately instead).
  Future<void> stopSubagent(String id, {bool force = false}) =>
      client.call('subagent_stop', {'subagentId': id, 'force': force});

  /// Queues a message for a running subagent; it is sent at the next safe boundary.
  Future<void> queueSubagentMessage(String id, String text) =>
      client.call('subagent_queue', {'subagentId': id, 'text': text});

  Future<void> removeQueuedSubagentMessage(String id, String queueId) =>
      client.call('subagent_queue_remove', {'subagentId': id, 'queueId': queueId});

  Future<void> moveQueuedSubagentMessage(String id, String queueId, String direction) =>
      client.call('subagent_queue_move', {'subagentId': id, 'queueId': queueId, 'direction': direction});

  /// Answers a subagent's approval request; [always] also allows the same
  /// action ([key]) for the rest of this app run, like the chat's approvals.
  Future<void> replySubagentApproval(String id, String approvalId, bool allow, {bool always = false, String? key}) =>
      client.call('subagent_approval_reply', {
        'subagentId': id,
        'approvalId': approvalId,
        'allow': allow,
        'always': always,
        'key': ?key,
      });

  /// Plans the user closed (todo_write call ids); kept for the app's lifetime.
  final _dismissedPlans = <String>{};
  Object? _todoKey;
  TodoState? _todo;

  /// The agent's plan for the chat (see currentPlan), worked out once per change rather than on every rebuild.
  TodoState? get todo {
    final last = entries.lastOrNull;
    final key = (
      sessionId,
      entries.length,
      identityHashCode(last),
      last is AssistantEntry ? (last.streaming, last.blocks.length) : null,
      tools.length,
      tools.values.where((t) => t.status == ToolStatus.failed).length,
      _dismissedPlans.length,
    );
    if (key == _todoKey) return _todo;
    _todoKey = key;
    _todo = currentPlan(entries, tools: tools, dismissed: _dismissedPlans, saved: PlanStore.instance.recall(sessionId));
    // Kept on disk so the plan outlives compaction.
    if (_todo case final t? when t.currentTurn) PlanStore.instance.remember(sessionId, t);
    return _todo;
  }

  /// Hides a plan from an earlier turn that no longer applies.
  void dismissPlan(String id) {
    _dismissedPlans.add(id);
    notifyListeners();
  }

  List<ProviderInfo> providers = const [];
  List<ModelInfo> models = const [];

  /// Login prompts and notices from pi's auth flow, handled by the UI.
  final authRecords = StreamController<Map<String, dynamic>>.broadcast();

  AssistantEntry? _streaming;
  Timer? _notifyTimer;

  bool get hasModel => model != null;

  /// The display name for a model id from a transcript ("claude-sonnet-5-5" -> "Claude Sonnet 5.5"),
  /// or the id itself when the model isn't in the list.
  String modelLabel(String id) {
    if (model?.id == id) return model!.name;
    for (final m in models) {
      if (m.id == id) return m.name;
    }
    return id;
  }

  /// The tool the agent is running right now, for the ongoing notification.
  String? runningTool;

  // -------------------------------------------------------------------------
  // Lifecycle

  Future<void> boot() async {
    status = BootStatus.starting;
    bootError = null;
    notifyListeners();
    try {
      await client.start();
      info = await client.call<Map<String, dynamic>>('hello');
      _applyState(info);
      await Future.wait([loadHistory(), refreshProviders()]);
      unawaited(integrations.refresh().then((_) => integrations.refreshProjects()).catchError((_) {}));
      // Notification toggles and limits must be known before the first subagent record.
      unawaited(integrations.refreshSettings().then((_) {}).catchError((_) {}));
      // A server agent may have been waiting for answers while the app was closed: show them again.
      unawaited(refreshSubagents().then((_) => client.isRemote ? restoreApprovals() : null).catchError((_) {}));
      // A server keeps its own clock (UTC as a rule): schedules follow the phone's time zone instead.
      if (client.isRemote) {
        unawaited(
          client
              .call('timezone_set', {'offsetMinutes': DateTime.now().timeZoneOffset.inMinutes})
              .then((_) {})
              .catchError((_) {}),
        );
      }
      status = BootStatus.ready;
      bootFailures = 0;
    } catch (e) {
      status = BootStatus.failed;
      bootFailures++;
      final tail = client.stderrTail;
      bootError = [
        e.toString(),
        if (tail.isNotEmpty) tail.skip(tail.length > 20 ? tail.length - 20 : 0).join('\n'),
      ].join('\n\n');
    }
    notifyListeners();
  }

  Future<void> restart() async {
    status = BootStatus.starting;
    notifyListeners();
    await client.stop();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await boot();
  }

  // -------------------------------------------------------------------------
  // Conversation

  /// Sends a chat message. Returns false when the host refuses it (budget,
  /// no model, host error): the caller must then keep the text, because a
  /// refused message never reaches the transcript and would otherwise be
  /// lost. The failure itself is shown as a notice.
  Future<bool> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    try {
      _noteQueued(await client.call<Object?>('prompt', {'text': trimmed}));
      return true;
    } on AgentError catch (e) {
      _addNotice(e.message, error: true);
      return false;
    }
  }

  Future<void> abort() => client.call('abort');

  /// Work a switch between this phone and a server would cut off: the chat's turn, subagents, queued or running runs.
  bool get working => busy || subagentStore.all.any((s) => s.isActive) || features.runs.any((r) => r.active);

  /// The host refuses to switch chats mid-turn with this message (host.ts BUSY_SWITCH).
  static const busySwitchError = 'The agent is still working in this chat. Stop it before switching chats.';

  /// Asks the user whether to stop the running turn to switch chats; set by
  /// the home shell (it owns a navigator). Null or false keeps the turn.
  Future<bool> Function()? confirmStopToSwitch;

  /// How long Stop and switch waits for the running turn to end (a stuck tool gets this long).
  @visibleForTesting
  static Duration stopToSwitchTimeout = const Duration(seconds: 10);

  /// Whether a chat switch may go ahead: always when idle; while the agent
  /// works only if the user agrees to stop it, then once it has stopped.
  Future<bool> readyToSwitch() async {
    if (!busy) return true;
    final ask = confirmStopToSwitch;
    if (ask == null || !await ask()) return false;
    stoppingToSwitch = true;
    notifyListeners();
    try {
      await abort();
      // The turn ends on the host's agent_settled; wait for it, in steps, up to the timeout.
      const step = Duration(milliseconds: 100);
      for (var waited = Duration.zero; busy && waited < stopToSwitchTimeout; waited += step) {
        await Future<void>.delayed(step);
      }
    } catch (_) {
      // The abort itself failed (the link dropped): the turn is still running, which is said below.
    } finally {
      stoppingToSwitch = false;
      notifyListeners();
    }
    if (busy) switchProblems.add('The agent did not stop in time. Try again in a moment.');
    return !busy;
  }

  /// Where a chat switch is going while one runs: the chat's path, or `new:<folder>` for a new chat. One at a time: a
  /// second tap while the first still waits on the host does nothing, so chats are never opened twice or on top of
  /// each other. Rows show a spinner for the one being opened.
  String? switchingTo;

  /// The switch waits for the running turn to stop (the user chose Stop and switch).
  bool stoppingToSwitch = false;

  /// Why a switch did not happen, for the user (English; the app translates it).
  final switchProblems = StreamController<String>.broadcast();

  /// The [switchingTo] key of a new chat in [dir].
  static String newChatKey(String? dir) => 'new:${dir ?? ''}';

  /// Runs one switch to [target]; false when another is already running or the user kept the running turn.
  Future<bool> _switch(String target, Future<void> Function() go) async {
    if (switchingTo != null) return false;
    switchingTo = target;
    notifyListeners();
    try {
      if (!await readyToSwitch()) return false;
      await go();
      return true;
    } finally {
      switchingTo = null;
      notifyListeners();
    }
  }

  /// Starts a session, in [dir] when given (a project folder), else the
  /// workspace. False when the user kept the running turn instead, or another switch is still under way.
  Future<bool> newSession({String? dir}) => _switch(newChatKey(dir), () async {
    _applyState(await client.call<Map<String, dynamic>>('new_session', {'cwd': ?dir}));
    _resetTranscript();
  });

  /// Opens another chat. False when the user kept the running turn instead, or another switch is still under way.
  Future<bool> openSession(String path) async {
    if (path == sessionFile && switchingTo == null) return true;
    return _switch(path, () async {
      _applyState(await client.call<Map<String, dynamic>>('open_session', {'path': path}));
      await loadHistory();
    });
  }

  Future<void> renameSession(String path, String name) async {
    await client.call('rename_session', {'path': path, 'name': name});
    if (path == sessionFile) sessionName = name;
    notifyListeners();
  }

  /// Deletes chats. If the open chat is among them, a fresh chat in the same folder takes its place.
  Future<int> deleteSessions(List<String> paths) async {
    final r = await client.call<Map<String, dynamic>>('delete_sessions', {'paths': paths});
    await _afterSwitch(r);
    return r['deleted'] as int? ?? 0;
  }

  /// What deleting a project would lose (uncommitted work, unpushed commits, chats) and what blocks it.
  Future<ProjectDeleteCheck> projectDeleteCheck(String path) async =>
      ProjectDeleteCheck(await client.call<Map<String, dynamic>>('project_delete_check', {'path': path}));

  /// Deletes a workspace project folder, and its chats when [deleteChats]. Returns how many chats went.
  Future<int> deleteProject(String path, {required bool deleteChats}) async {
    final r = await client.call<Map<String, dynamic>>('delete_project', {'path': path, 'deleteChats': deleteChats});
    await _afterSwitch(r);
    await integrations.refreshProjects();
    return r['deletedChats'] as int? ?? 0;
  }

  /// Applies host state after a delete; the transcript reloads when the open chat was replaced.
  Future<void> _afterSwitch(Map<String, dynamic> state) async {
    final before = sessionId;
    _applyState(state);
    if (sessionId != before) await loadHistory();
    notifyListeners();
  }

  Future<List<SessionSummary>> listSessions() async {
    final list = await client.call<List>('sessions');
    final out = list.map((e) => SessionSummary((e as Map).cast<String, dynamic>())).toList()
      ..sort((a, b) => b.modified.compareTo(a.modified));
    return out;
  }

  Future<void> loadHistory() async {
    final messages = await client.call<List>('messages');
    _resetTranscript();
    for (final m in messages.cast<Map>()) {
      _addMessage(m.cast<String, dynamic>(), fromHistory: true);
    }
    // Follow-ups still waiting (after a reconnect, or the app came back).
    try {
      final q = await client.call<Object?>('prompt_queue');
      if (q is List) _applyQueue({'items': q});
    } catch (_) {}
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Models & providers

  Future<void> refreshProviders() async {
    final list = await client.call<List>('providers');
    providers = list.map((e) => ProviderInfo((e as Map).cast<String, dynamic>())).toList()
      ..sort((a, b) {
        if (a.configured != b.configured) return a.configured ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    final available = await client.call<List>('models');
    models = available.map((e) => ModelInfo((e as Map).cast<String, dynamic>())).toList();
    notifyListeners();
  }

  Future<void> setModel(ModelInfo m) async {
    _applyState(await client.call<Map<String, dynamic>>('set_model', {'provider': m.provider, 'model': m.id}));
    notifyListeners();
  }

  Future<void> setPlanMode(bool on) async {
    _applyState(await client.call<Map<String, dynamic>>('plan_mode', {'on': on}));
    notifyListeners();
  }

  /// Leaves plan mode and tells the agent to carry out its plan.
  Future<void> approvePlan([String? text]) async {
    _applyState(await client.call<Map<String, dynamic>>('plan_approve', {'text': ?text}));
    notifyListeners();
  }

  /// Sends with images (base64) attached; files are referenced by path in [text].
  /// Same false-on-refusal contract as [send].
  ///
  /// [attachments] ride along with the message's echo (see
  /// [queueSentAttachments]); queued here so a cancelled follow-up can drop them.
  Future<bool> sendWith(
    String text, {
    List<Map<String, String>> images = const [],
    List<SentAttachment> attachments = const [],
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && images.isEmpty) return false;
    queueSentAttachments(attachments);
    try {
      final r = await client.call<Object?>('prompt', {
        'text': trimmed.isEmpty ? 'See the attached image.' : trimmed,
        'images': images,
      });
      _noteQueued(r, attachments);
      return true;
    } on AgentError catch (e) {
      retractSentAttachments(attachments);
      _addNotice(e.message, error: true);
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Follow-ups waiting for the agent

  /// Messages sent while the agent works, waiting for the turn's boundary
  /// (never steered in). Shown as dimmed bubbles; each can be cancelled.
  List<QueuedPrompt> queuedPrompts = const [];

  /// Attachments of each queued follow-up, by queue id, so cancelling drops them too.
  final _queuedAttachments = <String, List<SentAttachment>>{};

  void _noteQueued(Object? result, [List<SentAttachment> attachments = const []]) {
    final id = result is Map ? result['queued'] as String? : null;
    if (id != null && attachments.isNotEmpty) _queuedAttachments[id] = attachments;
  }

  void _applyQueue(Map<String, dynamic> record) {
    final sid = record['sessionId'] as String?;
    if (sid != null && sessionId != null && sid != sessionId) return;
    queuedPrompts = [for (final i in (record['items'] as List? ?? const []).whereType<Map>()) QueuedPrompt(i.cast())];
    final live = {for (final q in queuedPrompts) q.id};
    _queuedAttachments.removeWhere((id, _) => !live.contains(id));
    notifyListeners();
  }

  /// Cancels one waiting follow-up; the others keep their order. Returns its
  /// text (for "Edit"), or null when it had already been sent.
  Future<String?> cancelQueued(String id) async {
    final q = queuedPrompts.where((q) => q.id == id).firstOrNull;
    if (q == null) return null;
    // Gone from the screen at once; the host confirms with a prompt_queue record.
    queuedPrompts = queuedPrompts.where((x) => x.id != id).toList();
    notifyListeners();
    try {
      await client.call('prompt_queue_remove', {'queueId': id});
      final files = _queuedAttachments.remove(id);
      if (files != null) retractSentAttachments(files);
      return q.text;
    } on AgentError catch (e) {
      // Already delivered: it is in the chat now.
      _addNotice(e.message);
      return null;
    }
  }

  /// Tries the last failed request again (on the current model, which may have been changed since).
  Future<void> retry() async {
    try {
      await client.call('retry');
    } on AgentError catch (e) {
      _addNotice(e.message, error: true);
    }
  }

  /// Whether the transcript ends in an error the user could retry.
  bool get endsInError => !busy && lastTurnError != null;

  /// The error the transcript ends in, if any (also while the run is still winding down).
  String? get lastTurnError {
    if (entries.isEmpty) return null;
    final last = entries.last;
    if (last is AssistantEntry && last.error != null && !last.aborted) return last.error;
    if (last is NoticeEntry && last.error) return last.text;
    return null;
  }

  /// A short name for the open chat: its name, else its first message.
  String get chatTitle {
    final name = sessionName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final first = entries.whereType<UserEntry>().firstOrNull?.text.trim().split('\n').first ?? '';
    return first.length > 48 ? '${first.substring(0, 47)}…' : (first.isEmpty ? 'GripHub AI Agent' : first);
  }

  /// The message an edit or fork is working on (its entry id, or `''` for a fork of the whole chat), while one runs.
  /// The chat dims that message and shows a spinner on it; another edit or fork waits for this one.
  String? rewinding;

  /// Runs one edit or fork at a time. Throws [AgentError] when one is already running.
  Future<String> _rewind(String? entryId, Future<String> Function() go) async {
    if (rewinding != null || switchingTo != null) throw AgentError('Wait for the chat to finish updating.');
    rewinding = entryId ?? '';
    notifyListeners();
    try {
      return await go();
    } finally {
      rewinding = null;
      notifyListeners();
    }
  }

  /// Rewinds to just before a user message; returns its text for editing.
  Future<String> editMessage(String entryId) => _rewind(entryId, () async {
    final r = await client.call<Map>('edit_message', {'entryId': entryId});
    await loadHistory();
    return r['text'] as String? ?? '';
  });

  /// Copies this chat into a new one, rewound to just before [entryId].
  Future<String> forkAt(String? entryId) => _rewind(entryId, () async {
    String text = '';
    final switched = await _switch('fork:${entryId ?? ''}', () async {
      final r = (await client.call<Map>('fork_session', {'entryId': ?entryId})).cast<String, dynamic>();
      _applyState(r);
      await loadHistory();
      text = r['text'] as String? ?? '';
    });
    if (!switched) throw AgentError(busySwitchError);
    return text;
  });

  Future<void> setThinking(String level) async {
    _applyState(await client.call<Map<String, dynamic>>('set_thinking', {'level': level}));
    notifyListeners();
  }

  Future<void> login(String provider, String method) async {
    await client.call('login', {'provider': provider, 'method': method});
    await refreshProviders();
    if (model == null) {
      _applyState(await client.call<Map<String, dynamic>>('state'));
      if (model == null && models.isNotEmpty) await setModel(models.first);
    }
    notifyListeners();
  }

  void answerAuth(int authId, String? value) {
    client.call('auth_reply', {'authId': authId, 'value': value, 'cancel': value == null});
  }

  Future<void> logout(String provider) async {
    await client.call('logout', {'provider': provider});
    await refreshProviders();
    _applyState(await client.call<Map<String, dynamic>>('state'));
    notifyListeners();
  }

  /// Custom endpoints (base URL + API key) the user added.
  Future<List<CustomProvider>> customProviders() async =>
      (await client.call<List>('custom_providers'))
          .map((e) => CustomProvider((e as Map).cast<String, dynamic>()))
          .toList();

  /// Adds or updates a custom endpoint; an empty apiKey keeps the saved one.
  Future<void> saveCustomProvider(Map<String, dynamic> provider) async {
    await client.call('custom_provider_save', {'provider': provider});
    await refreshProviders();
    // The host swaps in the saved definition for the open chat: pick up its thinking levels and limits.
    _applyState(await client.call<Map<String, dynamic>>('state'));
    if (model == null && models.isNotEmpty) await setModel(models.first);
    notifyListeners();
  }

  Future<void> deleteCustomProvider(String id) async {
    await client.call('custom_provider_delete', {'providerId': id});
    await refreshProviders();
    _applyState(await client.call<Map<String, dynamic>>('state'));
    notifyListeners();
  }

  /// Lists the models an endpoint serves. Without [apiKey], the key saved for [providerId] is used.
  Future<List<CustomModel>> fetchProviderModels({
    required String api,
    required String baseUrl,
    String apiKey = '',
    String? providerId,
  }) async {
    final list = await client.call<List>('custom_provider_fetch_models', {
      'api': api,
      'baseUrl': baseUrl,
      'apiKey': apiKey,
      'providerId': ?providerId,
    });
    return list.map((e) => CustomModel((e as Map).cast<String, dynamic>())).toList();
  }

  // -------------------------------------------------------------------------
  // Event handling

  void _onRecord(Map<String, dynamic> record) {
    switch (record['type']) {
      case 'event':
        _onEvent((record['event'] as Map).cast<String, dynamic>());
      case 'subagent_started' ||
          'subagent_finished' ||
          'subagent_event' ||
          'subagent_status' ||
          'subagent_queued' ||
          'subagent_approval_request' ||
          'subagent_approval_dismiss':
        // The request this record ends, read before the store forgets it.
        final subId = record['subagentId'] as String? ?? ((record['subagent'] as Map?)?['id'] as String?);
        final before = subagentStore[subId ?? '']?.approval?.approvalId;
        subagentStore.applyRecord(record);
        final after = subagentStore[subId ?? '']?.approval?.approvalId;
        final answered = record['type'] == 'subagent_approval_dismiss'
            ? record['approvalId'] as String? ?? before
            : (before != null && before != after ? before : null);
        unawaited(_syncSubagentNotifications(record, answered));
        _scheduleNotify();
      case 'auth_prompt' || 'auth_event' || 'auth_dismiss':
        authRecords.add(record);
      // GripHub's model list changed on its daily refresh: reload the picker.
      case 'models_changed':
        unawaited(refreshProviders().catchError((_) {}));
      case 'notice':
        // Startup hints ("no models") are covered by the empty state; the rest
        // (model fallback, triggers) are worth showing.
        final message = record['message'] as String? ?? '';
        if (!message.startsWith('No models available')) _addNotice(message);
      // The host changed session state on its own (e.g. a fallback model).
      case 'prompt_queue':
        _applyQueue(record);
      case 'state':
        _applyState((record['state'] as Map).cast<String, dynamic>());
        notifyListeners();
      case 'error':
        _addNotice(readableError(record['message'] as String? ?? 'Error'), error: true);
      // A server link that could not replay what it missed: reload instead.
      case 'resync':
        unawaited(resync());
      // On a server agent an exit is the link dropping, not the host: the client reconnects by itself.
      case 'exit' when client.isRemote:
        break;
      case 'exit':
        if (status == BootStatus.ready) {
          status = BootStatus.failed;
          bootError = 'The agent process stopped (code ${record['code']}).\n\n${client.stderrTail.join('\n')}';
          _setBusy(false);
          notifyListeners();
        }
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'agent_start':
        _setBusy(true);
      case 'agent_settled':
        _setBusy(false);
        runningTool = null;
        _streaming = null;
        _refreshStateQuietly();
      case 'message_start':
        _addMessage((e['message'] as Map).cast<String, dynamic>());
      case 'message_update':
        _applyDelta((e['assistantMessageEvent'] as Map).cast<String, dynamic>());
      case 'message_end':
        final message = (e['message'] as Map).cast<String, dynamic>();
        if (message['role'] == 'assistant') {
          (_streaming ?? _lastAssistant())?.applyMessage(message);
          _streaming = null;
        }
      case 'tool_execution_start':
        tools[e['toolCallId'] as String] = ToolRun(e['toolCallId'] as String);
        runningTool = e['toolName'] as String?;
      case 'tool_execution_update':
        final run = tools.putIfAbsent(e['toolCallId'] as String, () => ToolRun(e['toolCallId'] as String));
        run.output = contentText((e['partialResult'] as Map?)?['content']);
      case 'tool_execution_end':
        final run = tools.putIfAbsent(e['toolCallId'] as String, () => ToolRun(e['toolCallId'] as String));
        run.output = contentText((e['result'] as Map?)?['content']);
        run.status = e['isError'] == true ? ToolStatus.failed : ToolStatus.done;
        runningTool = null;
      case 'compaction_start':
        _addNotice('Compacting context…');
      case 'session_info_changed':
        sessionName = e['name'] as String?;
      case 'thinking_level_changed':
        thinkingLevel = e['level'] as String? ?? thinkingLevel;
      default:
        return;
    }
    _scheduleNotify();
  }

  /// Attachments queued by the composer for the next user message the
  /// host echoes. The echo may arrive before the send call returns, so the
  /// composer queues first and retracts on refusal; the queue drains in
  /// transcript order, so rapid sends still line up. Cleared with the
  /// transcript on session switch, rewind and fork.
  final _pendingAttachments = <List<SentAttachment>>[];

  /// Queues [files] to ride along with the next echoed user message.
  void queueSentAttachments(List<SentAttachment> files) {
    if (files.isNotEmpty) _pendingAttachments.add(files);
  }

  /// Drops a queued batch that never reached the transcript (refused send).
  void retractSentAttachments(List<SentAttachment> files) {
    for (var i = _pendingAttachments.length - 1; i >= 0; i--) {
      if (identical(_pendingAttachments[i], files)) {
        _pendingAttachments.removeAt(i);
        return;
      }
    }
  }

  /// Adds a saved message as history would (for widget tests and goldens).
  @visibleForTesting
  void addHistoryMessage(Map<String, dynamic> m) => _addMessage(m, fromHistory: true);

  void _addMessage(Map<String, dynamic> m, {bool fromHistory = false}) {
    switch (m['role']) {
      case 'user':
        // The ordinal among user messages is assigned here, at append time,
        // so it always matches the transcript order — including history
        // reloads and rewind-and-resend (which reuses the index).
        final ordinal = entries.whereType<UserEntry>().length;
        final attached = fromHistory
            ? SentAttachments.instance.forMessage(sessionId, ordinal)
            : (_pendingAttachments.isNotEmpty ? _pendingAttachments.removeAt(0) : const <SentAttachment>[]);
        if (!fromHistory && attached.isNotEmpty) {
          SentAttachments.instance.record(sessionId, ordinal, attached);
        }
        entries.add(
          UserEntry(contentText(m['content']), images: contentImages(m['content']), attachments: attached),
        );
      case 'assistant':
        final entry = AssistantEntry();
        if (fromHistory || (m['content'] as List?)?.isNotEmpty == true) entry.applyMessage(m);
        entry.streaming = !fromHistory;
        entries.add(entry);
        if (!fromHistory) _streaming = entry;
      case 'toolResult':
        final run = tools.putIfAbsent(m['toolCallId'] as String, () => ToolRun(m['toolCallId'] as String));
        run.output = contentText(m['content']);
        run.status = m['isError'] == true ? ToolStatus.failed : ToolStatus.done;
      case 'bashExecution':
        entries.add(NoticeEntry('\$ ${m['command']}\n${m['output']}'));
      case 'compactionSummary':
        entries.add(NoticeEntry('Earlier messages were summarized to save context.'));
    }
  }

  void _applyDelta(Map<String, dynamic> d) {
    final entry = _streaming ??= _lastAssistant();
    if (entry == null) return;
    final index = d['contentIndex'] as int? ?? 0;
    switch (d['type']) {
      case 'text_start':
        entry.block(index, BlockKind.text);
      case 'text_delta':
        entry.block(index, BlockKind.text).buffer.write(d['delta'] ?? '');
      case 'text_end':
        entry.block(index, BlockKind.text).text = d['content'] as String? ?? '';
      case 'thinking_start':
        entry.block(index, BlockKind.thinking);
      case 'thinking_delta':
        entry.block(index, BlockKind.thinking).buffer.write(d['delta'] ?? '');
      case 'thinking_end':
        entry.block(index, BlockKind.thinking).text = d['content'] as String? ?? '';
      case 'toolcall_start':
        entry.block(index, BlockKind.toolCall)
          ..toolCallId = d['id'] as String?
          ..toolName = d['toolName'] as String?;
      case 'toolcall_delta':
        final block = entry.block(index, BlockKind.toolCall);
        block.toolCallId ??= d['id'] as String?;
        block.toolName ??= d['toolName'] as String?;
        block.buffer.write(d['delta'] ?? '');
      case 'toolcall_end':
        final call = (d['toolCall'] as Map?)?.cast<String, dynamic>();
        if (call != null) {
          entry.block(index, BlockKind.toolCall)
            ..toolCallId = call['id'] as String?
            ..toolName = call['name'] as String?
            ..args = (call['arguments'] as Map?)?.cast<String, dynamic>();
        }
    }
  }

  AssistantEntry? _lastAssistant() {
    for (final e in entries.reversed) {
      if (e is AssistantEntry) return e.streaming ? e : null;
    }
    return null;
  }

  void _addNotice(String text, {bool error = false}) {
    entries.add(NoticeEntry(text, error: error));
    notifyListeners();
  }

  void _resetTranscript() {
    entries.clear();
    tools.clear();
    _streaming = null;
    _pendingAttachments.clear();
    queuedPrompts = const [];
    _queuedAttachments.clear();
  }

  void _setBusy(bool value) {
    if (busy == value) return;
    busy = value;
    // The foreground service keeps this phone's agent alive; a server agent needs nothing from the phone.
    if (!client.isRemote) client.setBusy(value);
    features.setChatBusy(value);
  }

  void _applyState(Map<String, dynamic> s) {
    final m = s['model'];
    model = m == null ? null : ModelInfo((m as Map).cast<String, dynamic>());
    thinkingLevel = s['thinkingLevel'] as String? ?? 'off';
    thinkingLevels = (s['thinkingLevels'] as List? ?? const ['off']).cast<String>();
    sessionId = s['sessionId'] as String?;
    sessionName = s['sessionName'] as String?;
    sessionFile = s['sessionFile'] as String?;
    cwd = s['cwd'] as String? ?? cwd;
    billingNotice = s['billingNotice'] as String?;
    planMode = s['planMode'] == true;
    approvalMode = s['approvalMode'] as String? ?? approvalMode;
    if (s['isStreaming'] is bool) _setBusy(s['isStreaming'] as bool);
    // Another chat may now be on screen: its subagents stop (or start) needing the running notification.
    if (subagentStore.all.isNotEmpty) unawaited(_syncRunningNotification());
  }

  /// Re-reads session state after something outside the chat changed it (the shell).
  Future<void> refreshState() async {
    _applyState(await client.call<Map<String, dynamic>>('state'));
    notifyListeners();
  }

  Future<void> _refreshStateQuietly() async {
    try {
      _applyState(await client.call<Map<String, dynamic>>('state'));
      notifyListeners();
    } catch (_) {}
  }

  /// Coalesces streaming updates to roughly one rebuild per frame.
  void _scheduleNotify() {
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 32), notifyListeners);
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    authRecords.close();
    switchProblems.close();
    super.dispose();
  }
}
