/// One fling across a panel and the list inside it: friction, then a spring,
/// C1-continuous at the seam.
///
/// Nothing in this file knows what a
/// `ScrollPosition` is; it is a `Simulation` over a `FusedAxis`, and the scroll
/// layer above it is what samples it and writes the two scalars.
library;

import '../geometry/detent.dart';
import '../geometry/units.dart';
import 'dart:math' as math;
import 'fused_axis.dart';
import 'momentum.dart';
import 'motion.dart';
import 'package:flutter/physics.dart';
import 'projection.dart';
import 'snap.dart';

/// A fling that starts as a scroll and ends as a panel motion, as one
/// simulation.
///
/// The shape, from DESIGN.md §3.3:
///
/// 1. Project the landing with `projectFusedLanding` — a `FrictionSimulation` at
///    `kDecelerationDrag`, the same constant and the same function the panel's
///    own release uses, so a fling cannot land in one place and snap to another.
/// 2. **Lands at or above the seam** → the whole thing is friction. A scroll
///    fling stays a scroll fling, and there is no detent above the seam to snap
///    to.
/// 3. **Lands below it** → the destination is the detent nearest the projection,
///    friction carries the fling to the seam, and a spring seeded with the
///    velocity **read at the seam** carries it the rest of the way. Continuity is
///    by construction rather than by comment: [seamVelocity] is the friction's
///    own derivative at [seamCrossing] and the spring's initial velocity is that
///    number, not a re-derived one.
///
/// A release that is already below the seam has a zero-length friction phase and
/// is all spring — the same code, no branch — which is what makes a drag of the
/// panel's own handle and a fling of a list at its top produce the same motion.
///
/// **A velocity pointing away from the destination is never zeroed.**
/// `smooth_sheets` substitutes zero there (`lib/src/physics.dart:114-118`,
/// *"intentionally set to 0 … tends to cause unstable motion"*), which discards
/// exactly the continuity this class is built for: a finger still travelling up
/// when the fling has decided to settle down is a real gesture, and the curve
/// reads as attached to the hand only if it carries.
///
/// **What "one simulation" is claimed to mean, exactly.** One object, one
/// `Tolerance`, one clock, sampled by one ticker, whose position is continuous
/// and whose derivative is continuous at the seam. It is not one *formula* —
/// friction and a spring are two — and a claim that it were would be false. The
/// falsifiable form is `fused_ballistic_test.dart`'s: one `Simulation`
/// constructed, one `Ticker` started, no discontinuity in `x` or `dx` at the
/// crossing.
final class FusedSimulation extends Simulation {
  /// A fling released at [from] on [axis], travelling at [velocity] fused px/s.
  ///
  /// [velocity] is on the **fused** axis: positive toward [FusedAxis.end], which
  /// is the direction the panel grows in and the content scrolls forward in.
  /// `PanelAnchor.fromScroll` is what produced it from the release the gesture
  /// recogniser reported, and it is the only thing that knew which screen
  /// direction that was.
  ///
  /// [snapPolicy] decides which detents the panel half may reach —
  /// `SnapPolicy.projected` lets a hard fling cross several stops,
  /// `SnapPolicy.stepwise` allows one — and it is the panel's own policy rather
  /// than a second one, so a fling that begins in the list and a fling that
  /// begins on the handle choose the same destination from the same projection.
  ///
  /// [carry] is what happens at the seam, and it is `[OPEN]`. See
  /// [MomentumCarry].
  FusedSimulation({
    required this.axis,
    required this.from,
    required this.velocity,
    required this.motion,
    this.snapPolicy = SnapPolicy.projected,
    this.carry = MomentumCarry.both,
    super.tolerance,
  });

  /// The coordinate this fling runs on.
  final FusedAxis axis;

  /// Where the release happened.
  final FusedPosition from;

  /// The release velocity, in fused px/s, positive toward [FusedAxis.end].
  final double velocity;

  /// The spring the panel half of the fling settles under.
  ///
  /// A `PanelMotion` and not a `SpringDescription`, for `motion.dart`'s reason:
  /// `SpringDescription` has no `==`, and a fling whose shape is configured per
  /// placement and per page needs its motion to be comparable.
  final PanelMotion motion;

  /// How far through [FusedAxis.detents] one fling may travel.
  final SnapPolicy snapPolicy;

  /// What happens to momentum at [FusedAxis.seam].
  final MomentumCarry carry;

  /// The deceleration the release is spending, from the release onward.
  ///
  /// Built with [kDecelerationDrag] and this simulation's own [tolerance], so
  /// the fling stops when the *panel's* display cannot show the difference
  /// rather than at `Tolerance.defaultTolerance`, which is calibrated for a 0..1
  /// route animation and would run a visible fling's tail for seconds after it
  /// had visibly stopped.
  late final FrictionSimulation _friction = FrictionSimulation(
    kDecelerationDrag,
    from.px,
    velocity,
    tolerance: tolerance,
  );

  /// Whether the release started in the content's half of the axis.
  ///
  /// `>=` rather than `>`: at exactly the seam the panel is at its largest and
  /// the content at its start, and which half that *is* is decided by where the
  /// fling goes, not by where it began. Both readings agree everywhere the
  /// answer matters, because a release exactly on the seam that goes nowhere has
  /// nothing to cross.
  bool get _startsAbove => from.px >= axis.seam.px;

  /// Whether friction alone would leave the fling in the content's half.
  ///
  /// **Both halves of DESIGN.md §3.3's rule.** The document says only "lands at
  /// or above the seam → the whole thing is friction", which is right exactly
  /// when there is content beyond the seam. With a short list the seam *is* the
  /// end of the axis, and friction past it carries the panel past its largest
  /// detent under deceleration instead of settling it there — a sheet that a
  /// hard fling opens to somewhere above `.full` and leaves there.
  bool get _frictionEndsAbove =>
      landing.px >= axis.seam.px && axis.scrollableDistance > 0;

  /// Whether [carry] forbids the crossing friction would otherwise have made.
  ///
  /// The whole of S7 in three rows. [MomentumCarry.both] forbids nothing;
  /// [MomentumCarry.none] forbids either crossing; [MomentumCarry.intoPanelOnly]
  /// forbids only the one that leaves the panel, which is the asymmetry
  /// flutter#116981 describes and this package keeps as a choice.
  late final bool _walled = switch (carry) {
    MomentumCarry.both => false,
    MomentumCarry.intoPanelOnly => !_startsAbove && _frictionEndsAbove,
    MomentumCarry.none => _startsAbove != _frictionEndsAbove,
  };

  /// Whether the panel is what this fling ends up moving.
  ///
  /// A walled fling is confined to the side it started on, so the wall decides
  /// this before the projection does — which is what makes a `none` release out
  /// of the panel settle at a detent instead of scrolling the list.
  late final bool _isPanelFling = _walled ? !_startsAbove : !_frictionEndsAbove;

  /// Where the panel half is going, decided once from [landing].
  ///
  /// `snapTarget` and not a second search: a fling that begins on the handle and
  /// a fling that begins in the list must choose the same destination from the
  /// same projection, and [snapPolicy]'s window is the only difference between
  /// them. The release is translated onto the extent axis by the smallest
  /// detent, which is the offset [FusedAxis.positionOf] took off — and
  /// `projectLanding` is `x0 + v/ln(drag)`, so the translation commutes with it
  /// exactly and the two landings cannot disagree.
  ///
  /// It is also what confines a walled release: `SnapPolicy.projected`'s window
  /// is `[detents.min, detents.max]`, and `detents.max` *is* the seam, so a
  /// fling that may not leave the panel lands at the largest detent with no
  /// clamping written for it.
  late final SnapDecision? _decision = _isPanelFling
      ? snapTarget(
          from: Extent(axis.detents.min.px + from.px),
          velocity: ExtentVelocity(velocity),
          detents: axis.detents,
          policy: snapPolicy,
        )
      : null;

  /// [seamCrossing] in seconds, or zero when the spring starts at the release.
  ///
  /// **The published crossing, not the exact one**, and the two differ by up to
  /// half a microsecond because [seamCrossing] is a `Duration`. Switching at the
  /// exact root and publishing the rounded one would put `x(seamCrossing)` up to
  /// 4e-4px off the seam — small, but it would make the one number this class
  /// exists to name disagree with the curve it names it on.
  late final double _springStart = seamCrossing == null
      ? 0.0
      : seamCrossing!.inMicroseconds / Duration.microsecondsPerSecond;

  /// The spring that carries the panel half, or null for a fling that stays in
  /// the content.
  ///
  /// Starts at the seam exactly when there is a crossing — not at the friction's
  /// own position at [_springStart], which is that half-microsecond of drift
  /// away — and is seeded with [seamVelocity], which is the friction's
  /// derivative at the same instant. That pairing is the C1 claim: the number
  /// the spring starts at has a name, and it is the number the friction ended
  /// at.
  late final Simulation? _spring = _decision == null
      ? null
      : motion.createSimulation(
          start: seamCrossing == null ? from.px : axis.seam.px,
          // Total: the detent came out of this axis' own set, so the lookup
          // that follows cannot miss.
          end: axis.positionOfDetent(_decision.detent)!.px,
          velocity: seamCrossing == null ? velocity : seamVelocity,
          tolerance: tolerance,
        );

  /// Where the fling would stop under friction alone, before any detent caught
  /// it.
  ///
  /// Freely outside `[0, axis.end]`: past the end it means the content wanted to
  /// overscroll, below zero it means the panel wanted to go under its smallest
  /// detent, and both are what the caller needs to decide a bounce or a
  /// dismissal. Clamping it here would be the arithmetic that decides the
  /// destination happening twice.
  FusedPosition get landing => FusedPosition(_friction.finalX);

  /// The detent this fling settles at, or null when it lands in the content's
  /// half and there is nothing to snap to.
  ///
  /// Decided once, at construction, from [landing] — not re-chosen per frame.
  /// A destination re-chosen per frame is how a fling chases a moving landing
  /// and arrives nowhere; re-choosing is `LayoutCorrection.resnap`'s job and it
  /// is bounded by `PanelConfig.resnapWindow`.
  Detent? get destination => _decision?.detent;

  /// When the fling crosses [FusedAxis.seam], or null if it never does.
  ///
  /// Null covers three cases and they are all the same case: a fling that stays
  /// in the content, a fling that stays in the panel, and a fling under
  /// [MomentumCarry.none], which is a wall at the seam and so has no crossing.
  late final Duration? seamCrossing = _computeSeamCrossing();

  /// [seamCrossing]'s body: the root of `friction(t) == seam`, when the fling is
  /// allowed to reach it.
  ///
  /// A wall is not a crossing. Under [MomentumCarry.none] the momentum is spent
  /// at the seam, so there is no instant at which the fling passed through it,
  /// and reporting one would make [seamVelocity] the speed of a motion that
  /// never happened.
  Duration? _computeSeamCrossing() {
    if (_walled || _startsAbove == _frictionEndsAbove) return null;
    final seconds = _friction.timeAtX(axis.seam.px);
    // `timeAtX` answers infinity for a seam the friction never reaches. It
    // cannot happen here — the two sides above already disagree, so the seam is
    // between the release and the landing — and it is guarded anyway, because
    // the alternative is a `Duration` of nine quintillion microseconds silently
    // becoming the moment the spring starts.
    return seconds.isFinite
        ? Duration(
            microseconds: (seconds * Duration.microsecondsPerSecond).round(),
          )
        : null;
  }

  /// The friction's derivative at [seamCrossing] — what the spring is seeded
  /// with.
  ///
  /// Zero when there is no crossing. This getter exists so the continuity claim
  /// is *readable* rather than only testable: the number the spring starts at
  /// has a name, and it is the number the friction ended at.
  double get seamVelocity =>
      seamCrossing == null ? 0.0 : _friction.dx(_springStart);

  /// The fused position at [time] seconds.
  @override
  double x(double time) => _confined(_rawX(time));

  /// The two phases, before the wall is applied.
  ///
  /// One expression covers all three shapes because [_springStart] is zero when
  /// there is nothing to cross: a release below the seam is all spring, a
  /// release that stays in the content has no spring at all, and the one that
  /// crosses is friction until the crossing and the spring after it. There is no
  /// branch here for "which kind of fling this is" — the fields already decided.
  double _rawX(double time) {
    final spring = _spring;
    if (spring == null) return _friction.x(time);
    return time < _springStart
        ? _friction.x(time)
        : spring.x(time - _springStart);
  }

  /// [_rawX]'s derivative, phase for phase.
  double _rawDx(double time) {
    final spring = _spring;
    if (spring == null) return _friction.dx(time);
    return time < _springStart
        ? _friction.dx(time)
        : spring.dx(time - _springStart);
  }

  /// [position] held on the side of the seam a walled fling started on.
  ///
  /// The clamp is what makes [MomentumCarry.none] a wall rather than a
  /// destination that usually behaves like one. Coming out of the panel,
  /// `snapTarget`'s window already lands the fling at the largest detent, which
  /// *is* the seam — but a critically damped spring seeded above `|r|·distance`
  /// px/s overshoots its destination, so the seam would leak by a few pixels on
  /// exactly the hardest releases. Coming into the panel there is no destination
  /// at all and the clamp is the whole of it.
  double _confined(double position) => !_walled
      ? position
      : _startsAbove
      ? math.max(position, axis.seam.px)
      : math.min(position, axis.seam.px);

  /// The fused velocity at [time] seconds.
  ///
  /// Continuous at [seamCrossing] to within a numeric-differentiation
  /// tolerance — that is the C1 claim, and `fused_ballistic_test.dart` asserts it
  /// against the one-sided limits rather than against the analytic pieces, so an
  /// implementation that got the seeding right by accident and the algebra wrong
  /// still fails.
  @override
  double dx(double time) => _isSpent(time) ? 0.0 : _rawDx(time);

  /// Whether the wall is what is holding the position at [time].
  ///
  /// A clamped position is a stationary one, and reporting the simulation's
  /// underlying speed while the wall holds it would hand a `Scrollbar` and every
  /// `UserScrollNotification` the velocity of a motion the user cannot see.
  bool _isSpent(double time) {
    if (!_walled) return false;
    final raw = _rawX(time);
    return _confined(raw) != raw;
  }

  /// Whether the fling has finished both halves.
  ///
  /// A friction-only fling is done when the friction is; a fling with a spring
  /// after it is done when the spring is, and never before — a friction that
  /// reports itself finished at the seam while a spring is still to run would
  /// stop the ticker with the panel between detents.
  @override
  bool isDone(double time) {
    final spring = _spring;
    // A fling with a spring after it is done when the spring is, and never
    // before. Asking the friction as well would report a fling finished at the
    // seam with 342px of settle still to run, which stops the ticker with the
    // panel between detents — visibly short, and parked there until something
    // else touches it.
    if (spring != null) {
      return time >= _springStart && spring.isDone(time - _springStart);
    }
    // Without one there are two ways to finish: the throw runs out, or the wall
    // takes what is left of it. The second is not optional — a walled fling
    // decelerating toward a seam it may not cross would otherwise keep the
    // ticker running for the seconds of tail that friction has left, writing the
    // same position every frame.
    return _friction.isDone(time) || _isSpent(time);
  }

  /// The extent and the scroll offset at [time] — [x] put back through
  /// [FusedAxis.split].
  ///
  /// The only method the scroll layer above calls per frame, and it exists so
  /// that the crossing from a fused coordinate to the two things that move
  /// happens in one place. `smooth_sheets` does that crossing inline with three
  /// bare `double`s in scope (`lib/src/scrollable.dart:294-329`).
  ({Extent extent, double scrollPixels}) sample(double time) =>
      axis.split(FusedPosition(x(time)));

  @override
  String toString() =>
      'FusedSimulation(from: ${from.px}, velocity: $velocity, destination: '
      '$destination, carry: ${carry.name})';
}
