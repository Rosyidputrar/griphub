import 'clock.dart';

/// A background job (agent/src/jobs.ts): a long command the agent started without waiting for it. When it ends, its
/// chat is called back with the result as a turn of its own.
class JobState {
  JobState(Map<String, dynamic> json) {
    apply(json);
  }

  late String id;
  late String sessionFile;
  String? toolCallId;
  late String command;
  late String label;
  late String cwd;

  /// running, done, failed, timeout or stopped.
  late String status;
  int? exitCode;
  late int limitMinutes;

  /// The end of its output.
  String tail = '';

  /// When it started by this phone's clock: the host says how long it has run, so a server with another clock still
  /// counts right here.
  late DateTime startedAt;

  /// How long it ran, once it ended.
  Duration? took;

  bool get running => status == 'running';
  bool get ok => status == 'done';

  /// How long it has run so far (live while running).
  Duration get elapsed => took ?? clock().difference(startedAt);

  void apply(Map<String, dynamic> json) {
    id = json['id'] as String;
    sessionFile = json['sessionFile'] as String? ?? '';
    toolCallId = json['toolCallId'] as String?;
    command = json['command'] as String? ?? '';
    label = json['label'] as String? ?? command;
    cwd = json['cwd'] as String? ?? '';
    status = json['status'] as String? ?? 'running';
    exitCode = (json['exitCode'] as num?)?.toInt();
    limitMinutes = (json['limitMinutes'] as num?)?.toInt() ?? 60;
    tail = json['tail'] as String? ?? '';
    final elapsed = Duration(milliseconds: (json['elapsedMs'] as num?)?.toInt() ?? 0);
    startedAt = clock().subtract(elapsed);
    took = status == 'running' ? null : elapsed;
  }
}

/// The background jobs the host told the app about, by id.
class JobStore {
  final _jobs = <String, JobState>{};

  Iterable<JobState> get all => _jobs.values;
  JobState? operator [](String id) => _jobs[id];

  /// The job a `background_job` call started.
  JobState? forToolCall(String? toolCallId) =>
      toolCallId == null ? null : _jobs.values.where((j) => j.toolCallId == toolCallId).firstOrNull;

  int get running => _jobs.values.where((j) => j.running).length;

  void apply(Map<String, dynamic> json) {
    final id = json['id'] as String;
    final known = _jobs[id];
    if (known != null) {
      known.apply(json);
    } else {
      _jobs[id] = JobState(json);
    }
  }

  void replaceAll(Iterable<Map<String, dynamic>> list) {
    _jobs.clear();
    for (final j in list) {
      apply(j);
    }
  }
}
