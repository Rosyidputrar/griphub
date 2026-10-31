import 'models.dart' show ToolImage, contentImageData;

/// Subagent state mirrored from the host's `subagent_*` records.
///
/// This store is deliberately pure: it only reduces record maps, so it is
/// unit-testable without a platform channel or a running host. The
/// [AgentController] feeds it every host record and notifies listeners.
///
/// A subagent is never a chat: the host runs it on an in-memory session, so
/// the only thing Dart ever sees is these records. Cards are rendered for
/// the open chat ([forParent]); running subagents of other chats surface
/// through the cross-chat banner ([runningElsewhere]). Terminal state comes
/// only from `subagent_finished` — a settled turn is not a finish, because a
/// queued message starts a new turn on the same subagent.
enum SubagentStatus { queued, running, waitingApproval, stopping, done, failed, stopped }

/// The host's status names (agent/src/subagent.ts `SubagentStatus`). The
/// host writes `waiting_approval`; the camelCase spelling is accepted too.
/// An unknown name keeps [fallback] instead of pretending the subagent is
/// waiting for a slot.
SubagentStatus _status(String? s, [SubagentStatus fallback = SubagentStatus.queued]) => switch (s) {
  'queued' => SubagentStatus.queued,
  'running' => SubagentStatus.running,
  'waiting_approval' || 'waitingApproval' => SubagentStatus.waitingApproval,
  'stopping' => SubagentStatus.stopping,
  'done' => SubagentStatus.done,
  'failed' => SubagentStatus.failed,
  'stopped' => SubagentStatus.stopped,
  _ => fallback,
};

/// Why a stopped subagent stopped (host `stopCode`).
enum SubagentStopCode { user, force, time, credit, beforeStart, limit }

SubagentStopCode? _stopCode(String? s) => switch (s) {
  'user' => SubagentStopCode.user,
  'force' => SubagentStopCode.force,
  'time' => SubagentStopCode.time,
  'credit' => SubagentStopCode.credit,
  'before_start' => SubagentStopCode.beforeStart,
  'limit' => SubagentStopCode.limit,
  _ => null,
};

enum SubagentToolStatus { running, done, failed }

class SubagentToolRun {
  SubagentToolRun({required this.id, required this.name, required this.args, required this.startedAt, this.input});
  final String id;
  final String name;

  /// One line: the path, the command (cut short), the query.
  final String args;
  final DateTime startedAt;

  /// The arguments themselves (the whole command, a file's content, an edit's old and new text), when known.
  Map<String, dynamic>? input;
  String output = '';

  /// Pictures in the result (a `read` of an image).
  List<ToolImage> images = const [];
  SubagentToolStatus status = SubagentToolStatus.running;
  DateTime? finishedAt;
}

/// One step of a subagent's work, in order, as the chat shows its own (host `SubagentTimelineEntry`).
enum SubagentEntryKind { thinking, text, user, tool }

class SubagentEntry {
  const SubagentEntry(this.kind, {this.text = '', this.toolId, required this.at});
  final SubagentEntryKind kind;
  final String text;

  /// For [SubagentEntryKind.tool]: which tool call came here.
  final String? toolId;
  final DateTime at;
}

SubagentEntryKind? _entryKind(String? k) => switch (k) {
  'thinking' => SubagentEntryKind.thinking,
  'text' => SubagentEntryKind.text,
  'user' => SubagentEntryKind.user,
  'tool' => SubagentEntryKind.tool,
  _ => null,
};

class QueuedSubagentMessage {
  QueuedSubagentMessage({required this.id, required this.text, required this.at});
  final String id;
  final String text;
  final DateTime at;
}

/// A risky step the subagent paused on; answered from the detail modal.
class SubagentApproval {
  SubagentApproval({
    required this.approvalId,
    required this.toolName,
    required this.summary,
    required this.reason,
    required this.key,
    this.patch,
  });
  final String approvalId;
  final String toolName;
  final String summary;
  final String reason;
  final String key;

  /// For an edit or a write: the change as a unified patch, when the host could work it out.
  final String? patch;
}

class SubagentState {
  SubagentState({
    required this.id,
    required this.parentSessionFile,
    required this.parentTitle,
    required this.brief,
    required this.profile,
    required this.status,
    required this.createdAt,
    this.toolCallId,
  });

  final String id;

  /// The parent's `subagent` tool call; the card is drawn at that call in the transcript.
  final String? toolCallId;
  final String parentSessionFile;
  final String parentTitle;
  final String brief;
  final String profile;
  SubagentStatus status;
  final DateTime createdAt;
  DateTime? startedAt;
  DateTime? finishedAt;
  String? currentTool;

  /// One-line argument summary of [currentTool] (path, query, command).
  String? currentArgs;

  /// The host's English activity line; only a fallback, the UI builds a localized one.
  String? currentActivity;
  final List<SubagentToolRun> tools = [];

  /// What it thought, wrote, called and was sent, in order: from the host's record, and live from its events.
  final List<SubagentEntry> timeline = [];

  /// The thinking and text of the message being written now, before it ends.
  String liveThinking = '';
  String liveText = '';

  /// The arguments of tool calls still being written (raw JSON so far), by call id: a file shows as it is written.
  final Map<String, String> liveArgs = {};

  /// The tool each of [liveArgs] is for.
  final Map<String, String> liveNames = {};

  /// A tool call by id.
  SubagentToolRun? tool(String id) => tools.where((t) => t.id == id).firstOrNull;
  final List<QueuedSubagentMessage> queue = [];
  int inputTokens = 0;
  int outputTokens = 0;
  int cacheReadTokens = 0;
  int cacheWriteTokens = 0;

  /// Estimated GripHub credits, summed per model request by the router's rule
  /// (rate × all tokens incl. cache, or the model's floor when higher).
  double? credits;

  /// Model requests so far, and how many were billed at the model's minimum.
  int requests = 0;
  int flooredRequests = 0;

  /// The model doing the work, its name, and the thinking (reasoning) level.
  String? model;
  String? modelName;
  String? thinkingLevel;

  /// The model's rate (credits per 1M tokens).
  double? rate;

  /// All tokens billed: input, output and cache.
  int get totalTokens => inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens;
  String? report;
  String? error;
  String? stopReason;
  SubagentStopCode? stopCode;
  SubagentApproval? approval;

  bool get isActive =>
      status == SubagentStatus.queued ||
      status == SubagentStatus.running ||
      status == SubagentStatus.waitingApproval ||
      status == SubagentStatus.stopping;
  bool get isTerminal =>
      status == SubagentStatus.done || status == SubagentStatus.failed || status == SubagentStatus.stopped;

  /// "Now" for live durations; tests pin it so renders are reproducible.
  static DateTime Function() clock = DateTime.now;

  Duration? get elapsed {
    final start = startedAt;
    if (start == null) return null;
    final d = (finishedAt ?? clock()).difference(start);
    return d.isNegative ? Duration.zero : d;
  }

  String get profileKey => profile == 'full' ? 'Full access' : 'Read-only';

  /// English key of the status label (translated by the UI).
  String get statusKey => statusKeyOf(status);

  static String statusKeyOf(SubagentStatus status) => switch (status) {
    SubagentStatus.queued => 'Waiting for a slot',
    SubagentStatus.running => 'In progress',
    SubagentStatus.waitingApproval => 'Needs approval',
    SubagentStatus.stopping => 'Stopping…',
    SubagentStatus.done => 'Finished',
    SubagentStatus.failed => 'Failed',
    SubagentStatus.stopped => 'Stopped',
  };

  factory SubagentState.fromRecord(Map<String, dynamic> r) {
    final s = SubagentState(
      id: r['id'] as String? ?? '',
      parentSessionFile: r['parentSessionFile'] as String? ?? '',
      parentTitle: r['parentTitle'] as String? ?? '',
      brief: r['brief'] as String? ?? '',
      profile: r['profile'] as String? ?? 'read',
      status: _status(r['status'] as String?),
      createdAt: _date(r['createdAt']) ?? DateTime.now(),
      toolCallId: r['toolCallId'] as String?,
    );
    s._applyFull(r);
    return s;
  }

  /// Applies a full host record (started/finished): every field, including
  /// the tool list, which replaces the event-built one.
  void _applyFull(Map<String, dynamic> r) {
    status = _status(r['status'] as String?, status);
    startedAt = _date(r['startedAt']) ?? startedAt;
    finishedAt = _date(r['finishedAt']) ?? finishedAt;
    currentTool = r['currentTool'] as String?;
    currentArgs = r['currentArgs'] as String?;
    currentActivity = r['currentActivity'] as String?;
    _applyCost(r, replace: true);
    report = r['report'] as String? ?? report;
    error = r['error'] as String? ?? error;
    stopReason = r['stopReason'] as String? ?? stopReason;
    stopCode = _stopCode(r['stopCode'] as String?) ?? stopCode;
    // A finished subagent asks nothing any more (the host cancels pending approvals).
    if (isTerminal) approval = null;
    final calls = r['toolCalls'] as List?;
    if (calls != null) {
      tools
        ..clear()
        ..addAll(calls.whereType<Map>().map((c) {
          final m = c.cast<String, dynamic>();
          final t = SubagentToolRun(
            id: m['id'] as String? ?? '',
            name: m['name'] as String? ?? '',
            args: m['args'] as String? ?? '',
            startedAt: _date(m['startedAt']) ?? DateTime.now(),
            input: (m['input'] as Map?)?.cast<String, dynamic>(),
          );
          t.output = m['output'] as String? ?? '';
          t.images = contentImageData([
            for (final i in (m['images'] as List? ?? const []).whereType<Map>()) {'type': 'image', ...i},
          ]);
          t.status = m['status'] == 'failed'
              ? SubagentToolStatus.failed
              : m['status'] == 'done'
              ? SubagentToolStatus.done
              : SubagentToolStatus.running;
          t.finishedAt = _date(m['finishedAt']);
          return t;
        }));
    }
    // The host's timeline replaces the one built from events (an older host sends none: keep ours).
    final tl = r['timeline'] as List?;
    if (tl != null) {
      timeline
        ..clear()
        ..addAll(
          tl.whereType<Map>().map((e) {
            final kind = _entryKind(e['kind'] as String?);
            if (kind == null) return null;
            return SubagentEntry(
              kind,
              text: e['text'] as String? ?? '',
              toolId: e['id'] as String?,
              at: _date(e['at']) ?? DateTime.now(),
            );
          }).nonNulls,
        );
      if (isTerminal) {
        liveThinking = '';
        liveText = '';
        liveArgs.clear();
        liveNames.clear();
      }
    }
    final q = r['queue'] as List?;
    if (q != null) {
      queue
        ..clear()
        ..addAll(q.whereType<Map>().map((e) {
          final m = e.cast<String, dynamic>();
          return QueuedSubagentMessage(
            id: m['id'] as String? ?? '',
            text: m['text'] as String? ?? '',
            at: _date(m['at']) ?? DateTime.now(),
          );
        }));
    }
  }

  /// Applies one pi session event forwarded for this subagent.
  void applyEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      // The message being written: thinking and text as they stream, and the arguments of a tool call (a file).
      case 'message_update':
        final d = (e['assistantMessageEvent'] as Map?)?.cast<String, dynamic>() ?? const {};
        final delta = d['delta'] as String? ?? '';
        switch (d['type']) {
          case 'thinking_delta':
            liveThinking += delta;
          case 'text_delta':
            liveText += delta;
          case 'toolcall_delta' when d['id'] != null:
            final id = '${d['id']}';
            liveArgs[id] = (liveArgs[id] ?? '') + delta;
            if (d['toolName'] is String) liveNames[id] = d['toolName'] as String;
        }
      // The message ended: its thinking, text and tool-call places join the timeline, in its order (as the host does).
      case 'message_end':
        final m = (e['message'] as Map?)?.cast<String, dynamic>();
        if (m?['role'] == 'assistant') {
          final at = DateTime.now();
          for (final c in (m!['content'] as List? ?? const []).whereType<Map>()) {
            switch (c['type']) {
              case 'thinking' when (c['thinking'] as String? ?? '').trim().isNotEmpty:
                timeline.add(SubagentEntry(SubagentEntryKind.thinking, text: c['thinking'] as String, at: at));
              case 'text' when (c['text'] as String? ?? '').trim().isNotEmpty:
                timeline.add(SubagentEntry(SubagentEntryKind.text, text: c['text'] as String, at: at));
              case 'toolCall' when c['id'] != null:
                final id = '${c['id']}';
                if (!_placed(id)) timeline.add(SubagentEntry(SubagentEntryKind.tool, toolId: id, at: at));
                liveArgs.remove(id);
                liveNames.remove(id);
                final args = c['arguments'];
                final input = args is Map ? args.cast<String, dynamic>() : null;
                // The call usually starts after its message ends; keep what it was given for then.
                if (tool(id) case final t?) {
                  t.input ??= input;
                } else if (input != null) {
                  _pendingInput[id] = input;
                }
            }
          }
          liveThinking = '';
          liveText = '';
        }
      case 'subagent_user_message':
        timeline.add(
          SubagentEntry(SubagentEntryKind.user, text: e['text'] as String? ?? '', at: _date(e['at']) ?? DateTime.now()),
        );
      case 'agent_start':
        currentTool = null;
        if (status == SubagentStatus.queued) status = SubagentStatus.running;
      case 'tool_execution_start':
        final id = e['toolCallId'] as String? ?? '';
        currentTool = e['toolName'] as String?;
        currentArgs = _argsSummary(e['toolName'] as String?, e['args']);
        if (tools.every((t) => t.id != id)) {
          final args = e['args'];
          tools.add(
            SubagentToolRun(
              id: id,
              name: e['toolName'] as String? ?? '',
              args: _argsSummary(e['toolName'] as String?, e['args']),
              startedAt: DateTime.now(),
              input: args is Map ? args.cast<String, dynamic>() : _pendingInput[id],
            ),
          );
        }
        _pendingInput.remove(id);
        liveArgs.remove(id);
        liveNames.remove(id);
        if (!_placed(id)) timeline.add(SubagentEntry(SubagentEntryKind.tool, toolId: id, at: DateTime.now()));
      case 'tool_execution_update':
        final id = e['toolCallId'] as String? ?? '';
        final t = tools.where((t) => t.id == id).firstOrNull;
        if (t != null) t.output = _contentText((e['partialResult'] as Map?)?['content']);
      case 'tool_execution_end':
        final id = e['toolCallId'] as String? ?? '';
        final t = tools.where((t) => t.id == id).firstOrNull;
        if (t != null) {
          t.output = _contentText((e['result'] as Map?)?['content']);
          final images = contentImageData((e['result'] as Map?)?['content']);
          if (images.isNotEmpty) t.images = images.take(2).toList();
          t.status = e['isError'] == true ? SubagentToolStatus.failed : SubagentToolStatus.done;
          t.finishedAt = DateTime.now();
        }
        currentTool = null;
        currentArgs = null;
      case 'agent_settled':
      case 'agent_end':
        // Not a finish: a queued message starts a new turn on the same
        // subagent. Terminal state arrives only via subagent_finished.
        currentTool = null;
        currentArgs = null;
        currentActivity = null;
    }
  }

  /// Whether the timeline already has a place for tool call [id].
  bool _placed(String id) => timeline.any((t) => t.kind == SubagentEntryKind.tool && t.toolId == id);

  /// Arguments a message gave a tool call before the call started.
  final Map<String, Map<String, dynamic>?> _pendingInput = {};

  void applyStatus(Map<String, dynamic> r) {
    // Terminal state only ever comes from subagent_finished.
    if (isTerminal) return;
    status = _status(r['status'] as String?, status);
    if (status != SubagentStatus.waitingApproval && status != SubagentStatus.running) approval = null;
    currentTool = r['currentTool'] as String?;
    currentArgs = r['currentArgs'] as String?;
    currentActivity = r['currentActivity'] as String?;
    _applyCost(r, replace: false);
  }

  /// Tokens, cost, model and thinking level from a full record ([replace]:
  /// a missing cost means unknown) or a status update (missing keeps the last).
  void _applyCost(Map<String, dynamic> r, {required bool replace}) {
    int i(String k, int old) => (r[k] as num?)?.toInt() ?? old;
    inputTokens = i('inputTokens', inputTokens);
    outputTokens = i('outputTokens', outputTokens);
    cacheReadTokens = i('cacheReadTokens', cacheReadTokens);
    cacheWriteTokens = i('cacheWriteTokens', cacheWriteTokens);
    requests = i('requests', requests);
    flooredRequests = i('flooredRequests', flooredRequests);
    final c = (r['credits'] as num?)?.toDouble();
    credits = replace ? c : (c ?? credits);
    model = r['model'] as String? ?? model;
    modelName = r['modelName'] as String? ?? modelName;
    thinkingLevel = r['thinkingLevel'] as String? ?? thinkingLevel;
    rate = (r['rate'] as num?)?.toDouble() ?? rate;
  }
}

DateTime? _date(dynamic v) {
  if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
  if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt());
  return null;
}

String _contentText(dynamic content) {
  if (content is String) return content;
  if (content is! List) return '';
  return content
      .whereType<Map>()
      .map((c) => c['type'] == 'text' ? (c['text'] as String? ?? '') : '')
      .join();
}

String _argsSummary(String? toolName, dynamic args) {
  final a = (args as Map?)?.cast<String, dynamic>() ?? const {};
  String v(String k) => a[k] is String ? a[k] as String : '';
  return switch (toolName) {
    'read' || 'ls' || 'edit' || 'write' => v('path'),
    'grep' || 'find' => v('pattern'),
    'web_search' => v('query'),
    'web_fetch' => v('url'),
    'bash' => v('command').length > 200 ? v('command').substring(0, 200) : v('command'),
    _ => '',
  };
}

class SubagentStore {
  final _states = <String, SubagentState>{};

  List<SubagentState> get all => _states.values.toList();

  SubagentState? operator [](String id) => _states[id];

  /// Subagents of one chat, oldest first. Matches the host's parent id,
  /// which is the session file when one exists, else the session id.
  List<SubagentState> forParent({String? file, String? id}) {
    if ((file == null || file.isEmpty) && (id == null || id.isEmpty)) return const [];
    return _states.values
        .where((s) => (file != null && file.isNotEmpty && s.parentSessionFile == file) || (id != null && id.isNotEmpty && s.parentSessionFile == id))
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  /// Active subagents living in chats other than the open one.
  List<SubagentState> runningElsewhere({String? file, String? id}) {
    final mine = forParent(file: file, id: id).map((s) => s.id).toSet();
    return _states.values.where((s) => s.isActive && !mine.contains(s.id)).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  void applyRecord(Map<String, dynamic> record) {
    switch (record['type']) {
      case 'subagent_started':
        final r = (record['subagent'] as Map).cast<String, dynamic>();
        final id = r['id'] as String? ?? '';
        // A re-sent start (subagent_list after a reconnect) refreshes, never resets, a known one.
        final known = _states[id];
        if (known != null) {
          known._applyFull(r);
        } else {
          _states[id] = SubagentState.fromRecord(r);
        }
      case 'subagent_finished':
        final r = (record['subagent'] as Map).cast<String, dynamic>();
        final id = r['id'] as String? ?? '';
        final s = _states[id] ??= SubagentState.fromRecord(r);
        s._applyFull(r);
      case 'subagent_event':
        final id = record['subagentId'] as String? ?? '';
        _states[id]?.applyEvent((record['event'] as Map).cast<String, dynamic>());
      case 'subagent_status':
        final id = record['subagentId'] as String? ?? '';
        _states[id]?.applyStatus(record);
      case 'subagent_queued':
        final id = record['subagentId'] as String? ?? '';
        final s = _states[id];
        if (s != null) {
          s.queue
            ..clear()
            ..addAll(
              ((record['queue'] as List?) ?? const []).whereType<Map>().map((e) {
                final m = e.cast<String, dynamic>();
                return QueuedSubagentMessage(
                  id: m['id'] as String? ?? '',
                  text: m['text'] as String? ?? '',
                  at: _date(m['at']) ?? DateTime.now(),
                );
              }),
            );
        }
      case 'subagent_approval_request':
        final id = record['subagentId'] as String? ?? '';
        final s = _states[id];
        if (s != null && s.isActive) {
          s.approval = SubagentApproval(
            approvalId: record['approvalId'] as String? ?? '',
            toolName: record['toolName'] as String? ?? '',
            summary: record['summary'] as String? ?? '',
            reason: record['reason'] as String? ?? '',
            key: record['key'] as String? ?? '',
            patch: record['patch'] is String && (record['patch'] as String).trim().isNotEmpty ? record['patch'] as String : null,
          );
          // A stop in progress keeps saying so; the approval is about to be cancelled.
          if (s.status != SubagentStatus.stopping) s.status = SubagentStatus.waitingApproval;
        }
      case 'subagent_approval_dismiss':
        final id = record['subagentId'] as String? ?? '';
        final s = _states[id];
        final approvalId = record['approvalId'] as String?;
        // Only the request it names: a late dismiss must not clear a newer request.
        if (s != null && (approvalId == null || s.approval?.approvalId == approvalId)) {
          s.approval = null;
          if (s.status == SubagentStatus.waitingApproval) s.status = SubagentStatus.running;
        }
    }
  }
}
