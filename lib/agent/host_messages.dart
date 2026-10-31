/// Messages the host builds with numbers in them ("Daily budget of 5 credits reached ..."). Their English text is the
/// only copy the host has, so the app recognises them here and says them in its own language.
library;

/// A request that was ended by a limit, which the person can do something about.
enum LimitStop { budget, toolCalls }

final _budget = RegExp(r'^Daily budget of ([\d.]+) credits reached \(([\d.]+) credits spent today\)\. Raise it in Settings → Usage\.$');
final _toolCalls = RegExp(r'^Stopped after (\d+) tool calls in one request\.$');

/// Which limit [message] is about, or null when it is some other message.
LimitStop? limitStopOf(String message) {
  final m = message.trim();
  if (_budget.hasMatch(m)) return LimitStop.budget;
  if (_toolCalls.hasMatch(m)) return LimitStop.toolCalls;
  return null;
}

/// The numbers in a limit message, in the order they appear ("5", "5.02"), or null.
List<String>? limitNumbers(String message) {
  final m = message.trim();
  final b = _budget.firstMatch(m);
  if (b != null) return [b[1]!, b[2]!];
  final t = _toolCalls.firstMatch(m);
  return t == null ? null : [t[1]!];
}
