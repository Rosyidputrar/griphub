import 'subagents.dart';

/// Notification decisions for subagents, kept separate from the controller
/// so the rules are unit-testable with recording fakes.
///
/// Privacy rule: notifications never carry report content, briefs, tool
/// results, or chat titles (a chat title can be the user's first message).
/// They only say a subagent finished/failed/needs approval/is running, and
/// tapping one always opens the parent chat — never a new chat.
///
/// The controller decides WHICH subagents are worth a notification: those
/// whose chat is not on screen (another chat, or the app is in the
/// background). The "running" notification stays until those subagents
/// finish; parallel subagents share one summary notification instead of one
/// per subagent. Texts are English keys passed through [translate].
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

String _same(String s) => s;

class SubagentNotifier {
  SubagentNotifier({required this.notify, required this.cancel, String Function(String)? translate})
    : translate = translate ?? _same;
  final SubagentNotifyFn notify;
  final SubagentCancelFn cancel;

  /// UI language for the notification texts (the app passes its `tr`).
  String Function(String) translate;

  /// Fixed ids: a single running subagent, and the parallel summary.
  static const runningId = 910001;
  static const summaryId = 910002;

  final _approvalIds = <String, int>{};
  int _nextId = 930000;

  /// What the running notification currently shows, so identical syncs post nothing.
  String? _runningShown;

  int _freshId() => _nextId++;

  Map<String, Object?> _launch(SubagentState s) => {'action': 'open_chat', 'path': s.parentSessionFile};

  String get _tapBody => translate('Tap to open the parent chat.');

  /// Keeps the running notification in step with [unseen] active subagents:
  /// one running, a summary when several, none when zero or when [enabled]
  /// is off.
  Future<void> syncRunning(List<SubagentState> unseen, {bool enabled = true}) async {
    final active = enabled ? unseen.where((s) => s.isActive).toList() : const <SubagentState>[];
    final shown = active.isEmpty
        ? null
        : '${active.length}|${active.first.parentSessionFile}|${translate('Subagent running')}';
    if (shown == _runningShown) return;
    _runningShown = shown;
    if (active.isEmpty) {
      await cancel(runningId).catchError((_) {});
      await cancel(summaryId).catchError((_) {});
      return;
    }
    if (active.length == 1) {
      await cancel(summaryId).catchError((_) {});
      await notify(
        runningId,
        translate('Subagent running'),
        _tapBody,
        channel: 'chats',
        launch: _launch(active.first),
      ).catchError((_) {});
      return;
    }
    await cancel(runningId).catchError((_) {});
    await notify(
      summaryId,
      translate('{n} subagents running').replaceAll('{n}', '${active.length}'),
      _tapBody,
      channel: 'chats',
      launch: _launch(active.first),
    ).catchError((_) {});
  }

  /// Terminal notification. Stopped ones never notify: the user (or a limit
  /// they set) stopped them, and the card says why.
  Future<void> notifyFinished(SubagentState s, {required bool notifyDone, required bool notifyFailed}) async {
    if (s.status == SubagentStatus.done && !notifyDone) return;
    if (s.status == SubagentStatus.failed && !notifyFailed) return;
    if (s.status != SubagentStatus.done && s.status != SubagentStatus.failed) return;
    await notify(
      _freshId(),
      translate(s.status == SubagentStatus.done ? 'Subagent finished' : 'Subagent failed'),
      _tapBody,
      channel: 'chats',
      launch: _launch(s),
    ).catchError((_) {});
  }

  Future<void> notifyApproval(SubagentState s, SubagentApproval ap, {required bool enabled}) async {
    if (!enabled || _approvalIds.containsKey(ap.approvalId)) return;
    final id = _freshId();
    _approvalIds[ap.approvalId] = id;
    await notify(
      id,
      translate('Subagent needs approval'),
      translate('Tap to open the parent chat and answer.'),
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
