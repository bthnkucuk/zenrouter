import 'package:flutter/physics.dart';
import 'package:meta/meta.dart';

/// The settle duration every panel motion uses unless it says otherwise.
///
/// One number, deliberately. `motor-1.1.0` ships two defaults for what its own
/// documentation calls the standard iOS spring — `CupertinoMotion()` is 550 ms
/// (`lib/src/motion.dart:378`) while `CupertinoMotion.smooth()` is 500 ms
/// (`:423`) — so which one a panel got depended on which constructor the call
/// site happened to reach for. Here [PanelMotion.new] and [PanelMotion.smooth]
/// are the same spring, and `motion_test.dart` asserts it.
///
/// 500 ms is also `SpringDescription.withDurationAndBounce`'s own default
/// (`physics/spring_simulation.dart:70`), so nothing in the stack disagrees.
const Duration kPanelMotionDuration = Duration(milliseconds: 500);

/// The settle duration for [PanelMotion.interactive].
///
/// Short on purpose: this spring finishes a gesture the finger was already
/// making, so it has to arrive before the user reads it as a separate animation.
const Duration kPanelInteractiveDuration = Duration(milliseconds: 150);

/// A spring, described the way a designer describes one: how long it takes and
/// how far it overshoots.
///
/// Wraps `SpringDescription.withDurationAndBounce`, which the SDK documents as
/// producing the same result as SwiftUI's `spring(duration:bounce:)`. The value
/// of having a type here rather than a bare `SpringDescription` is that
/// (duration, bounce) survives round-tripping and reads at a call site, where
/// (mass, stiffness, damping) is three numbers nobody can picture — and a panel
/// that is configured per placement, per page and per route needs its motion to
/// be comparable, which `SpringDescription` is not: it has no `==`.
///
/// The four named constructors are `motor`'s Cupertino constants, which are in
/// turn SwiftUI's. Attribution: `motor` 1.1.0, MIT, Timo Bähr — the numbers
/// below are its `CupertinoMotion` presets, re-pinned here rather than depended
/// on, because a dependency that contributes four constants is four constants
/// and a transitive `equatable`.
@immutable
final class PanelMotion {
  /// A spring of [duration] with [bounce] overshoot.
  ///
  /// Identical to [PanelMotion.smooth] at its defaults. The duration is left to
  /// `SpringDescription.withDurationAndBounce` to validate, because Dart cannot
  /// evaluate `Duration.inMilliseconds` in a constant expression and this
  /// constructor is const so that `PanelPage(motion: const PanelMotion.snappy())`
  /// stays const.
  const PanelMotion({this.duration = kPanelMotionDuration, this.bounce = 0.0})
    : assert(
        bounce > -1 && bounce < 1,
        'A bounce of 1 is an undamped spring — a panel that oscillates forever '
        'and never reaches a detent. A bounce of -1 or lower is an infinite or '
        'negative damping ratio, which is not a motion at all.',
      );

  /// iOS's standard spring: it arrives and stops.
  ///
  /// The default for anything that resizes, because a detent is a destination
  /// rather than a gesture, and overshooting a height the content is laid out
  /// against shows the gap behind it.
  const PanelMotion.smooth({Duration duration = kPanelMotionDuration})
    : this(duration: duration);

  /// A trace of overshoot — SwiftUI `snappy`.
  const PanelMotion.snappy({Duration duration = kPanelMotionDuration})
    : this(duration: duration, bounce: 0.15);

  /// Visible overshoot — SwiftUI `bouncy`.
  const PanelMotion.bouncy({Duration duration = kPanelMotionDuration})
    : this(duration: duration, bounce: 0.3);

  /// The spring for motion a finger is still in the middle of.
  ///
  /// Short and barely bouncy, so that a correction applied mid-gesture — a
  /// detent set changing under a drag, a keyboard arriving — is over before it
  /// can be read as the panel taking over.
  const PanelMotion.interactive({Duration duration = kPanelInteractiveDuration})
    : this(duration: duration, bounce: 0.14);

  /// Roughly how long the spring takes to settle.
  ///
  /// Perceptual, not exact: for a bouncy spring it is closer to the oscillation
  /// period than to the time the motion stops. The SDK says the same thing about
  /// its own parameter, and this type does not pretend to more precision than
  /// the model underneath it has.
  final Duration duration;

  /// How far past its destination the spring goes, in `(-1, 1)`.
  ///
  /// Zero is critically damped — the fastest arrival with no overshoot. Positive
  /// overshoots and oscillates; negative is overdamped, arriving slowly as if
  /// through a fluid.
  final double bounce;

  /// The spring these two numbers describe.
  ///
  /// Derived on every read rather than stored, because storing it would cost the
  /// const constructor, and the const constructor is what lets a placement
  /// declare its motion at a const call site. The cost is one small allocation
  /// per settle, not per frame — a simulation is built once and then ticked.
  SpringDescription get spring => SpringDescription.withDurationAndBounce(
    duration: duration,
    bounce: bounce,
  );

  /// A simulation from [start] to [end], entering at [velocity].
  ///
  /// [velocity] is seeded into the spring exactly as given, **including when it
  /// points away from [end]**. A release that is still travelling upward when
  /// the panel has already decided to settle downward is a real thing a finger
  /// does, and the curve that comes out of it — carry on, slow, turn, come
  /// back — is what makes the panel feel attached to the hand. `smooth_sheets`
  /// zeroes that case (`lib/src/physics.dart:114-118`) and gets a spring that
  /// starts from rest at the exact moment the user was moving fastest;
  /// `motion_test.dart` asserts `dx(0)` here is the velocity that went in.
  ///
  /// [tolerance] decides when the simulation is done, and the default is only
  /// right for a 0..1 route animation. Over an extent in logical pixels the
  /// default settles about a thousand times tighter than the screen can show,
  /// so a caller animating pixels should pass a distance tolerance of half a
  /// physical pixel — the same threshold `Extent.isCloseTo` uses.
  Simulation createSimulation({
    required double start,
    required double end,
    double velocity = 0.0,
    Tolerance? tolerance,
  }) => SpringSimulation(
    spring,
    start,
    end,
    velocity,
    tolerance: tolerance ?? Tolerance.defaultTolerance,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PanelMotion &&
          other.duration == duration &&
          other.bounce == bounce;

  @override
  int get hashCode => Object.hash(duration, bounce);

  @override
  String toString() =>
      'PanelMotion(${duration.inMilliseconds}ms, bounce: $bounce)';
}
