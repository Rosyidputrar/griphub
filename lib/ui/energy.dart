import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'theme.dart';

/// How a wait ended, for an [EnergySpinner] that turns into a check or a cross.
enum EnergyOutcome { success, failure }

/// The colours of the spinner's comets for one theme: a bright head, a tail running from magenta through purple and
/// indigo to blue, and the check and cross it can turn into. The spinner is drawn on whatever is behind it (no fill of
/// its own), so on a light page the head is the darkest part and on a dark page the lightest.
@immutable
class EnergyColors {
  const EnergyColors({
    required this.palette,
    required this.halo,
    required this.success,
    required this.failure,
    this.tailFloor = 0,
  });

  /// Head, then blue, indigo, purple, magenta (the tail table below picks from these by index).
  final List<Color> palette;

  /// A soft wider stroke under the big spinner's comets, in place of a blurred glow (none when transparent).
  final Color halo;
  final Color success;
  final Color failure;

  /// How much of the tail's fade is taken back: a tail fading to nearly nothing on white reads as lavender haze.
  final double tailFloor;

  static const dark = EnergyColors(
    palette: [Color(0xFFDBEAFE), Color(0xFF1E3CFF), Color(0xFF4F46E5), Color(0xFF7C3AED), Color(0xFFC026D3)],
    halo: Color(0x297C3AED),
    success: Color(0xFF4ADE80),
    failure: Color(0xFFFF6369),
  );

  /// On white a light head disappears and a glow turns into haze: the same hues, deeper, and only a faint halo.
  static const light = EnergyColors(
    palette: [Color(0xFF3730A3), Color(0xFF1D4ED8), Color(0xFF4F46E5), Color(0xFF6D28D9), Color(0xFFA21CAF)],
    halo: Color(0x146D28D9),
    success: Color(0xFF16A34A),
    failure: Color(0xFFDC2626),
    tailFloor: .25,
  );

  static EnergyColors of(BuildContext context) => Theme.of(context).brightness == Brightness.dark ? dark : light;
}

// The comet's tail, head first: how wide, how opaque and which colour each of its 14 parts is.
const _factors = [1.0, .92, .84, .77, .69, .62, .54, .47, .39, .32, .25, .18, .12, .05];
const _opacities = [1.0, .91, .84, .76, .70, .63, .56, .50, .43, .37, .31, .24, .18, .12];
const _colorIdx = [0, 4, 4, 4, 3, 3, 3, 2, 2, 2, 1, 1, 1, 1];
const _smallIdx = [0, 4, 4, 4, 4, 4, 3, 3, 3, 3, 3, 3, 3, 3];

/// Sizes from this up get the full spinner: four comets on tilted orbits. Below it, two comets on one flat ring, which
/// reads at 12–24 px where four orbits turn into noise.
const energyHeroSize = 28.0;

/// What the app shows while it waits: comets circling. Big (from [energyHeroSize]) it is four comets on tilted orbits,
/// for a screen or panel with nothing to show yet; small it is two comets on a ring, for a button or a row. With
/// [color] the comets are that one colour (on a filled button, or where the colour says something); otherwise they
/// take the theme's [EnergyColors]. Given an [outcome], the comets slow down, flatten and gather into a check or a
/// cross.
///
/// It stays cheap: each comet is one path built once per size and theme, and a frame only turns the canvas and draws
/// it (no blur, no offscreen layers). It repaints on its own layer without rebuilding, stops when its route is hidden,
/// and stands still when the system removes animations.
class EnergySpinner extends StatefulWidget {
  const EnergySpinner({super.key, this.size = 16, this.color, this.outcome});

  final double size;
  final Color? color;
  final EnergyOutcome? outcome;

  /// How long the turn into a check or a cross takes until the symbol stands (its ripple fades a little after).
  static const outcomeDuration = Duration(milliseconds: 650);

  @override
  State<EnergySpinner> createState() => _EnergySpinnerState();
}

class _EnergySpinnerState extends State<EnergySpinner> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  final _clock = _SpinClock();
  bool _reduced = false;

  // Seconds already run before the ticker last (re)started: its elapsed time starts again from zero each start.
  double _base = 0;

  @override
  void initState() {
    super.initState();
    // Made with its outcome already known: it turns at once.
    if (widget.outcome != null) _clock.outcomeAt = 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = Motion.reduced(context);
    _sync();
  }

  @override
  void didUpdateWidget(EnergySpinner old) {
    super.didUpdateWidget(old);
    if (old.outcome != widget.outcome) {
      _clock.outcomeAt = widget.outcome == null ? null : _clock.t;
      _sync();
    }
  }

  void _onTick(Duration elapsed) {
    _clock.t = _base + elapsed.inMicroseconds / 1e6;
    final at = _clock.outcomeAt;
    // Once the check or cross has formed nothing moves any more.
    if (at != null && _clock.t - at > _Painter.outcomeEnd) _stop();
  }

  void _stop() {
    if (!_ticker.isActive) return;
    _base = _clock.t;
    _ticker.stop();
  }

  void _sync() {
    final settled = _clock.outcomeAt != null && _clock.t - _clock.outcomeAt! > _Painter.outcomeEnd;
    if (_reduced || settled) {
      _stop();
      _clock.notify();
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = EnergyColors.of(context);
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: CustomPaint(
          willChange: true,
          painter: _Painter(
            clock: _clock,
            comets: _Comets.of(widget.size, colors, widget.color),
            colors: colors,
            solid: widget.color,
            outcome: widget.outcome,
            still: _reduced,
          ),
        ),
      ),
    );
  }
}

/// The spinner's time, in seconds, which the painter reads on each frame: the ticker only moves this, nothing rebuilds.
class _SpinClock extends ChangeNotifier {
  double _t = 0;
  double get t => _t;
  set t(double v) {
    _t = v;
    notifyListeners();
  }

  /// When the outcome was given, on the same clock.
  double? outcomeAt;

  void notify() => notifyListeners();
}

/// A comet's shape and paint, made once for a size and colour and then only turned and drawn.
class _Comet {
  _Comet({
    required this.radius,
    required this.width,
    required this.tail,
    required EnergyColors colors,
    Color? solid,
    bool small = false,
  }) {
    const n = 24;
    final outer = <Offset>[];
    final inner = <Offset>[];
    for (var j = 0; j < n; j++) {
      final f = j / (n - 1);
      final a = -math.pi / 2 - f * 2 * math.pi * tail;
      // A small comet thins out only by half: a tail tapering to a hair is invisible at 16 px.
      final factor = _lerpTable(_factors, f);
      final w = width * (small ? .45 + .55 * factor : factor) / 2;
      final dir = Offset(math.cos(a), math.sin(a));
      outer.add(dir * (radius + w));
      inner.add(dir * (radius - w));
    }
    body = Path()..addPolygon([...outer, ...inner.reversed], true);
    head = Offset(0, -radius);

    // The tail's colours as a sweep around the ring: the head at the top (3π/2, clockwise from 3 o'clock), the tail
    // running back from it. Stops go from the tail's end to the head.
    final tints = <Color>[];
    final stops = <double>[];
    for (var k = _factors.length - 1; k >= 0; k--) {
      final f = k / (_factors.length - 1);
      final a = _opacities[k];
      // A small comet keeps to the bright end (head, magenta, purple): the deep blue of a long tail is lost on a dark
      // page at that size.
      final tint = solid ?? colors.palette[small ? _smallIdx[k] : _colorIdx[k]];
      final floor = small ? math.max(colors.tailFloor, .35) : colors.tailFloor;
      tints.add(tint.withValues(alpha: a + (1 - a) * floor));
      stops.add(1 - f);
    }
    shader = SweepGradient(
      startAngle: 3 * math.pi / 2 - 2 * math.pi * tail,
      endAngle: 3 * math.pi / 2,
      colors: tints,
      stops: stops,
    ).createShader(Rect.fromCircle(center: Offset.zero, radius: radius));
  }

  final double radius;

  /// The head's width; the tail thins out from it.
  final double width;

  /// How much of the ring the tail covers.
  final double tail;

  late final Path body;
  late final Offset head;
  late final Shader shader;

  /// The comet's points, head to tail end, for the turn into a check or a cross.
  List<Offset> samples(int n) => [
    for (var j = 0; j < n; j++)
      Offset(
        radius * math.cos(-math.pi / 2 - j / (n - 1) * 2 * math.pi * tail),
        radius * math.sin(-math.pi / 2 - j / (n - 1) * 2 * math.pi * tail),
      ),
  ];

  static double _lerpTable(List<double> table, double f) {
    final x = f * (table.length - 1);
    final lo = x.floor().clamp(0, table.length - 1);
    final hi = math.min(lo + 1, table.length - 1);
    return table[lo] + (table[hi] - table[lo]) * (x - lo);
  }
}

/// The comets for one size and look, shared by every spinner that has them (a list of rows all waiting builds them
/// once).
class _Comets {
  _Comets._(this.size, this.hero, this.comet);

  final double size;
  final bool hero;
  final _Comet comet;

  static final _cache = <(double, EnergyColors, Color?), _Comets>{};

  static _Comets of(double size, EnergyColors colors, Color? solid) {
    if (_cache.length > 48) _cache.clear();
    return _cache.putIfAbsent((size, colors, solid), () {
      final hero = size >= energyHeroSize;
      // Big: the ring a little inside the square, as the near side of a tilted orbit comes out by about a fifth.
      // Small: the ring just inside the square, as thick as the spinner it replaces.
      final width = hero ? (size * .04).clamp(1.8, 4.0).toDouble() : (size <= 12 ? 1.6 : (size * .13).clamp(2.0, 3.2).toDouble());
      final radius = hero ? size * .40 : size / 2 - width / 2 - .5;
      return _Comets._(
        size,
        hero,
        _Comet(radius: radius, width: width, tail: hero ? .64 : .40, colors: colors, solid: solid, small: !hero),
      );
    });
  }
}

class _Painter extends CustomPainter {
  _Painter({
    required this.clock,
    required this.comets,
    required this.colors,
    required this.solid,
    required this.outcome,
    required this.still,
  }) : super(repaint: clock);

  final _SpinClock clock;
  final _Comets comets;
  final EnergyColors colors;
  final Color? solid;
  final EnergyOutcome? outcome;
  final bool still;

  // The turn into a check or a cross, in seconds from the outcome: the spin slows to a stop as the orbits flatten,
  // the comets take the outcome's colour, then travel onto the symbol's two strokes, which pops once and sends out a
  // ripple.
  static const _settle = .25;
  static const _recolorFrom = .10, _recolorFor = .25;
  static const _travelFrom = .25, _travelFor = .30;
  static const _popFrom = .55, _popFor = .15;
  static const _rippleFrom = .55, _rippleFor = .40;
  static const outcomeEnd = _rippleFrom + _rippleFor;

  /// One turn of the small spinner, in seconds.
  static const _miniTurn = 1.1;

  /// One turn of each big orbit: a little faster and a little slower in turn, so they drift against each other.
  static const _heroTurns = [2.23, 2.37, 2.23, 2.37];

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    // Animations off: a still frame, or the finished symbol.
    final t = still ? .6 : clock.t;
    final at = outcome == null ? null : (still ? -outcomeEnd : clock.outcomeAt ?? t);
    final u = at == null ? null : t - at;
    // Fades in, so a wait that ends at once never flashes a spinner.
    final fade = still ? 1.0 : _smooth(t / .3);

    canvas.save();
    canvas.translate(s / 2, s / 2);
    if (u != null && u >= _travelFrom) {
      _paintSymbol(canvas, s, t: at!, u: u, fade: fade);
    } else {
      _paintSpin(canvas, s, t: at == null ? t : at + _spinAfter(u!), flat: u == null ? 0 : _easeInOut(u / _settle), recolor: u == null ? 0 : _smooth((u - _recolorFrom) / _recolorFor), fade: fade);
    }
    canvas.restore();
  }

  /// Where the spin has got to [u] seconds after the outcome: it keeps going, slowing smoothly to a stop over
  /// [_settle] (the integral of 1 − smoothstep).
  static double _spinAfter(double u) {
    final x = (u / _settle).clamp(0.0, 1.0);
    return _settle * (x - x * x * x + x * x * x * x / 2);
  }

  /// One comet's turn and depth at time [t]: the angle of its head, and how faded it is on the far side of its orbit.
  (double, double) _orbit(int i, double t) {
    if (!comets.hero) return (2 * math.pi * (t / _miniTurn + i / 2), 1.0);
    final p = (t / _heroTurns[i] + i * .25) % 1.0;
    final depth = p < .5
        ? .35 + .65 * Curves.fastOutSlowIn.transform(p * 2)
        : 1 - .65 * Curves.fastOutSlowIn.transform((p - .5) * 2);
    return (p * 2 * math.pi, depth);
  }

  int get _count => comets.hero ? 4 : 2;

  /// The comet [i]'s turn on the canvas: big ones on orbits tilted [tilt] radians and mirrored in turn, around the
  /// spinner's centre seen in perspective; small ones flat.
  Matrix4 _place(int i, double spin, double tilt, double s) {
    if (!comets.hero) return Matrix4.rotationZ(spin);
    return Matrix4.identity()
      ..setEntry(3, 2, -1 / (s * 2.4))
      ..rotateZ(i * math.pi / 4)
      ..rotateX(tilt)
      ..scaleByDouble(i.isOdd ? -1.0 : 1.0, 1.0, 1.0, 1.0)
      ..rotateZ(spin);
  }

  void _paintSpin(Canvas canvas, double s, {required double t, required double flat, required double recolor, required double fade}) {
    final comet = comets.comet;
    final tilt = 64 * (1 - flat) * math.pi / 180;
    final target = _outcomeColor;
    for (var i = 0; i < _count; i++) {
      final (spin, depth) = _orbit(i, t);
      // A flattened orbit has no far side.
      final alpha = fade * (depth + (1 - depth) * flat);
      canvas.save();
      canvas.transform(_place(i, spin, tilt, s).storage);
      if (comets.hero && solid == null && colors.halo.a > 0) {
        canvas.drawPath(
          comet.body,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = comet.width * 1.6
            ..strokeJoin = StrokeJoin.round
            ..color = colors.halo.withValues(alpha: colors.halo.a * alpha * (1 - recolor)),
        );
      }
      if (recolor < 1) _drawComet(canvas, comet, Paint()..shader = comet.shader..color = Color.fromRGBO(0, 0, 0, alpha * (1 - recolor)));
      if (recolor > 0 && target != null) {
        _drawComet(canvas, comet, Paint()..color = target.withValues(alpha: alpha * recolor));
      }
      canvas.restore();
    }
  }

  static void _drawComet(Canvas canvas, _Comet comet, Paint paint) {
    canvas.drawPath(comet.body, paint);
    canvas.drawCircle(comet.head, comet.width / 2, paint);
  }

  Color? get _outcomeColor => switch (outcome) {
    EnergyOutcome.success => solid ?? colors.success,
    EnergyOutcome.failure => solid ?? colors.failure,
    null => null,
  };

  /// The comets, flat and still where the spin stopped, travelling onto the symbol's strokes: two comets to a stroke on
  /// the big spinner, one on the small.
  void _paintSymbol(Canvas canvas, double s, {required double t, required double u, required double fade}) {
    final color = _outcomeColor!;
    final travel = _easeInOut((u - _travelFrom) / _travelFor);
    final symbol = comets.hero ? s * .065 : math.max(s * .11, comets.comet.width * 1.1);

    final ripple = (u - _rippleFrom) / _rippleFor;
    if (ripple > 0 && ripple < 1) {
      canvas.drawCircle(
        Offset.zero,
        s * (.30 + .17 * ripple),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, s * .012)
          ..color = color.withValues(alpha: (1 - ripple) * .38 * fade),
      );
    }
    final popT = ((u - _popFrom) / _popFor).clamp(0.0, 1.0);
    final pop = u >= _popFrom ? 1 + math.sin(popT * math.pi) * .045 : 1.0;
    canvas.scale(pop);

    // The check and the cross, on a 100-unit grid around the spinner's centre.
    Offset grid(double x, double y) => Offset((x - 50) / 100 * s * 1.2, (y - 50) / 100 * s * 1.2);
    final strokes = outcome == EnergyOutcome.success
        ? [(grid(33, 51.5), grid(45.5, 63.5)), (grid(45.5, 63.5), grid(68, 39))]
        : [(grid(37, 37), grid(63, 63)), (grid(63, 37), grid(37, 63))];

    const n = 16;
    final from = comets.comet.samples(n);
    final bulge = math.sin(travel * math.pi) * s * .045;
    final width = comets.comet.width * .6 + (symbol - comets.comet.width * .6) * travel;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = width
      ..color = color.withValues(alpha: fade * (.6 + .4 * travel));
    for (var i = 0; i < _count; i++) {
      final (spin, _) = _orbit(i, t + _spinAfter(_settle));
      final m = _place(i, spin, 0, s);
      final (a, b) = strokes[comets.hero ? i >> 1 : i];
      final path = Path();
      for (var j = 0; j < n; j++) {
        final start = MatrixUtils.transformPoint(m, from[j]);
        final p = Offset.lerp(start, Offset.lerp(a, b, j / (n - 1))!, travel)!;
        final d = p.distance;
        final q = d == 0 ? p : p + p / d * bulge;
        j == 0 ? path.moveTo(q.dx, q.dy) : path.lineTo(q.dx, q.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  static double _smooth(double x) {
    final v = x.clamp(0.0, 1.0);
    return v * v * (3 - 2 * v);
  }

  static double _easeInOut(double x) => Curves.easeInOut.transform(x.clamp(0.0, 1.0));

  @override
  bool shouldRepaint(_Painter old) =>
      old.comets != comets || old.colors != colors || old.solid != solid || old.outcome != outcome || old.still != still;
}
