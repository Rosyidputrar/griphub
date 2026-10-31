// UI-15: animations ignored the system's "remove animations" setting outside a few files. Every animation's duration
// now goes through Motion.of (no time at all when animations are off); this keeps it that way.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// file:line text that may keep a fixed duration: not animations of the screen (a snackbar's time on screen), or ones
/// that already stop when animations are off (they check Motion.reduced themselves).
const _allowed = {
  'task_log.dart': ['duration: const Duration(seconds: 8)'], // a snackbar's time on screen
  'preview_open.dart': ['duration: const Duration(seconds: 8)'], // a snackbar's time on screen
  'terminal_screen.dart': ['duration: const Duration(seconds: 1)'], // a snackbar's time on screen
  'chat_screen.dart': ['scroll.animateTo(target, duration: const Duration(milliseconds: 250)'], // jumps when reduced
  'onboarding.dart': ['pages.nextPage(duration: const Duration(milliseconds: 320)'], // jumps when reduced
  'message_views.dart': ['AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))'], // stops when reduced
  'live_clock.dart': ['AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))'], // stops when reduced
};

void main() {
  test('every fixed animation duration in the app goes through Motion.of, or is on the list', () {
    final found = <String>[];
    final files = [...Directory('lib/ui').listSync().whereType<File>(), File('lib/main.dart')].where((f) => f.path.endsWith('.dart'));
    for (final f in files) {
      final name = f.uri.pathSegments.last;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i];
        if (!l.contains('duration: const Duration(') || l.contains('Motion.of(')) continue;
        if ((_allowed[name] ?? const []).any(l.contains)) continue;
        found.add('$name:${i + 1}: ${l.trim()}');
      }
    }
    expect(found, isEmpty, reason: 'durations that ignore "remove animations":\n${found.join('\n')}');
  });
}
