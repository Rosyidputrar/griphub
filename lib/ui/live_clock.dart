import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/clock.dart';
import 'i18n.dart';
import 'theme.dart';

/// How a [LiveClock] stands: still running, or how it ended.
enum ClockState { running, done, failed, stopped }

/// A duration the app waits on, shown the same way for the agent's turn and for a background job: blue and
/// shimmering, counting every second while it runs; once it ends it stops at the time it took, green when it went
/// well (red when it failed, grey when it was stopped).
class LiveClock extends StatefulWidget {
  const LiveClock({
    super.key,
    required this.label,
    this.startedAt,
    this.took,
    this.state = ClockState.running,
    this.detail,
  });

  /// What is being timed ("Working", "Build"). Shown before the time.
  final String label;

  /// When it started, while it runs (by this phone's clock).
  final DateTime? startedAt;

  /// How long it took, once it ended.
  final Duration? took;
  final ClockState state;

  /// Said after the time (tokens so far, an exit code).
  final String? detail;

  @override
  State<LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<LiveClock> with SingleTickerProviderStateMixin {
  late final _shimmer = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  Timer? _tick;

  bool get _running => widget.state == ClockState.running;

  @override
  void didUpdateWidget(LiveClock old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) _sync();
  }

  /// Also the first sync after initState: whether animations are off comes from the MediaQuery.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  /// Ticks once a second and shimmers while running; still once it ended, or when animations are off (the time still
  /// counts then).
  void _sync() {
    if (_running) {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      final reduced = Motion.reduced(context);
      if (reduced) {
        _shimmer.stop();
      } else if (!_shimmer.isAnimating) {
        _shimmer.repeat();
      }
    } else {
      _tick?.cancel();
      _tick = null;
      _shimmer.stop();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _shimmer.dispose();
    super.dispose();
  }

  Duration get _elapsed {
    if (!_running) return widget.took ?? Duration.zero;
    final start = widget.startedAt;
    if (start == null) return Duration.zero;
    final d = clock().difference(start);
    return d.isNegative ? Duration.zero : d;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = switch (widget.state) {
      ClockState.running => p.accentAlt,
      ClockState.done => p.success,
      ClockState.failed => p.danger,
      ClockState.stopped => p.muted,
    };
    final style = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]);
    final icon = switch (widget.state) {
      ClockState.running => LucideIcons.timer,
      ClockState.done => LucideIcons.circleCheck,
      ClockState.failed => LucideIcons.circleX,
      ClockState.stopped => LucideIcons.circleStop,
    };
    // Only the label gives way on a narrow line: the time (and what follows it) is what the clock is for.
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
        ),
        Text(' · ${[formatDurationShort(_elapsed), ?widget.detail].join(' · ')}', maxLines: 1, style: style),
      ],
    );
    return Semantics(
      liveRegion: !_running,
      label: _running ? '${widget.label}, ${tr('running')}' : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: !_running
                ? label
                : AnimatedBuilder(
                    animation: _shimmer,
                    builder: (context, child) => ShaderMask(
                      blendMode: BlendMode.srcIn,
                      // A lighter band sweeping across the blue text while it runs.
                      shaderCallback: (rect) => LinearGradient(
                        colors: [color, Color.lerp(color, p.bg, 0.55)!, color],
                        stops: const [0, 0.5, 1],
                        begin: Alignment(-2.5 + 4 * _shimmer.value, 0),
                        end: Alignment(-0.5 + 4 * _shimmer.value, 0),
                      ).createShader(rect),
                      child: child,
                    ),
                    child: label,
                  ),
          ),
        ],
      ),
    );
  }
}
