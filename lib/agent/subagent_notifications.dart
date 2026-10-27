import 'subagents.dart';

/// Notification decisions for subagents, kept separate from the controller
/// so the rules are unit-testable with recording fakes.
///
/// Privacy rule: notifications never carry report content, briefs, tool
/// results, or chat titles (a chat title can be the user's first message).
/// They only say a subagent finished/failed/needs approval/is running, and
/// tapping one always opens the parent chat — never a new chat.
///
/// Only subagents of OTHER chats notify. When the parent chat is open, the
/// card and modal already show everything, so notifying would double-report.
/// The "running" notification is persistent in the shade sense: it stays
/// until the subagent finishes (then it is cancelled and, for done/failed,
/// replaced by a terminal notification). Parallel subagents share one
/// summary notification instead of one per subagent.
typedef SubagentNotifyFn =
    Future<void> Function(
      int id,
      String title,
      String body, {
      String channel,
      Map<String, Object?>? launch,
      List<({String label, Map<String, Object?> launch})> actions,
    });

typedef SubagentCancelFn = Future<void> Function(int id);

class SubagentNotifier {
  SubagentNotifier({required this.notify, required this.cancel});
  final SubagentNotifyFn notify;
  final SubagentCancelFn cancel;

  /// Fixed ids: a single running subagent, and the parallel summary.
  static const runningId = 910001;
  static const summaryId = 910002;

  final _approvalIds = <String, int>{};
  int _nextId = 930000;

  int _freshId() => _nextId++;

  Map<String, Object?> _launch(SubagentState s) => {
    'action': 'open_chat',
    'path': s.parentSessionFile,
  };

  /// Keeps the running notification in step with active subagents of other
  /// chats: one running, a summary when several, none when zero.
  Future<void> syncRunning(List<SubagentState> elsewhere) async {
    if (elsewhere.isEmpty) {
      await cancel(runningId).catchError((_) {});
      await cancel(summaryId).catchError((_) {});
      return;
    }
    if (elsewhere.length == 1) {
      await cancel(summaryId).catchError((_) {});
      await notify(
        runningId,
        'Subagent berjalan',
        'Ketuk untuk membuka chat induk.',
        channel: 'chats',
        launch: _launch(elsewhere.first),
      ).catchError((_) {});
      return;
    }
    await cancel(runningId).catchError((_) {});
    await notify(
      summaryId,
      '${elsewhere.length} subagent berjalan',
      'Ketuk untuk membuka chat induk.',
      channel: 'chats',
      launch: _launch(elsewhere.first),
    ).catchError((_) {});
  }

  /// Terminal notification for a subagent of another chat. Stopped ones
  /// never notify: the user stopped them on purpose.
  Future<void> notifyFinished(SubagentState s, {required bool notifyDone, required bool notifyFailed}) async {
    if (s.status == SubagentStatus.done && !notifyDone) return;
    if (s.status == SubagentStatus.failed && !notifyFailed) return;
    if (s.status != SubagentStatus.done && s.status != SubagentStatus.failed) return;
    await notify(
      _freshId(),
      s.status == SubagentStatus.done ? 'Subagent selesai' : 'Subagent gagal',
      'Ketuk untuk membuka chat induk.',
      channel: 'chats',
      launch: _launch(s),
    ).catchError((_) {});
  }

  Future<void> notifyApproval(SubagentState s, SubagentApproval ap, {required bool enabled}) async {
    if (!enabled) return;
    final id = _freshId();
    _approvalIds[ap.approvalId] = id;
    await notify(
      id,
      'Subagent minta persetujuan',
      'Ketuk untuk membuka chat induk dan menjawab.',
      channel: 'approvals',
      launch: _launch(s),
    ).catchError((_) {});
  }

  /// Drops the approval notification once the request is answered or withdrawn.
  Future<void> cancelApproval(String approvalId) async {
    final id = _approvalIds.remove(approvalId);
    if (id != null) await cancel(id).catchError((_) {});
  }
}
