import 'dart:async';

import 'package:flutter/foundation.dart';

import 'agent_client.dart';

// ---------------------------------------------------------------------------
// Models for the host's workbench commands (see agent/src/host.ts).

Map<String, dynamic> _m(Object? o) => (o as Map).cast<String, dynamic>();
List<Map<String, dynamic>> _l(Object? o) => (o as List? ?? const []).map(_m).toList();

/// The agent wants to do something that needs the user's OK (guard.ts).
class Approval {
  Approval(this.json);
  final Map<String, dynamic> json;
  String get id => json['approvalId'] as String;
  String get toolName => json['toolName'] as String;
  String get summary => json['summary'] as String? ?? '';
  String get reason => json['reason'] as String? ?? '';
  String get key => json['key'] as String? ?? '';

  /// For an edit or a write: the change as a unified patch, when the host could work it out.
  String? get patch {
    final p = json['patch'];
    return p is String && p.trim().isNotEmpty ? p : null;
  }
}

class CheckpointInfo {
  CheckpointInfo(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get label => json['label'] as String;
  DateTime get time => DateTime.fromMillisecondsSinceEpoch(json['time'] as int);
  int get files => json['files'] as int? ?? 0;
}

class DiffFile {
  DiffFile(this.json);
  final Map<String, dynamic> json;
  String get path => json['path'] as String;
  int get additions => json['additions'] as int? ?? 0;
  int get deletions => json['deletions'] as int? ?? 0;
  bool get binary => json['binary'] == true;
}

class ChangeSet {
  ChangeSet(this.json);
  final Map<String, dynamic> json;
  String? get base => json['base'] as String?;
  List<DiffFile> get files => _l(json['files']).map(DiffFile.new).toList();
  String get patch => json['patch'] as String? ?? '';
}

class GitFile {
  GitFile(this.json);
  final Map<String, dynamic> json;
  String get path => json['path'] as String;

  /// For a rename or copy: the old path.
  String? get from => json['from'] as String?;

  /// Paths git must be given to act on this entry (a rename has two sides).
  List<String> get paths => [path, ?from];
  String get code => json['code'] as String;
  bool get staged => json['staged'] == true;
  bool get unstaged => json['unstaged'] == true;
  bool get untracked => json['untracked'] == true;
}

class GitStatus {
  GitStatus(this.json);
  final Map<String, dynamic> json;
  bool get isRepo => json['repo'] == true;
  String get branch => json['branch'] as String? ?? '';
  String? get upstream => json['upstream'] as String?;
  int get ahead => json['ahead'] as int? ?? 0;
  int get behind => json['behind'] as int? ?? 0;
  String? get remote => json['remote'] as String?;

  /// The repository's top folder: the [files]' paths start there (null from a host before this was sent).
  String? get root => json['root'] as String?;
  List<GitFile> get files => _l(json['files']).map(GitFile.new).toList();
}

/// The review before a commit: the status, and per file how many lines it adds and removes against the last commit.
class GitReview {
  GitReview(this.json) : status = GitStatus(json);
  final Map<String, dynamic> json;
  final GitStatus status;

  ({int additions, int deletions, bool binary}) statOf(String path) {
    final s = (json['stats'] as Map?)?[path];
    if (s is! Map) return (additions: 0, deletions: 0, binary: false);
    return (
      additions: (s['additions'] as num?)?.toInt() ?? 0,
      deletions: (s['deletions'] as num?)?.toInt() ?? 0,
      binary: s['binary'] == true,
    );
  }

  int get additions => status.files.fold(0, (n, f) => n + statOf(f.path).additions);
  int get deletions => status.files.fold(0, (n, f) => n + statOf(f.path).deletions);
}

class GitBranch {
  GitBranch(this.json);
  final Map<String, dynamic> json;
  String get name => json['name'] as String;
  bool get current => json['current'] == true;
  bool get remote => json['remote'] == true;
}

class GitCommit {
  GitCommit(this.json);
  final Map<String, dynamic> json;
  String get hash => json['hash'] as String;
  String get author => json['author'] as String? ?? '';
  DateTime get time => DateTime.fromMillisecondsSinceEpoch(json['time'] as int);
  String get subject => json['subject'] as String? ?? '';
}

class GithubIssue {
  GithubIssue(this.json);
  final Map<String, dynamic> json;
  int get number => json['number'] as int;
  String get title => json['title'] as String;
  String get body => json['body'] as String? ?? '';
  String get url => json['url'] as String;
  String? get author => json['author'] as String?;
  List<String> get labels => (json['labels'] as List? ?? const []).cast<String>();
  int get comments => json['comments'] as int? ?? 0;
  bool get isPr => json['isPr'] == true;
  DateTime get updatedAt => DateTime.fromMillisecondsSinceEpoch(json['updatedAt'] as int);
}

class SearchMatch {
  SearchMatch(this.json);
  final Map<String, dynamic> json;
  String get path => json['path'] as String;
  int get line => json['line'] as int;
  String get text => json['text'] as String;
}

class DbTable {
  DbTable(this.json);
  final Map<String, dynamic> json;
  String get name => json['name'] as String;
  String get type => json['type'] as String;
  int? get rows => json['rows'] as int?;
}

class DbResult {
  DbResult(this.json);
  final Map<String, dynamic> json;
  List<String> get columns => (json['columns'] as List? ?? const []).cast<String>();
  List<List<Object?>> get rows => (json['rows'] as List? ?? const []).map((r) => (r as List).cast<Object?>()).toList();
  int? get changes => json['changes'] as int?;
}

class UsageRow {
  UsageRow(this.json);
  final Map<String, dynamic> json;
  String get day => json['day'] as String;
  String get provider => json['provider'] as String? ?? '';
  String get model => json['model'] as String? ?? '';
  int get input => json['input'] as int? ?? 0;
  int get output => json['output'] as int? ?? 0;
  int get cacheRead => json['cacheRead'] as int? ?? 0;
  int get cacheWrite => json['cacheWrite'] as int? ?? 0;

  /// All tokens the request was billed for (cache included, as the router counts them).
  int get tokens => input + output + cacheRead + cacheWrite;
  double get cost => (json['cost'] as num? ?? 0).toDouble();

  /// Estimated GripHub credits by the router's rule (null: price unknown).
  double? get credits => (json['credits'] as num?)?.toDouble();
  int get requests => json['requests'] as int? ?? 0;
}

class PromptTemplate {
  PromptTemplate(this.json);
  final Map<String, dynamic> json;
  String get name => json['name'] as String;
  String get description => json['description'] as String? ?? '';
  String? get argumentHint => json['argumentHint'] as String? ?? json['hint'] as String?;
  String get body => json['body'] as String? ?? '';
}

class RunInfo {
  RunInfo(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get title => json['title'] as String;
  String get prompt => json['prompt'] as String;
  String get cwd => json['cwd'] as String? ?? '';
  String get status => json['status'] as String;
  String get source => json['source'] as String? ?? 'queue';
  DateTime get createdAt => DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int);
  DateTime? get finishedAt =>
      json['finishedAt'] == null ? null : DateTime.fromMillisecondsSinceEpoch(json['finishedAt'] as int);
  String? get sessionFile => json['sessionFile'] as String?;
  String? get summary => json['summary'] as String?;
  bool get active => status == 'queued' || status == 'running';
}

class ScheduleInfo {
  ScheduleInfo(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String get prompt => json['prompt'] as String;
  String get cwd => json['cwd'] as String? ?? '';
  bool get enabled => json['enabled'] == true;
  int? get everyMinutes => json['everyMinutes'] as int?;
  String? get dailyAt => json['dailyAt'] as String?;
  Map<String, dynamic>? get trigger => (json['trigger'] as Map?)?.cast<String, dynamic>();
  DateTime? get lastRun => json['lastRun'] == null ? null : DateTime.fromMillisecondsSinceEpoch(json['lastRun'] as int);
}

class McpServer {
  McpServer(this.json);
  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get name => json['name'] as String;
  String get type => json['type'] as String;
  String? get command => json['command'] as String?;
  bool get inContainer => json['inContainer'] == true;
  String? get url => json['url'] as String?;
  Map<String, String> get env => (json['env'] as Map? ?? const {}).cast<String, String>();
  Map<String, String> get headers => (json['headers'] as Map? ?? const {}).cast<String, String>();
  bool get enabled => json['enabled'] == true;
  String get status => json['status'] as String? ?? 'disabled';
  String? get error => json['error'] as String?;
  List<Map<String, dynamic>> get tools => _l(json['tools']);
}

class SlashCommand {
  SlashCommand(this.name, this.description, this.hint, {required this.isSkill});
  final String name;
  final String description;
  final String? hint;
  final bool isSkill;
}

// ---------------------------------------------------------------------------

/// Everything beyond plain chat: approvals, checkpoints, git, search, runs,
/// MCP, templates, usage, backups. Live records from the host (approvals,
/// dev servers, run updates) are kept here for the UI to watch.
class Features extends ChangeNotifier {
  Features(this.client) {
    client.records.listen(_onRecord);
  }

  final AgentClient client;
  final _taskLines = StreamController<Map<String, dynamic>>.broadcast();
  int _nextTask = 1;

  /// Approvals waiting for an answer, oldest first.
  final approvals = <Approval>[];

  /// Local dev servers seen in command output: port -> url.
  final devServers = <int, String>{};

  /// Public tunnel URLs: port -> url.
  final tunnels = <int, String>{};

  List<RunInfo> runs = const [];
  List<ScheduleInfo> schedules = const [];
  int concurrency = 1;
  bool keepAlive = false;

  /// Whether an interactive chat turn is streaming. Together with the
  /// runs/schedules signal below, this keeps the foreground service alive
  /// while the agent works — previously only runs/schedules did, so
  /// Android could kill the host mid-chat when the app was backgrounded.
  bool chatBusy = false;

  /// Background jobs running on this phone's host (they outlive the turn that started them).
  int jobsRunning = 0;
  bool _runsKeepAlive = false;
  List<McpServer> mcpServers = const [];

  /// Fired when the chat's run ends (for notifications): preview text.
  final done = StreamController<String>.broadcast();

  /// Fired when a background run finishes.
  final runFinished = StreamController<RunInfo>.broadcast();

  void _onRecord(Map<String, dynamic> r) {
    switch (r['type']) {
      case 'task':
        _taskLines.add(r);
      case 'approval':
        approvals.add(Approval(r));
        notifyListeners();
      case 'approval_dismiss':
        approvals.removeWhere((a) => a.id == r['approvalId']);
        notifyListeners();
      case 'exit':
      case 'fatal':
        // A server agent's link dropped: the host is still there and its approvals still wait. Reconnecting replays
        // what changed, or, when it cannot, the controller reloads them (replaceApprovals).
        if (r['type'] == 'exit' && client.isRemote) return;
        // The host process is gone: any card left on screen belongs to a
        // dead process, and its id must never answer a new process's approval.
        approvals.clear();
        _answered.clear();
        notifyListeners();
      case 'dev_server':
        final port = r['port'] as int;
        if (!devServers.containsKey(port)) {
          devServers[port] = r['url'] as String;
          notifyListeners();
        }
      case 'tunnel':
        final port = r['port'] as int;
        if (r['closed'] == true || r['url'] == null) {
          tunnels.remove(port);
        } else {
          tunnels[port] = r['url'] as String;
        }
        notifyListeners();
      case 'runs':
        _applyRuns(r);
      case 'run_finished':
        runFinished.add(RunInfo(_m(r['run'])));
      case 'mcp':
        mcpServers = _l(r['servers']).map(McpServer.new).toList();
        notifyListeners();
      case 'agent_done':
        // A fallback model taking over the failed turn: not done yet.
        if (r['retrying'] != true) done.add(r['preview'] as String? ?? '');
    }
  }

  void setChatBusy(bool value) {
    if (chatBusy == value) return;
    chatBusy = value;
    _updateKeepAlive();
  }

  /// How many background jobs run, so the host is kept alive for them while the app is in the background.
  void setJobsRunning(int count) {
    if (jobsRunning == count) return;
    jobsRunning = count;
    _updateKeepAlive();
  }

  void _updateKeepAlive() {
    // A server agent works on the server; the phone has nothing to keep alive for it.
    final next = !client.isRemote && (_runsKeepAlive || chatBusy || jobsRunning > 0);
    if (keepAlive == next) return;
    keepAlive = next;
    unawaited(client.keepAlive(keepAlive, text: _keepAliveText()));
  }

  void _applyRuns(Map<String, dynamic> s) {
    runs = _l(s['runs']).map(RunInfo.new).toList();
    schedules = _l(s['schedules']).map(ScheduleInfo.new).toList();
    concurrency = s['concurrency'] as int? ?? 1;
    _runsKeepAlive = s['keepAlive'] == true;
    _updateKeepAlive();
    notifyListeners();
  }

  String _keepAliveText() {
    final running = runs.where((r) => r.status == 'running').length;
    final queued = runs.where((r) => r.status == 'queued').length;
    if (running + queued > 0) return '$running running, $queued queued';
    if (chatBusy) return 'Agent is working';
    if (jobsRunning > 0) return jobsRunning == 1 ? '1 background job running' : '$jobsRunning background jobs running';
    return '${schedules.where((s) => s.enabled).length} scheduled tasks';
  }

  Future<T> _task<T>(String type, Map<String, dynamic> args, void Function(String)? onLine) async {
    final taskId = 'f${_nextTask++}';
    final sub = _taskLines.stream.where((r) => r['taskId'] == taskId).listen((r) {
      if (r['line'] != null) onLine?.call(r['line'] as String);
    });
    try {
      return await client.call<T>(type, {...args, 'taskId': taskId});
    } finally {
      await sub.cancel();
    }
  }

  // Approvals & plan mode -----------------------------------------------------
  /// Ids already answered: a double-tap on a card must never answer twice.
  final _answered = <String>{};

  /// Puts the chat's waiting approvals back as the host lists them (`approvals_pending`), after a server link could
  /// not replay what it missed.
  void replaceApprovals(Iterable<Map<String, dynamic>> records) {
    approvals
      ..clear()
      ..addAll(records.where((r) => r['type'] == 'approval' && !_answered.contains(r['approvalId'])).map(Approval.new));
    notifyListeners();
  }

  Future<void> answer(Approval a, {required bool allow, bool always = false}) async {
    if (!_answered.add(a.id)) return;
    approvals.remove(a);
    notifyListeners();
    await client.call('approval_reply', {'approvalId': a.id, 'allow': allow, 'always': always, 'key': a.key});
  }

  // Conversation editing ------------------------------------------------------
  Future<List<({String entryId, String text})>> forkPoints() async =>
      (await client.call<List>('fork_points'))
          .map((e) => (entryId: (e as Map)['entryId'] as String, text: e['text'] as String))
          .toList();

  // Checkpoints ---------------------------------------------------------------
  Future<List<CheckpointInfo>> checkpoints({String? dir}) async =>
      (await client.call<List>('checkpoints', {'dir': ?dir})).map((e) => CheckpointInfo(_m(e))).toList();
  Future<void> createCheckpoint(String label, {String? dir}) =>
      client.call('checkpoint_create', {'label': label, 'dir': ?dir});
  Future<ChangeSet> changes({String? checkpoint, String? file, String? dir}) async =>
      ChangeSet(_m(await client.call('checkpoint_diff', {'checkpoint': ?checkpoint, 'file': ?file, 'dir': ?dir})));
  /// Files a restore to [checkpoint] would delete (they did not exist then).
  Future<List<String>> restorePlan(String checkpoint, {String? dir}) async =>
      ((_m(await client.call('checkpoint_restore_plan', {'checkpoint': checkpoint, 'dir': ?dir})))['removes'] as List? ??
              const [])
          .cast<String>();

  /// Restores [checkpoint]; files in [keep] (from [restorePlan]) are left as they are.
  Future<void> restore(String checkpoint, {String? dir, List<String> keep = const []}) =>
      client.call('checkpoint_restore', {'checkpoint': checkpoint, 'dir': ?dir, 'keep': keep});

  // Git -----------------------------------------------------------------------
  Future<GitStatus> gitStatus({String? dir}) async => GitStatus(_m(await client.call('git_status', {'dir': ?dir})));
  Future<String> gitDiff({String? file, bool staged = false, String? dir}) async =>
      _m(await client.call('git_diff', {'file': ?file, 'staged': staged, 'dir': ?dir}))['patch'] as String? ?? '';
  Future<GitStatus> gitStage(List<String>? paths, {String? dir}) async =>
      GitStatus(_m(await client.call('git_stage', {'paths': paths ?? 'all', 'dir': ?dir})));
  Future<GitStatus> gitUnstage(List<String>? paths, {String? dir}) async =>
      GitStatus(_m(await client.call('git_unstage', {'paths': paths ?? 'all', 'dir': ?dir})));
  Future<GitStatus> gitDiscard(List<String> paths, {String? dir}) async =>
      GitStatus(_m(await client.call('git_discard', {'paths': paths, 'dir': ?dir})));
  Future<GitReview> gitReview({String? dir}) async => GitReview(_m(await client.call('git_review', {'dir': ?dir})));

  /// A commit message for the uncommitted changes, written by the chat's model.
  Future<String> gitCommitMessage({String? dir}) async =>
      _m(await client.call('git_commit_message', {'dir': ?dir}))['message'] as String? ?? '';
  Future<String> gitCommit(String message, {bool all = false, String? dir}) async =>
      _m(await client.call('git_commit', {'message': message, 'all': all, 'dir': ?dir}))['commit'] as String;
  Future<List<GitCommit>> gitLog({String? dir}) async =>
      (await client.call<List>('git_log', {'dir': ?dir})).map((e) => GitCommit(_m(e))).toList();
  Future<List<GitBranch>> gitBranches({String? dir}) async =>
      (await client.call<List>('git_branches', {'dir': ?dir})).map((e) => GitBranch(_m(e))).toList();
  Future<GitStatus> gitCheckout(String branch, {bool create = false, String? dir}) async =>
      GitStatus(_m(await client.call('git_checkout', {'branch': branch, 'create': create, 'dir': ?dir})));
  /// Fetches origin, so branches created on GitHub since the clone show up; returns the status after.
  Future<GitStatus> gitFetch({String? dir}) async => GitStatus(_m(await client.call('git_fetch', {'dir': ?dir})));
  Future<void> gitPull({String? dir, void Function(String)? onLine}) => _task('git_pull', {'dir': ?dir}, onLine);
  Future<void> gitPush({String? dir, void Function(String)? onLine}) => _task('git_push', {'dir': ?dir}, onLine);
  Future<String> createPr(String title, String body, {String? base, String? dir}) async =>
      _m(await client.call('github_pr_create', {'title': title, 'body': body, 'base': ?base, 'dir': ?dir}))['url']
          as String;
  Future<(String repo, List<GithubIssue>)> issues({String state = 'open', String? dir}) async {
    final r = _m(await client.call('github_issues', {'state': state, 'dir': ?dir}));
    return (r['repo'] as String, _l(r['issues']).map(GithubIssue.new).toList());
  }

  // Project tools ---------------------------------------------------------------
  Future<(List<SearchMatch>, bool truncated)> search(
    String query, {
    bool regex = false,
    bool caseSensitive = false,
    String? glob,
    String? dir,
  }) async {
    final r = _m(
      await client.call('search', {
        'query': query,
        'regex': regex,
        'caseSensitive': caseSensitive,
        'glob': ?glob,
        'dir': ?dir,
      }),
    );
    return (_l(r['matches']).map(SearchMatch.new).toList(), r['truncated'] == true);
  }

  /// The project's files best matching [query] by name, for the composer's @ list.
  Future<List<String>> findFiles(String query, {int limit = 30}) async {
    final r = _m(await client.call('files_find', {'query': query, 'limit': limit}));
    final files = r['files'];
    return files is List ? [for (final f in files) if (f is String) f] : const [];
  }

  Future<List<DbTable>> dbTables(String path) async =>
      (await client.call<List>('db_tables', {'path': path})).map((e) => DbTable(_m(e))).toList();
  Future<DbResult> dbQuery(String path, String sql) async =>
      DbResult(_m(await client.call('db_query', {'path': path, 'sql': sql})));
  Future<({String command, String framework})?> detectTests({String? dir}) async {
    final r = await client.call<Map?>('tests_detect', {'dir': ?dir});
    return r == null ? null : (command: r['command'] as String, framework: r['framework'] as String);
  }

  Future<String> startTunnel(int port) async {
    final url = _m(await client.call('tunnel_start', {'port': port}))['url'] as String;
    tunnels[port] = url;
    notifyListeners();
    return url;
  }

  Future<void> stopTunnel(int port) async {
    await client.call('tunnel_stop', {'port': port});
    tunnels.remove(port);
    notifyListeners();
  }

  void dismissDevServer(int port) {
    devServers.remove(port);
    notifyListeners();
  }

  Future<List<UsageRow>> usage({int days = 30}) async =>
      (await client.call<List>('usage', {'days': days})).map((e) => UsageRow(_m(e))).toList();
  Future<Map<String, dynamic>> sessionStats() async => _m(await client.call('session_stats'));

  // Templates & slash commands --------------------------------------------------
  Future<List<PromptTemplate>> templates() async =>
      (await client.call<List>('templates')).map((e) => PromptTemplate(_m(e))).toList();
  Future<void> saveTemplate(String name, String description, String body, {String? argumentHint}) => client.call(
    'template_save',
    {'name': name, 'description': description, 'body': body, 'argumentHint': ?argumentHint},
  );
  Future<void> deleteTemplate(String name) => client.call('template_delete', {'name': name});
  Future<List<SlashCommand>> slashCommands() async {
    final r = _m(await client.call('slash_commands'));
    return [
      for (final t in _l(r['templates']))
        SlashCommand(t['name'] as String, t['description'] as String? ?? '', t['hint'] as String?, isSkill: false),
      for (final s in _l(r['skills']))
        SlashCommand(s['name'] as String, s['description'] as String? ?? '', null, isSkill: true),
    ];
  }

  // Background runs & schedules -------------------------------------------------
  Future<void> refreshRuns() async => _applyRuns(_m(await client.call('runs')));
  Future<RunInfo> enqueue(String prompt, {String? dir, String? title}) async {
    final r = RunInfo(_m(await client.call('run_enqueue', {'prompt': prompt, 'dir': ?dir, 'title': ?title})));
    await refreshRuns();
    return r;
  }

  Future<void> cancelRun(String id) async => _applyRuns(_m(await client.call('run_cancel', {'runId': id})));
  Future<void> clearRuns() async => _applyRuns(_m(await client.call('runs_clear')));

  /// Removes one finished run from the list (its chat stays). Returns what [restoreRun] needs for Undo.
  Future<({Map<String, dynamic> run, int index})?> deleteRun(String id) async {
    final r = _m(await client.call('run_delete', {'runId': id}));
    _applyRuns(r);
    final removed = r['removed'];
    if (removed is! Map) return null;
    return (run: _m(removed['run']), index: removed['index'] as int? ?? 0);
  }

  Future<void> restoreRun(Map<String, dynamic> run, int index) async =>
      _applyRuns(_m(await client.call('run_restore', {'run': run, 'index': index})));
  Future<void> setConcurrency(int n) async => _applyRuns(_m(await client.call('runs_concurrency', {'n': n})));
  Future<void> saveSchedule(Map<String, dynamic> schedule) async =>
      _applyRuns(_m(await client.call('schedule_save', {'schedule': schedule})));
  Future<void> deleteSchedule(String id) async =>
      _applyRuns(_m(await client.call('schedule_delete', {'scheduleId': id})));
  Future<void> runScheduleNow(String id) async => _applyRuns(_m(await client.call('schedule_run', {'scheduleId': id})));

  // MCP -------------------------------------------------------------------------
  Future<void> refreshMcp() async {
    mcpServers = (await client.call<List>('mcp_servers')).map((e) => McpServer(_m(e))).toList();
    notifyListeners();
  }

  Future<void> saveMcp(Map<String, dynamic> server) async {
    mcpServers = (await client.call<List>('mcp_save', {'server': server})).map((e) => McpServer(_m(e))).toList();
    notifyListeners();
  }

  Future<void> deleteMcp(String id) async {
    mcpServers = (await client.call<List>('mcp_delete', {'serverId': id})).map((e) => McpServer(_m(e))).toList();
    notifyListeners();
  }

  // Backups ---------------------------------------------------------------------
  Future<({String path, int files})> backup({bool includeWorkspace = false}) async {
    final r = _m(await client.call('backup_create', {'includeWorkspace': includeWorkspace}));
    return (path: r['path'] as String, files: r['files'] as int);
  }

  Future<({int restored, int skipped})> restoreBackup(String path) async {
    final m = _m(await client.call('backup_restore', {'path': path}));
    return (restored: m['restored'] as int, skipped: m['skipped'] as int? ?? 0);
  }

  @override
  void dispose() {
    _taskLines.close();
    done.close();
    runFinished.close();
    super.dispose();
  }
}
