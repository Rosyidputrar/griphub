import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'theme.dart';

/// Bottom sheet motion, after ArchiveTune's player sheet (Metrolist): springs that never bounce, a light fling, the
/// nearest resting place when let go slowly, and a list inside that scrolls to its top before the sheet follows the
/// finger down.
///
/// - Opening, and settling after a drag or a fling: a critically damped spring of stiffness 400 (Compose's
///   StiffnessMediumLow). Closing with Back, the scrim or a button: the softer 200 (StiffnessLow), as ArchiveTune's
///   collapseSoft on Back.
/// - Let go faster than [flingPhysicalPx] physical pixels a second (ArchiveTune compares the raw pointer velocity, in
///   pixels): up opens fully, down closes (or, from the expanded height, goes back to the first height). Slower: the
///   nearest resting place, split half-way between two.
class SheetMotion {
  const SheetMotion._();

  /// StiffnessMediumLow, critically damped (damping 2·√400).
  static const normal = SpringDescription(mass: 1, stiffness: 400, damping: 40);

  /// StiffnessLow, critically damped (damping 2·√200).
  static const soft = SpringDescription(mass: 1, stiffness: 200, damping: 28.284271247461902);

  static const double flingPhysicalPx = 250;

  /// [flingPhysicalPx] in logical pixels a second on this screen.
  static double flingThreshold(BuildContext context) => flingPhysicalPx / MediaQuery.devicePixelRatioOf(context);

  /// A spring from [from] to [to] that lands exactly on [to] (no sub-pixel remainder left on screen).
  static Simulation spring(SpringDescription d, double from, double to, double velocity, double tolerance) =>
      SpringSimulation(
        d,
        from,
        to,
        velocity,
        snapToEnd: true,
        tolerance: Tolerance(distance: tolerance, velocity: tolerance * 10),
      );

  /// ArchiveTune's crossfade between a sheet's folded and unfolded forms, for open progress [p] (0 folded, 1
  /// unfolded): the unfolded content comes in over the second quarter, the folded one leaves over the first.
  static double unfoldedAlpha(double p) => ((p - 0.25) * 4).clamp(0.0, 1.0);
  static double foldedAlpha(double p) => 1 - (p * 4).clamp(0.0, 1.0);
}

/// Shows [builder] in a bottom sheet with [SheetMotion]. The same choices as [showModalBottomSheet].
Future<T?> showSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool? showDragHandle,
  BoxConstraints? constraints,
}) {
  final navigator = Navigator.of(context);
  final l = MaterialLocalizations.of(context);
  final themed = Theme.of(context).bottomSheetTheme.shape;
  return navigator.push(
    SpringSheetRoute<T>(
      builder: builder,
      // The theme's top radius, or Material 3's 28 when the theme sets none; another kind of shape is kept as it is.
      corners: themed is RoundedRectangleBorder
          ? themed.borderRadius.resolve(Directionality.of(context)).topLeft.x
          : themed == null && Theme.of(context).useMaterial3
          ? 28
          : null,
      capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
      isScrollControlled: isScrollControlled,
      barrierLabel: l.scrimLabel,
      barrierOnTapHint: l.scrimOnTapHint(l.bottomSheetLabel),
      constraints: constraints,
      isDismissible: isDismissible,
      modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
      drag: enableDrag,
      dragHandle: showDragHandle,
      useSafeArea: useSafeArea,
      reduced: Motion.reduced(context),
    ),
  );
}

/// A modal bottom sheet whose motion is [SheetMotion]: Flutter's layout, theme and semantics, with springs for every
/// movement and the drag and fling rules of [SheetMotion] in place of Flutter's (700 px/s, half-way).
class SpringSheetRoute<T> extends ModalBottomSheetRoute<T> {
  SpringSheetRoute({
    required WidgetBuilder builder,
    super.capturedThemes,
    super.barrierLabel,
    super.barrierOnTapHint,
    super.constraints,
    super.modalBarrierColor,
    super.isDismissible,
    required super.isScrollControlled,
    super.useSafeArea,
    super.settings,
    required this.drag,
    this.dragHandle,
    this.reduced = false,
    double? corners,
  }) : _corners = corners, // ignore: prefer_initializing_formals
       super(
         builder: (context) => _SheetFrame(builder: builder),
         // The frame draws the handle and follows the finger; Flutter's own drag would apply its rules on top.
         enableDrag: false,
         showDragHandle: false,
         // Placement follows the route's value as it is: the springs are the curve.
         sheetAnimationStyle: AnimationStyle(
           curve: Curves.linear,
           reverseCurve: Curves.linear,
           duration: reduced ? Duration.zero : const Duration(milliseconds: 250),
           reverseDuration: reduced ? Duration.zero : const Duration(milliseconds: 200),
         ),
       );

  /// Whether the sheet follows the finger (Flutter's enableDrag).
  final bool drag;

  /// Flutter's showDragHandle: null takes the theme's, when [drag] is on.
  final bool? dragHandle;

  /// Animations are off: no springs, the sheet just appears and goes.
  final bool reduced;

  /// The theme's top corner radius, which a sheet pulled up to fill the screen folds away (ArchiveTune: 16 dp
  /// collapsed, square expanded), so it meets the top edge square. Null keeps the theme's shape as it is.
  final double? _corners;

  @override
  ShapeBorder? get shape => _corners == null ? null : _MorphingCorners(this, _corners);

  _SheetFrameState? _frame;

  /// The velocity (route value a second) and spring for the next close; a drag sets them, anything else closes softly.
  double _closeVelocity = 0;
  SpringDescription _closeSpring = SheetMotion.soft;

  /// The route's value when a back gesture started, so the gesture moves the sheet from where it rests.
  double _gestureFrom = 1;

  double get _tolerance {
    final h = _frame?._height ?? 0;
    return h > 0 ? 0.4 / h : 0.0005; // under half a pixel
  }

  // The scrim follows the sheet as it moves (ArchiveTune's background alpha = progress).
  @override
  Curve get barrierCurve => Curves.linear;

  @override
  Simulation? createSimulation({required bool forward}) {
    if (reduced) return null;
    final from = controller?.value ?? (forward ? 0.0 : 1.0);
    if (forward) return SheetMotion.spring(SheetMotion.normal, from, 1, 0, _tolerance);
    final sim = SheetMotion.spring(_closeSpring, from, 0, _closeVelocity, _tolerance);
    _closeVelocity = 0;
    _closeSpring = SheetMotion.soft;
    return sim;
  }

  /// Moves the sheet to [value] of its first height (the frame's drags), stopping whatever it was doing.
  void _place(double value) {
    final c = controller;
    if (c != null && c.value != value) c.value = value;
  }

  /// Springs the sheet back to its first height, from wherever a drag left it.
  void _settle({required double velocity, SpringDescription spring = SheetMotion.normal}) {
    final c = controller;
    if (c == null) return;
    if (reduced) {
      c.value = 1;
      return;
    }
    c.animateWith(SheetMotion.spring(spring, c.value, 1, velocity, _tolerance));
  }

  /// Closes from a drag, carrying its speed, unless something on the sheet refuses (PopScope): then it goes back up.
  Future<void> _dismissFromDrag(double velocity) async {
    final nav = navigator;
    if (nav == null || !isCurrent) return;
    if (popDisposition == RoutePopDisposition.doNotPop) {
      onPopInvokedWithResult(false, null);
      _settle(velocity: velocity);
      return;
    }
    _closeVelocity = velocity;
    _closeSpring = SheetMotion.normal;
    nav.pop();
  }

  // Back closes the top layer first: an expanded sheet goes back to its first height before Back closes it.
  @override
  RoutePopDisposition get popDisposition {
    final base = super.popDisposition;
    if (base == RoutePopDisposition.pop && (_frame?._expanded ?? false)) return RoutePopDisposition.doNotPop;
    return base;
  }

  @override
  void onPopInvokedWithResult(bool didPop, T? result) {
    super.onPopInvokedWithResult(didPop, result);
    if (!didPop && (_frame?._expanded ?? false)) _frame?._collapse(soft: true);
  }

  // A back gesture moves the sheet from where it rests, and a cancelled one springs back softly (Flutter's would
  // run the linear 250 ms forward).
  @override
  void handleStartBackGesture({double progress = 0.0}) {
    _gestureFrom = controller?.value ?? 1;
    super.handleStartBackGesture(progress: _gestureFrom * progress);
  }

  @override
  void handleUpdateBackGestureProgress({required double progress}) =>
      super.handleUpdateBackGestureProgress(progress: _gestureFrom * progress);

  @override
  void handleCancelBackGesture() {
    final c = controller;
    if (c == null || !isCurrent || reduced) {
      super.handleCancelBackGesture();
      return;
    }
    c.animateWith(SheetMotion.spring(SheetMotion.soft, c.value, _gestureFrom, 0, _tolerance)).whenCompleteOrCancel(() {
      navigator?.didStopUserGesture();
    });
  }
}

/// What the frame shares with the sheet's content: the scroll controller that hands the drag over, and the expanded
/// height when the content asked for one ([SheetExtent]).
class _SheetScope extends InheritedWidget {
  const _SheetScope({required this.frame, required super.child});
  final _SheetFrameState frame;

  @override
  bool updateShouldNotify(_SheetScope old) => old.frame != frame;
}

class _SheetFrame extends StatefulWidget {
  const _SheetFrame({required this.builder});
  final WidgetBuilder builder;

  @override
  State<_SheetFrame> createState() => _SheetFrameState();
}

/// Follows the finger and settles the sheet. One number places it: [_s], the pixels of sheet showing above the bottom,
/// from 0 (closed) through the first height [_low] (the route fully in) to the expanded height [_high] (with a
/// [SheetExtent]; otherwise the two are the same). Below [_low] the route's value moves the sheet; above it the extent
/// grows it.
class _SheetFrameState extends State<_SheetFrame> with SingleTickerProviderStateMixin {
  late final SpringSheetRoute<dynamic> route = ModalRoute.of(context)! as SpringSheetRoute<dynamic>;
  late final _scroll = _HandoffController(this);
  late final _motion = AnimationController.unbounded(vsync: this)..addListener(_onMotion);
  final _key = GlobalKey();

  /// 0 at the first height, 1 expanded; only moves with a [SheetExtent].
  final extent = ValueNotifier<double>(0);
  _SheetExtentState? _extentOwner;

  /// The sheet's measured height at its first height, and the room the content has to grow into.
  double _height = 0;
  double _room = 0;

  double get _low => _height;
  double get _high {
    final e = _extentOwner;
    if (e == null) return _low;
    return _low + (e.widget.max - e.widget.initial) * _room;
  }

  double get _s => (route.animation?.value ?? 1) * _low + extent.value * (_high - _low);
  bool get _expanded => _extentOwner != null && extent.value > 0.001;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    route._frame = this;
  }

  @override
  void dispose() {
    if (route._frame == this) route._frame = null;
    _motion.dispose();
    _scroll.dispose();
    extent.dispose();
    super.dispose();
  }

  void _measure() {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    // The sheet's height at its first height: with a SheetExtent, less what it has grown.
    final grown = extent.value * (_high - _low);
    _height = box.size.height - grown;
  }

  /// Whether a drag of [delta] (positive: the finger moves down) on a list belongs to the sheet: pulling down at
  /// the top of the list, or pushing up while the sheet is below its highest place.
  bool _takes(double delta, {required bool atTop}) {
    if (!route.drag || !route.isCurrent) return false;
    _measure();
    if (_low <= 0) return false;
    if (delta > 0) return atTop;
    return _s < _high - 0.5;
  }

  /// Moves the sheet by [delta] and returns what it could not take (for the list underneath).
  double _drag(double delta) {
    _motion.stop();
    _measure();
    if (_low <= 0) return delta;
    final before = _s;
    _set((before - delta).clamp(0.0, _high));
    return delta - (before - _s);
  }

  void _set(double s) {
    if (s <= _low || _high <= _low) {
      if (extent.value != 0) extent.value = 0;
      route._place(_low > 0 ? (s / _low).clamp(0.0, 1.0) : 1);
    } else {
      route._place(1);
      extent.value = ((s - _low) / (_high - _low)).clamp(0.0, 1.0);
    }
  }

  /// Let go with [down] pixels a second (positive: moving down): ArchiveTune's performFling.
  void _release(double down) {
    _measure();
    if (_low <= 0) return;
    final up = -down;
    final s = _s;
    final threshold = SheetMotion.flingThreshold(context);
    if (up > threshold) {
      _to(_high, up);
    } else if (up < -threshold) {
      // Down: from below the first height it closes; from above, back to the first height.
      s < _low - 0.5 ? _dismiss(up) : _to(_low, up);
    } else if (s < _low / 2) {
      _dismiss(up);
    } else if (_high > _low && s >= (_low + _high) / 2) {
      _to(_high, up);
    } else {
      _to(_low, up);
    }
  }

  void _dismiss(double up) => route._dismissFromDrag(_low > 0 ? up / _low : 0);

  void _collapse({bool soft = false}) => _to(_low, 0, spring: soft ? SheetMotion.soft : SheetMotion.normal);

  /// Springs the sheet to [target] pixels showing, starting at [up] pixels a second.
  void _to(double target, double up, {SpringDescription spring = SheetMotion.normal}) {
    final s = _s;
    if (route.reduced || (s - target).abs() < 0.5) {
      _set(target);
      return;
    }
    if (s < _low && target == _low) {
      // Only the route moves: its own spring keeps the scrim and the route's state in step.
      route._settle(velocity: up / _low, spring: spring);
      return;
    }
    _motion.value = s;
    _motion.animateWith(SheetMotion.spring(spring, s, target, up, 0.4));
  }

  void _onMotion() => _set(_motion.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).bottomSheetTheme;
    final handle = route.dragHandle ?? (route.drag && (theme.showDragHandle ?? false));
    Widget child = PrimaryScrollController(controller: _scroll, child: Builder(builder: widget.builder));
    if (handle) {
      // As Flutter's: a 48 dp target with the pill in its middle, and the content below it.
      final size = theme.dragHandleSize ?? const Size(32, 4);
      child = Stack(
        alignment: Alignment.topCenter,
        children: [
          Semantics(
            label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
            container: true,
            button: true,
            onTap: () => Navigator.maybePop(context),
            child: SizedBox(
              width: math.max(size.width, kMinInteractiveDimension),
              height: math.max(size.height, kMinInteractiveDimension),
              child: Center(
                child: Container(
                  height: size.height,
                  width: size.width,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(size.height / 2),
                    color: theme.dragHandleColor ?? Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          Padding(padding: const EdgeInsets.only(top: kMinInteractiveDimension), child: child),
        ],
      );
    }
    child = KeyedSubtree(key: _key, child: _SheetScope(frame: this, child: child));
    if (!route.drag) return child;
    // The pointer's own speed at release, however short the flick (ArchiveTune reads its VelocityTracker as it is;
    // Flutter's recognizer reports no speed under its fling distance and speed), so a light flick is a fling.
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        VerticalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
          () => VerticalDragGestureRecognizer(debugOwner: this),
          (r) => r
            ..minFlingDistance = 0
            ..minFlingVelocity = 0
            ..onStart = ((_) => _motion.stop())
            ..onUpdate = ((d) => _drag(d.primaryDelta ?? 0))
            ..onEnd = ((d) => _release(d.velocity.pixelsPerSecond.dy))
            ..onCancel = (() => _release(0)),
        ),
      },
      child: child,
    );
  }
}

/// A sheet that opens at [initial] of the room and can be pulled up to [max] (in place of a DraggableScrollableSheet):
/// the list given to [builder] scrolls only once the sheet is all the way up, and pulled down at its top it brings
/// the sheet down, then closes it.
class SheetExtent extends StatefulWidget {
  const SheetExtent({super.key, required this.initial, this.max = 1, required this.builder})
    : assert(initial > 0 && initial <= max && max <= 1);
  final double initial;
  final double max;
  final Widget Function(BuildContext context, ScrollController scroll) builder;

  @override
  State<SheetExtent> createState() => _SheetExtentState();
}

class _SheetExtentState extends State<SheetExtent> {
  _SheetFrameState? _frame;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final frame = context.getInheritedWidgetOfExactType<_SheetScope>()?.frame;
    if (frame != _frame) {
      if (_frame?._extentOwner == this) _frame!._extentOwner = null;
      frame?._extentOwner = this;
      _frame = frame;
    }
  }

  @override
  void dispose() {
    if (_frame?._extentOwner == this) _frame!._extentOwner = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    return LayoutBuilder(
      builder: (context, box) {
        final room = box.maxHeight.isFinite ? box.maxHeight : MediaQuery.sizeOf(context).height;
        if (frame != null) frame._room = room;
        final scroll = frame?._scroll ?? PrimaryScrollController.of(context);
        final body = widget.builder(context, scroll);
        if (frame == null) return SizedBox(height: widget.initial * room, child: body);
        return ValueListenableBuilder<double>(
          valueListenable: frame.extent,
          child: body,
          builder: (context, e, body) =>
              SizedBox(height: (widget.initial + (widget.max - widget.initial) * e) * room, child: body),
        );
      },
    );
  }
}

/// The scroll controller of a sheet's list: hands the finger to the sheet while the list is at its top and the
/// finger goes down, or while the sheet is below its highest place and the finger goes up, as ArchiveTune's
/// preUpPostDownNestedScrollConnection.
class _HandoffController extends ScrollController {
  _HandoffController(this.frame);
  final _SheetFrameState frame;

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _HandoffPosition(physics: physics, context: context, oldPosition: oldPosition, frame: frame);
}

class _HandoffPosition extends ScrollPositionWithSingleContext {
  _HandoffPosition({required super.physics, required super.context, super.oldPosition, required this.frame});
  final _SheetFrameState frame;

  /// This drag moved the sheet: its release settles the sheet, not the list.
  bool _moved = false;

  @override
  void applyUserOffset(double delta) {
    if (frame._takes(delta, atTop: pixels <= minScrollExtent)) {
      _moved = true;
      final rest = frame._drag(delta);
      if (rest != 0) super.applyUserOffset(rest);
      return;
    }
    super.applyUserOffset(delta);
  }

  @override
  void goBallistic(double velocity) {
    if (_moved) {
      _moved = false;
      // velocity > 0 flings the list toward its end: the finger went up.
      frame._release(-velocity);
      super.goBallistic(0);
      return;
    }
    super.goBallistic(velocity);
  }
}

/// Top corners of [radius] while the sheet is at its first height, square once it fills the room. Read as the sheet
/// is laid out: expanding changes its height every frame, which redraws the clip.
class _MorphingCorners extends RoundedRectangleBorder {
  _MorphingCorners(this.route, this.radius)
    : super(borderRadius: BorderRadius.vertical(top: Radius.circular(radius * _scale(route))));
  final SpringSheetRoute<dynamic> route;
  final double radius;

  static double _scale(SpringSheetRoute<dynamic> route) {
    final frame = route._frame;
    final owner = frame?._extentOwner;
    if (frame == null || owner == null || owner.widget.max < 1) return 1;
    return 1 - frame.extent.value;
  }

  BorderRadius get _now => BorderRadius.vertical(top: Radius.circular(radius * _scale(route)));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => Path()..addRRect(_now.toRRect(rect));

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) => getOuterPath(rect, textDirection: textDirection);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  // One shape for the route's life: Material would otherwise animate between "different" shapes.
  @override
  bool operator ==(Object other) => other is _MorphingCorners && other.route == route;

  @override
  int get hashCode => route.hashCode;
}
