import 'package:meta/meta.dart';

import '../geometry/detent.dart';
import '../geometry/detent_set.dart';
import '../geometry/units.dart';
import 'projection.dart';

/// Which detents a released fling is allowed to reach.
///
/// A closed set with no payload, so it is an enum rather than a sealed class:
/// there is nothing to carry and nothing to extend.
enum SnapPolicy {
  /// Every detent is reachable. The panel settles at the one nearest where the
  /// fling would have come to rest, so a hard fling crosses as many stops as its
  /// velocity pays for and a flick crosses one.
  ///
  /// The default, and the disagreement with the package this one is measured
  /// against: `stupid_simple_sheet-1.0.0-dev.2`'s `FlingSnapPhysics` — its
  /// shipped default — documents itself as *"Snapping points can never be
  /// overshot with a fling"* and then returns the next point in the fling's
  /// direction no matter how hard the throw was
  /// (`lib/src/snapping_point.dart:229` and `:253-270`). A three-detent sheet
  /// then needs three separate flings to open, which is not what any native
  /// scroll view does with the same gesture.
  projected,

  /// At most one stop from where the finger left, whatever the projection says.
  ///
  /// Here because "one gesture, one stop" is a legitimate choice for a panel
  /// whose detents mean discrete modes rather than sizes — a two-state drawer
  /// that should never blow past its middle. It is a *choice*, made at the call
  /// site and visible in the source, rather than the only behaviour available.
  stepwise,
}

/// Where a released panel is going, and what it is carrying there.
///
/// Produced by [snapTarget]. A value type rather than a bare [Detent] because
/// the settle needs three of these four numbers and reconstructing any of them
/// at the call site means a second copy of the arithmetic that decided them.
@immutable
final class SnapDecision {
  const SnapDecision._({
    required this.detent,
    required this.extent,
    required this.velocity,
    required this.landing,
  });

  /// The detent to settle at.
  final Detent detent;

  /// The height [detent] resolved to on the baseline the decision was made
  /// against.
  ///
  /// Carried rather than re-resolved, because a detent resolves against a
  /// baseline and the caller of a settle does not necessarily still have one.
  final Extent extent;

  /// The velocity to seed the settle with — **exactly** the velocity that was
  /// released, sign included.
  ///
  /// Verbatim even when it points away from [extent], which is the case this
  /// field exists to make impossible to get wrong. `smooth_sheets` substitutes
  /// zero there (`lib/src/physics.dart:114-118`, *"intentionally set to 0 …
  /// tends to cause unstable motion"*), so a panel flung upward that decides to
  /// settle downward starts its spring from rest at the moment the finger was
  /// moving fastest. The instability that comment describes is a spring tuned to
  /// tolerate being restarted; the fix is the tuning, not throwing away the one
  /// number that connects the animation to the gesture.
  final ExtentVelocity velocity;

  /// Where the fling would have stopped if no detent had caught it, in px on the
  /// extent axis.
  ///
  /// Kept for the caller that needs to know *how far past* the end a gesture
  /// reached — an overdrag that should rubber-band, a dismissal that should
  /// follow through. Freely outside `[min, max]` and freely negative, which is
  /// why it is a `double` and not an [Extent].
  final double landing;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SnapDecision &&
          other.detent == detent &&
          other.extent == extent &&
          other.velocity == velocity &&
          other.landing == landing;

  @override
  int get hashCode => Object.hash(detent, extent, velocity, landing);

  @override
  String toString() =>
      'SnapDecision($detent at ${extent.px}, velocity: '
      '${velocity.pxPerSecond}, landing: $landing)';
}

/// Chooses where a panel released at [from] with [velocity] should settle.
///
/// The whole decision is: project the fling, then take the nearest detent to the
/// projection. There is no fling-versus-drag threshold, because there does not
/// need to be one — a slow release projects a few pixels and the nearest detent
/// is the one it was already at, which is what a threshold would have decided
/// anyway, without a constant to tune or a discontinuity at it.
///
/// [policy] is the whole difference between the two behaviours, and it is one
/// thing: the window the projection is confined to before the nearest detent is
/// taken. The whole travel for [SnapPolicy.projected], the pair bracketing
/// [from] for [SnapPolicy.stepwise]. Two searches could disagree about a tie and
/// would be two behaviours; one search and two windows cannot.
SnapDecision snapTarget({
  required Extent from,
  required ExtentVelocity velocity,
  required ResolvedDetents detents,
  SnapPolicy policy = SnapPolicy.projected,
}) {
  final landing = projectLanding(from.px, velocity.pxPerSecond);
  final (Extent lower, Extent upper) = switch (policy) {
    SnapPolicy.projected => (detents.min, detents.max),
    // Each bound falls back to the end of the travel, which is also what handles
    // a release from beyond the ends: over-dragged above the top,
    // `neighbourAbove` is null and `neighbourBelow` is the top, so the window
    // collapses onto the top detent and the panel comes back to it.
    SnapPolicy.stepwise => (
      detents.neighbourBelow(from) ?? detents.min,
      detents.neighbourAbove(from) ?? detents.max,
    ),
  };

  // Clamping cannot change which detent is nearest — a landing past the end of
  // the travel is nearest that end either way — and it keeps the projection,
  // which is freely negative, from being handed on as an Extent.
  final reachable = Extent(landing.clamp(lower.px, upper.px));
  final detent = detents.nearestTo(reachable);
  return SnapDecision._(
    detent: detent,
    // Total: nearestTo answers with a detent out of the set's own snaps, so the
    // lookup that follows it cannot miss.
    extent: detents.extentOf(detent)!,
    velocity: velocity,
    landing: landing,
  );
}
