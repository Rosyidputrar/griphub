import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A back gesture in progress (Android 14+ predictive back).
class BackGesture {
  BackGesture(this.route, this.edge);
  final ModalRoute<dynamic> route;
  final SwipeEdge edge;

  /// Set once the finger is released and Android decided to go back.
  bool committed = false;

  /// The route's animation value when it was committed; the exit animates from there to 0.
  double committedAt = 1;
}

/// Android 14+ predictive back: while the user swipes back from a screen edge, the top route follows the finger
/// (pages shrink to reveal the one underneath, sheets and menus slide or fade away); releasing goes back, swiping
/// back to the edge cancels. Routes that veto popping (PopScope) or handle it internally keep the plain back.
///
/// Registered both as a navigator observer (to know the top route) and a binding observer (for the gesture).
class PredictiveBack extends NavigatorObserver with WidgetsBindingObserver {
  PredictiveBack._();
  static final instance = PredictiveBack._();

  /// The gesture in progress, for transitions that draw it (SmoothPageTransitions).
  final gesture = ValueNotifier<BackGesture?>(null);

  Route<dynamic>? _top;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _top = route;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route == _top) _top = previousRoute;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route == _top) _top = previousRoute;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute == _top) _top = newRoute;
  }

  /// How far back the route's animation goes for gesture [progress] (0..1): all the way for pages, part of the way
  /// for sheets and dialogs, which would otherwise vanish long before the finger stops.
  static double _value(ModalRoute<dynamic> route, double progress) =>
      1 - progress.clamp(0.0, 1.0) * (route is PageRoute ? 1 : 0.35);

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    final route = _top;
    if (backEvent.isButtonEvent || gesture.value != null) return false;
    if (route is! ModalRoute || !route.isCurrent || route.navigator == null || !route.popGestureEnabled) return false;
    gesture.value = BackGesture(route, backEvent.swipeEdge);
    route.handleStartBackGesture(progress: _value(route, backEvent.progress));
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    final g = gesture.value;
    if (g == null || g.committed) return;
    g.route.handleUpdateBackGestureProgress(progress: _value(g.route, backEvent.progress));
  }

  @override
  void handleCommitBackGesture() {
    final g = gesture.value;
    if (g == null || g.committed) return;
    final route = g.route;
    final navigator = route.navigator;
    final animation = route.animation;
    if (navigator == null || animation == null || !route.isCurrent) {
      _end(g);
      return;
    }
    g
      ..committed = true
      ..committedAt = animation.value;
    // Rebuild transitions that draw the gesture: they switch to the exit.
    gesture.value = null;
    gesture.value = g;
    HapticFeedback.lightImpact();
    // Pop from where the finger left it (route.handleCommitBackGesture would restart the exit from the top).
    navigator.pop();
    _whenSettled(g, () => navigator.didStopUserGesture());
  }

  @override
  void handleCancelBackGesture() {
    final g = gesture.value;
    if (g == null || g.committed) return;
    if (g.route.isCurrent) g.route.handleCancelBackGesture();
    _whenSettled(g, () {});
  }

  /// Runs [done] and forgets the gesture once the route's animation stops.
  void _whenSettled(BackGesture g, VoidCallback done) {
    final animation = g.route.animation;
    if (animation == null || !animation.isAnimating) {
      done();
      _end(g);
      return;
    }
    late final AnimationStatusListener listener;
    listener = (status) {
      if (status.isAnimating) return;
      animation.removeStatusListener(listener);
      done();
      _end(g);
    };
    animation.addStatusListener(listener);
  }

  void _end(BackGesture g) {
    if (gesture.value == g) gesture.value = null;
  }
}

/// Page motion, after ArchiveTune (Metrolist): a pushed page slides in from the right across the whole width while it
/// fades in (250 ms), and the page it covers slides out to the left across the whole width while it fades out (200 ms);
/// going back is the mirror image, both pages sliding the whole width with no fade (200 ms), so a page always travels
/// off-screen instead of vanishing part-way. Every curve is fast-out-slow-in (Compose's tween default).
///
/// A page opened with [nested] settings (search results) is the exception underneath: covered, it moves only half the
/// width and fades, and comes back the same way, as results do under the page opened from them.
///
/// During a predictive back gesture the page instead shrinks toward the finger with rounded corners, revealing the page
/// underneath (which grows back to full size); when released, the page slides all the way off-screen from where the
/// finger left it.
class SmoothPageTransitions extends PageTransitionsBuilder {
  const SmoothPageTransitions();

  static final _runs = Expando<_Runs>('page motion runs');

  /// Route settings for a page whose page underneath motion is the half-width parallax (search results).
  static const nested = RouteSettings(name: 'nested');

  static const enterMs = 250;
  static const exitMs = 200;
  static const curve = Curves.fastOutSlowIn;

  @override
  Duration get transitionDuration => const Duration(milliseconds: enterMs);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: exitMs);

  /// Where a page is horizontally (as a share of the width) and how opaque, at the time of [route]'s two animations
  /// with no back gesture in progress. Public so the tests can lock the geometry.
  @visibleForTesting
  static ({double dx, double opacity}) place({
    required double value,
    required AnimationStatus status,
    required double under,
    required AnimationStatus underStatus,
    bool nested = false,
  }) {
    // Popping: slides off to the right across the whole width, with no fade.
    if (status == AnimationStatus.reverse) return (dx: curve.transform(1 - value), opacity: 1);
    var dx = 0.0;
    var opacity = 1.0;
    if (under > 0) {
      final reach = nested ? 0.5 : 1.0;
      if (underStatus == AnimationStatus.reverse) {
        // The page above goes back: this one comes back in from the left. Only the half-way (nested) page fades in, as
        // in ArchiveTune; a full-width one is already in view as it slides.
        final t = curve.transform(1 - under);
        dx = -reach * (1 - t);
        if (nested) opacity = t;
      } else {
        // A page is pushed on top: this one leaves to the left and fades, over 200 of the 250 ms.
        final t = curve.transform((under / (exitMs / enterMs)).clamp(0.0, 1.0));
        dx = -reach * t;
        opacity = 1 - t;
      }
    }
    // Coming in: from the right across the whole width, fading in.
    final e = curve.transform(value);
    dx += 1 - e;
    opacity *= e;
    return (dx: dx, opacity: opacity);
  }

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final gesture = PredictiveBack.instance.gesture;
    final nestedPage = route.settings.name == nested.name;
    final runs = _runs[route] ??= _Runs();
    return AnimatedBuilder(
      animation: Listenable.merge([animation, secondaryAnimation, gesture]),
      child: child,
      // One widget structure for every state, so switching between them never rebuilds the page.
      builder: (context, child) {
        final width = MediaQuery.sizeOf(context).width;
        final g = gesture.value;
        var dx = 0.0;
        var scale = 1.0;
        var radius = 0.0;
        var opacity = 1.0;
        // Darkens the page a back gesture reveals; cheaper than fading the whole page, and nothing shows through.
        var scrim = 0.0;
        var shadow = 0.0;
        if (g != null && g.route == route) {
          // This page follows the back gesture, lifted off the page it reveals.
          final dir = g.edge == SwipeEdge.left ? 1.0 : -1.0;
          final shift = math.max(0.0, width / 20 - 8);
          final drag = 1 - (g.committed ? g.committedAt : animation.value);
          scale = 1 - 0.1 * drag;
          radius = 28 * math.min(1.0, drag * 4);
          shadow = math.min(1.0, drag * 4);
          dx = dir * shift * drag;
          if (g.committed) {
            // Released: keep sliding all the way off-screen instead of fading in
            // place, relaxing the gesture shrink and corners as it goes.
            final c = g.committedAt <= 0 ? 1.0 : (1 - animation.value / g.committedAt).clamp(0.0, 1.0);
            final ce = Curves.easeOutCubic.transform(c);
            dx = dir * (shift * drag + (width - shift * drag) * ce);
            scale = 1 - 0.1 * drag * (1 - ce);
            radius = 28 * math.min(1.0, drag * 4) * (1 - ce);
            shadow = math.min(1.0, drag * 4) * (1 - ce);
            // opacity stays 1: the page leaves the screen instead of vanishing.
          }
        } else if (g != null && animation.status != AnimationStatus.reverse) {
          // Revealed by a back gesture: grows to full size as the page above
          // leaves (secondaryAnimation falls with the top page's animation),
          // brightening as the page above moves away.
          scrim = 0.12 * secondaryAnimation.value;
          scale = 0.92 + 0.08 * (1 - secondaryAnimation.value);
          final e = curve.transform(animation.value);
          dx = width * (1 - e);
          opacity = e;
        } else {
          final at = place(
            value: animation.value,
            status: runs.own.of(animation.status),
            under: secondaryAnimation.value,
            underStatus: runs.under.of(secondaryAnimation.status),
            nested: nestedPage,
          );
          dx = width * at.dx;
          opacity = at.opacity;
        }
        final dark = Theme.of(context).brightness == Brightness.dark;
        return Transform.translate(
          offset: Offset(dx, 0),
          child: Transform.scale(
            scale: scale,
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  boxShadow: shadow > 0
                      ? [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: (dark ? 0.5 : 0.22) * shadow),
                            blurRadius: 24,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(radius),
                  clipBehavior: radius > 0 ? Clip.antiAlias : Clip.none,
                  child: DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: BoxDecoration(color: scrim > 0 ? Colors.black.withValues(alpha: scrim) : null),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The direction each of a page's two animations started in. A run keeps its motion until it stops, as
/// CurvedAnimation keeps its curve: a page popped while it is still being pushed goes back the way it came, instead of
/// jumping to where the pop motion would have it.
class _Runs {
  final own = _Run();
  final under = _Run();
}

class _Run {
  AnimationStatus? _started;

  AnimationStatus of(AnimationStatus status) {
    if (!status.isAnimating) {
      _started = null;
      return status;
    }
    return _started ??= status;
  }
}
