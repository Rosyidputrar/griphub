import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'agent_controller.dart';

/// Screen companion (Fitur 5; android Companion.kt, agent/src/companion.ts): the agent sees the user's screen one frame
/// at a time, when a step needs it, and points at the element of the step with a highlight over the other app. The
/// user's finger does everything; nothing here taps or types.
///
/// Started only by the user, with Android's consent each time; Stop ends capture at once. Frames go to the host for one
/// request and are kept nowhere (not in the chat, not in memory, not in a file).
class ScreenCompanion extends ChangeNotifier {
  ScreenCompanion._();
  static final instance = ScreenCompanion._();

  static const _method = MethodChannel('griphub/agent');

  /// Capture is allowed and on.
  bool active = false;

  /// A step is being looked at (frame taken, the agent answering).
  bool looking = false;

  /// The last frame's size and the screen's, to put a box from the frame on the screen.
  ({int width, int height, int screenWidth, int screenHeight})? _frame;

  /// The elements of the last step's screen (only with the accessibility service on), by id.
  final _nodes = <String, Map<String, dynamic>>{};

  StreamSubscription<Map<String, dynamic>>? _records;

  /// Whether a frame is a secure screen: Android renders FLAG_SECURE windows black. Dark and flat means unseen.
  static bool isSecureFrame(num mean, num deviation) => mean < 8 && deviation < 4;

  /// Where on the screen a pointer from the host goes, in screen pixels; null when it cannot be placed.
  @visibleForTesting
  static ({int x, int y, int w, int h})? place(
    Map<String, dynamic>? pointer, {
    ({int width, int height, int screenWidth, int screenHeight})? frame,
    Map<String, Map<String, dynamic>> nodes = const {},
  }) {
    if (pointer == null) return null;
    final id = pointer['id'];
    if (id is String) {
      final n = nodes[id];
      if (n == null) return null;
      int v(String k) => (n[k] as num?)?.toInt() ?? 0;
      return (x: v('x'), y: v('y'), w: v('w'), h: v('h'));
    }
    if (frame == null || frame.width == 0 || frame.height == 0) return null;
    final sx = frame.screenWidth / frame.width;
    final sy = frame.screenHeight / frame.height;
    int v(String k) => (pointer[k] as num?)?.toInt() ?? 0;
    final box = (x: (v('x') * sx).round(), y: (v('y') * sy).round(), w: (v('w') * sx).round(), h: (v('h') * sy).round());
    // A box outside the screen points at nothing.
    if (box.w <= 0 || box.h <= 0 || box.x >= frame.screenWidth || box.y >= frame.screenHeight) return null;
    return box;
  }

  /// Starts: Android's consent dialog, then the host records the start in the chat. False when the user declined.
  Future<bool> start(AgentController agent) async {
    final ok = await _method.invokeMethod<bool>('companionStart') ?? false;
    if (!ok) return false;
    await agent.client.call('companion_start');
    active = true;
    // Follows this agent's records (a new start may come with a new client: after a reconnect, in tests).
    unawaited(_records?.cancel());
    _records = agent.client.records.listen((r) => _onRecord(agent, r));
    notifyListeners();
    return true;
  }

  /// One step: the screen as it is now (or the fact that it cannot be seen), with the user's words.
  Future<void> step(AgentController agent, String text) async {
    if (!active || looking) return;
    looking = true;
    notifyListeners();
    try {
      await _method.invokeMethod('companionClearHighlight');
      final f = (await _method.invokeMethod<Map>('companionCapture'))?.cast<String, dynamic>();
      if (f == null) throw StateError('No frame came from the screen. Try again.');
      final secure = isSecureFrame(f['mean'] as num? ?? 255, f['deviation'] as num? ?? 255);
      _frame = (
        width: (f['width'] as num?)?.toInt() ?? 0,
        height: (f['height'] as num?)?.toInt() ?? 0,
        screenWidth: (f['screenWidth'] as num?)?.toInt() ?? 0,
        screenHeight: (f['screenHeight'] as num?)?.toInt() ?? 0,
      );
      final tree = secure || !(await _method.invokeMethod<bool>('a11yStatus') ?? false)
          ? const <Map<String, dynamic>>[]
          : [for (final n in (await _method.invokeMethod<List>('a11yTree') ?? const [])) (n as Map).cast<String, dynamic>()];
      _nodes
        ..clear()
        ..addEntries(tree.map((n) => MapEntry(n['id'] as String, n)));
      await agent.client.call('companion_turn', {
        'text': text,
        'secure': secure,
        if (!secure) 'frame': {'data': f['data'], 'mimeType': f['mimeType'], 'width': f['width'], 'height': f['height']},
        if (tree.isNotEmpty) 'tree': tree,
      });
    } catch (_) {
      looking = false;
      notifyListeners();
      rethrow;
    }
  }

  void _onRecord(AgentController agent, Map<String, dynamic> r) {
    switch (r['type']) {
      // The step ended: point at its element over the other app, when it named one.
      case 'companion_pointer':
        looking = false;
        final box = place((r['pointer'] as Map?)?.cast<String, dynamic>(), frame: _frame, nodes: _nodes);
        if (box != null) {
          unawaited(_method.invokeMethod('companionHighlight', {'x': box.x, 'y': box.y, 'w': box.w, 'h': box.h}));
        }
        notifyListeners();
      // Stopped from the notification (or Android ended the capture).
      case 'companion_native' when r['active'] == false:
        if (active) unawaited(stop(agent));
      // The host ended it (the chat it belongs to was left): capture ends on the phone too; the chat has the record.
      case 'companion' when r['event'] == 'stop':
        if (active) unawaited(_endOnPhone());
      // A step that failed (or ended without its pointer): no longer looking, so the next step can be asked for.
      case 'error' || 'agent_done' when looking && r['retrying'] != true:
        looking = false;
        notifyListeners();
    }
  }

  Future<void> _endOnPhone() async {
    active = false;
    looking = false;
    _frame = null;
    _nodes.clear();
    notifyListeners();
    try {
      await _method.invokeMethod('companionStop');
    } catch (_) {}
  }

  /// Stops at once: capture, the service and the highlight on the phone, then the record in the chat.
  Future<void> stop(AgentController agent) async {
    active = false;
    looking = false;
    _frame = null;
    _nodes.clear();
    notifyListeners();
    try {
      await _method.invokeMethod('companionStop');
    } catch (_) {}
    try {
      await agent.client.call('companion_stop');
    } catch (_) {}
  }
}
