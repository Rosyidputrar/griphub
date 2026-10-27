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

SubagentStatus _status(String? s) => switch (s) {
  'queued' => SubagentStatus.queued,
  'running' => SubagentStatus.running,
  'waitingApproval' => SubagentStatus.waitingApproval,
  'stopping' => SubagentStatus.stopping,
  'done' => SubagentStatus.done,
  'failed' => SubagentStatus.failed,
  'stopped' => SubagentStatus.stopped,
  _ => SubagentStatus.queued,
};

enum SubagentToolStatus { running, done, failed }

class SubagentToolRun {
  SubagentToolRun({required this.id, required this.name, required this.args, required this.startedAt});
  final String id;
  final String name;
  final String args;
  final DateTime startedAt;
  String output = '';
  SubagentToolStatus status = SubagentToolStatus.running;
  DateTime? finishedAt;
}

class QueuedSubagentMessage {
  QueuedSubagentMessage({required this.id, required this.text, required this.at});
  final String id;
  final String text;
  final DateTime at;
}

/// A risky step the subagent paused on; answered from the detail modal.
class SubagentApproval {
  SubagentApproval({required this.approvalId, required this.toolName, required this.summary, required this.reason, required this.key});
  final String approvalId;
  final String toolName;
  final String summary;
  final String reason;
  final String key;
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
  });

  final String id;
  final String parentSessionFile;
  final String parentTitle;
  final String brief;
  final String profile;
  SubagentStatus status;
  final DateTime createdAt;
  DateTime? startedAt;
  DateTime? finishedAt;
  String? currentTool;
  String? currentActivity;
  final List<SubagentToolRun> tools = [];
  final List<QueuedSubagentMessage> queue = [];
  int inputTokens = 0;
  int outputTokens = 0;
  double? credits;
  String? report;
  String? error;
  String? stopReason;
  SubagentApproval? approval;

  bool get isActive =>
      status == SubagentStatus.queued ||
      status == SubagentStatus.running ||
      status == SubagentStatus.waitingApproval ||
      status == SubagentStatus.stopping;
  bool get isTerminal =>
      status == SubagentStatus.done || status == SubagentStatus.failed || status == SubagentStatus.stopped;

  Duration? get elapsed {
    final start = startedAt;
    if (start == null) return null;
    return (finishedAt ?? DateTime.now()).difference(start);
  }

  String get profileKey => profile == 'full' ? 'Full' : 'Read-only';

  String get statusKey => switch (status) {
    SubagentStatus.queued => 'Waiting for a slot',
    SubagentStatus.running => 'Running',
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
    );
    s._applyFull(r);
    return s;
  }

  /// Applies a full host record (started/finished): every field, including
  /// the tool list, which replaces the event-built one.
  void _applyFull(Map<String, dynamic> r) {
    status = _status(r['status'] as String?);
    startedAt = _date(r['startedAt']) ?? startedAt;
    finishedAt = _date(r['finishedAt']) ?? finishedAt;
    currentTool = r['currentTool'] as String?;
    currentActivity = r['currentActivity'] as String?;
    inputTokens = (r['inputTokens'] as num?)?.toInt() ?? inputTokens;
    outputTokens = (r['outputTokens'] as num?)?.toInt() ?? outputTokens;
    credits = (r['credits'] as num?)?.toDouble();
    report = r['report'] as String? ?? report;
    error = r['error'] as String? ?? error;
    stopReason = r['stopReason'] as String? ?? stopReason;
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
          );
          t.output = m['output'] as String? ?? '';
          t.status = m['status'] == 'failed'
              ? SubagentToolStatus.failed
              : m['status'] == 'done'
              ? SubagentToolStatus.done
              : SubagentToolStatus.running;
          t.finishedAt = _date(m['finishedAt']);
          return t;
        }));
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
      case 'agent_start':
        currentTool = null;
        if (status == SubagentStatus.queued) status = SubagentStatus.running;
      case 'tool_execution_start':
        final id = e['toolCallId'] as String? ?? '';
        currentTool = e['toolName'] as String?;
        if (tools.every((t) => t.id != id)) {
          tools.add(
            SubagentToolRun(
              id: id,
              name: e['toolName'] as String? ?? '',
              args: _argsSummary(e['toolName'] as String?, e['args']),
              startedAt: DateTime.now(),
            ),
          );
        }
      case 'tool_execution_update':
        final id = e['toolCallId'] as String? ?? '';
        final t = tools.where((t) => t.id == id).firstOrNull;
        if (t != null) t.output = _contentText((e['partialResult'] as Map?)?['content']);
      case 'tool_execution_end':
        final id = e['toolCallId'] as String? ?? '';
        final t = tools.where((t) => t.id == id).firstOrNull;
        if (t != null) {
          t.output = _contentText((e['result'] as Map?)?['content']);
          t.status = e['isError'] == true ? SubagentToolStatus.failed : SubagentToolStatus.done;
          t.finishedAt = DateTime.now();
        }
        currentTool = null;
      case 'agent_settled':
      case 'agent_end':
        // Not a finish: a queued message starts a new turn on the same
        // subagent. Terminal state arrives only via subagent_finished.
        currentTool = null;
        currentActivity = null;
    }
  }

  void applyStatus(Map<String, dynamic> r) {
    status = _status(r['status'] as String?);
    currentTool = r['currentTool'] as String?;
    currentActivity = r['currentActivity'] as String?;
    inputTokens = (r['inputTokens'] as num?)?.toInt() ?? inputTokens;
    outputTokens = (r['outputTokens'] as num?)?.toInt() ?? outputTokens;
    credits = (r['credits'] as num?)?.toDouble() ?? credits;
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
    'bash' => v('command'),
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
        _states[r['id'] as String? ?? ''] = SubagentState.fromRecord(r);
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
        if (s != null) {
          s.approval = SubagentApproval(
            approvalId: record['approvalId'] as String? ?? '',
            toolName: record['toolName'] as String? ?? '',
            summary: record['summary'] as String? ?? '',
            reason: record['reason'] as String? ?? '',
            key: record['key'] as String? ?? '',
          );
          s.status = SubagentStatus.waitingApproval;
        }
      case 'subagent_approval_dismiss':
        final id = record['subagentId'] as String? ?? '';
        final s = _states[id];
        if (s != null) {
          s.approval = null;
          if (s.status == SubagentStatus.waitingApproval) s.status = SubagentStatus.running;
        }
    }
  }
}
