import '../geometry/detent.dart';
import '../geometry/detent_set.dart';
import '../geometry/layout.dart';
import '../geometry/units.dart';

/// The shortest span of time that is still a motion.
///
/// `SpringDescription.withDurationAndBounce` measures its duration in **whole
/// milliseconds** and asserts it is above zero, so everything in `(0, 1ms)` is
/// a spring that cannot be built: in debug it throws — from inside a layout
/// pass, where a correction reaches it — and in release, with the assert
/// stripped, `durationInSeconds` truncates to 0.0, the stiffness becomes
/// `4π²/0²`, and the simulation writes `NaN` to the extent every frame while
/// never reporting itself done.
///
/// So the whole band below one millisecond means one thing, and it is not
/// "a very short spring": it is an arrival. Anywhere a duration reaches a
/// spring in this layer, that is what a remainder under this becomes.
const Duration kMinimumSettleDuration = Duration(milliseconds: 1);

/// Where [detent] sits on [detents], or the nearest surviving stop to [current]
/// when it sits nowhere.
///
/// The one answer to "the detent went inactive underneath the panel" —
/// `.medium` after a rotation into compact height, which iOS deactivates and
/// this package models as a null resolution. The panel moves the shortest
/// distance it can rather than collapsing to the smallest stop, and it moves
/// *without* the detent being rewritten, so turning the phone back restores the
/// height with nothing having had to remember it.
///
/// Written once and called from three places — [HoldDetent.resolve],
/// [SettleWithin.resolve] and `PanelModel._settle` — because a fallback spelled
/// out at each of them is three chances for one of them to collapse to
/// `ResolvedDetents.select`'s smallest instead, and the difference only shows up
/// as a panel that jumps to the wrong stop on one of three paths.
///
/// The `!` is total: `nearestTo` answers with a detent out of `snaps`, so the
/// lookup that follows is a lookup of something just found in the list being
/// looked in.
Extent heightOf(Detent detent, Extent current, ResolvedDetents detents) =>
    detents.extentOf(detent) ?? detents.extentOf(detents.nearestTo(current))!;

/// What a layout change does to a panel that is in the middle of something.
///
/// A panel is laid out twice per pass: once to find out how big it wants to be
/// and once to commit that. `smooth_sheets` answers those two questions with two
/// methods — `dryApplyNewLayout` and `applyNewLayout` — and then asserts at
/// runtime that they agreed (`lib/src/model.dart:345-361`), on exact `double`
/// equality, against a value fresh out of a spring. Here there is one function,
/// [resolve], and both passes call it. They cannot disagree, so the assert that
/// remains is a *purity* tripwire rather than a correctness check: it fires when
/// [resolve] stops being a function of its arguments, not when two
/// implementations drift.
///
/// **[resolve] answers where the panel is, not where it is going.** Two of the
/// four variants below always leave the extent exactly where they found it, and
/// are told apart only by what `PanelModel.applyLayout` does with them on
/// commit — re-projecting a fling, rebasing a gesture, doing nothing. That split
/// is deliberate: the handoff allocates activities and touches a clock, and a
/// function called twice per layout pass with an assert comparing its two
/// results must do neither. The sealed set is what makes the commit's `switch`
/// exhaustive; [resolve] is what makes the two passes agree.
///
/// **Everything the two passes must agree on lives on this side of the seam.**
/// The commit half may not move the extent, so every question whose answer is a
/// height — where a parked detent went, whether a settle has run out of time —
/// is answered here, by one expression, read twice.
///
/// One variant per activity policy, and the policies are the whole content of
/// the content-resize protocol:
///
/// | while the panel is | the correction | because |
/// |:--|:--|:--|
/// | dragged | [LayoutCorrection.freeze] | the thing under the finger must not jump |
/// | idle | [LayoutCorrection.hold] | a detent means a height, and the height changed |
/// | settling | [LayoutCorrection.settle] | the destination moved; the remaining time did not |
/// | ballistic | [LayoutCorrection.resnap] | the fling's landing moved, briefly |
sealed class LayoutCorrection {
  /// Allows the variants to be const.
  const LayoutCorrection();

  /// Leave the extent exactly where it is.
  const factory LayoutCorrection.freeze() = FreezeExtent;

  /// Re-resolve [target] against the new layout and go there.
  const factory LayoutCorrection.hold(Detent target) = HoldDetent;

  /// Continue toward [destination], re-resolved, in the time that is left.
  const factory LayoutCorrection.settle(
    Detent destination,
    Duration remaining,
  ) = SettleWithin;

  /// Re-choose the fling's landing at [velocity] against the new layout.
  const factory LayoutCorrection.resnap(ExtentVelocity velocity) =
      ResnapBallistic;

  /// The extent the panel takes for this layout pass.
  ///
  /// **Pure.** Called once to size and once to commit, with the same arguments,
  /// and asserted to answer the same both times. It must not notify, must not
  /// allocate an activity, must not read a clock and must not touch the model —
  /// everything it needs is in front of it.
  ///
  /// [current] is the extent before this pass, [detents] is [layout]'s detent
  /// set already resolved, and [layout] is here for the corrections that will
  /// need `viewInsets` when the keyboard policy lands. The result is a frame
  /// span and may legitimately sit outside `[detents.min, detents.max]` — an
  /// over-dragged panel and a spring returning from an overshoot are both real,
  /// and clamping either would be a visible yank rather than a correction.
  Extent resolve(PanelLayout layout, Extent current, ResolvedDetents detents);
}

/// Pin the pixels: whatever the panel measured before this pass, it measures
/// after it.
///
/// The keyboard opening under a finger is the case. The drag's accumulated
/// position *is* the extent, so there is no second, stale reference height to
/// desync from it — which is `stupid_simple_sheet`'s defect 7
/// (`lib/src/shrink_transition.dart:160-163`), where the transition keeps its
/// own copy of the height it started from.
///
/// Deliberately does **not** clamp into the new travel. A finger holding the
/// panel 90pt past its tallest detent is holding it there legitimately, through
/// the rubber band, and a clamp would pull it out from under the finger at the
/// exact moment the correction exists to stop that happening.
final class FreezeExtent extends LayoutCorrection {
  /// Prefer [LayoutCorrection.freeze].
  const FreezeExtent();

  /// [current], unchanged.
  @override
  Extent resolve(PanelLayout layout, Extent current, ResolvedDetents detents) =>
      current;

  @override
  bool operator ==(Object other) => other is FreezeExtent;

  @override
  int get hashCode => (FreezeExtent).hashCode;

  @override
  String toString() => 'LayoutCorrection.freeze()';
}

/// Re-resolve a parked detent and move to wherever it now is.
///
/// Rotation and a keyboard are both this: an idle panel is not at 469.68pt, it
/// is at `.medium`, and 469.68 was only what that meant on the last layout. The
/// move is instant and within the same layout pass, which is right — the frame
/// this commits in is the frame the geometry changed in, so nothing animates
/// into a viewport that no longer exists.
///
/// It is also where KB7 is avoided by doing nothing: the engine already springs
/// `viewInsets` frame by frame off the real `CASpringAnimation`, so a panel that
/// animated its own response to the keyboard would double-animate. This resolves
/// to the new height every frame the inset moves, which is the engine's curve
/// followed exactly.
final class HoldDetent extends LayoutCorrection {
  /// Prefer [LayoutCorrection.hold].
  const HoldDetent(this.target);

  /// The detent the panel is parked at.
  final Detent target;

  /// [target]'s height on the new layout, through [heightOf].
  ///
  /// When [target] resolved to nothing the answer is the surviving detent
  /// nearest [current], and that fallback is [heightOf]'s — the same one a
  /// settle and a programmatic `settleTo` take, written once. It is a choice and
  /// not a measurement: iOS's own fallback is documented for an unknown
  /// *selection* rather than for a detent that goes inactive underneath one, and
  /// the two are not the same event.
  ///
  /// The fallback moves the panel and **not** [target]. An idle panel that was
  /// parked at `.medium` when the phone was turned on its side is still parked
  /// at `.medium`, sitting at the nearest height that currently exists; turning
  /// it back restores 469.68 without anything having to remember it. Rewriting
  /// the target here would make a rotation a one-way trip.
  @override
  Extent resolve(PanelLayout layout, Extent current, ResolvedDetents detents) =>
      heightOf(target, current, detents);

  @override
  bool operator ==(Object other) =>
      other is HoldDetent && other.target == target;

  @override
  int get hashCode => Object.hash(HoldDetent, target);

  @override
  String toString() => 'LayoutCorrection.hold($target)';
}

/// Keep animating, to the re-resolved destination, in the time that is left.
///
/// Content growing under a running settle is the case: the target is moving, so
/// a naive fix — re-seed a fresh spring at every layout — restarts a 500ms
/// animation on every frame the content changes and the panel never arrives.
/// Carrying [remaining] is what makes the re-seed convergent, because no
/// re-seed is longer than the last.
///
/// [resolve] leaves the extent alone *while there is still a settle to run*.
/// The spring is mid-flight and the layout change moved its destination, not its
/// current position; moving the position too is a jump in the middle of an
/// animation, which reads as a dropped frame rather than as a correction. Once
/// [hasArrived] it is the other way round, and that is the whole of the
/// distinction.
final class SettleWithin extends LayoutCorrection {
  /// Prefer [LayoutCorrection.settle].
  const SettleWithin(this.destination, this.remaining);

  /// The detent the settle is heading for, re-resolved on commit.
  final Detent destination;

  /// How much of the settle's duration has not elapsed.
  ///
  /// Floored at [Duration.zero] by the activity that reads it, and anything
  /// under [kMinimumSettleDuration] is [hasArrived] rather than a very short
  /// spring.
  final Duration remaining;

  /// Whether the settle's time has run out, so this correction *finishes* it
  /// rather than continuing it.
  ///
  /// The whole sub-millisecond band and not only zero, for the reason
  /// [kMinimumSettleDuration] gives: below it there is no spring to build, in
  /// debug or in release.
  ///
  /// This is the knowledge that has to sit on the [resolve] side. The commit
  /// half of a correction may not move the extent — the sizing pass has already
  /// been believed and the child laid out against it — so a settle that runs out
  /// of time can only be finished by the half that *is* allowed to answer with a
  /// height. Deciding it here means both passes read the same answer out of the
  /// same expression and cannot disagree about whether the panel arrived.
  bool get hasArrived => remaining < kMinimumSettleDuration;

  /// [current] while the settle is running, and [destination]'s height once
  /// [hasArrived].
  ///
  /// A settle whose remaining time is spent is a settle that is over, and a
  /// panel whose settle is over is *at* its destination. Answering [current]
  /// there parks the panel at a detent it never moved to and leaves it there:
  /// the activity that would have carried it is replaced by an idle one in the
  /// same commit, and no later pass moves it, because from then on `hold`
  /// resolves the detent it is already claimed to be at.
  @override
  Extent resolve(PanelLayout layout, Extent current, ResolvedDetents detents) =>
      hasArrived ? heightOf(destination, current, detents) : current;

  @override
  bool operator ==(Object other) =>
      other is SettleWithin &&
      other.destination == destination &&
      other.remaining == remaining;

  @override
  int get hashCode => Object.hash(SettleWithin, destination, remaining);

  @override
  String toString() => 'LayoutCorrection.settle($destination, $remaining)';
}

/// Re-choose where the fling was going, from where it is and how fast.
///
/// A page whose content settles a frame or two after a fling started is the
/// case. The landing was projected against the old travel; the travel changed;
/// the projection is stale. Unlike [SettleWithin] there is no chosen
/// destination to carry — a ballistic's destination *is* the projection — so the
/// correction carries the velocity instead and the commit runs `snapTarget`
/// again.
///
/// Re-snapping is bounded in time by the activity that produces this, not by
/// this: an activity that re-snapped for the whole flight would chase a
/// destination that content changes kept moving, and the panel would never
/// commit to one. Past the window the ballistic answers
/// [LayoutCorrection.freeze] instead, which is the "and then stops re-snapping"
/// half of the policy.
///
/// [resolve] leaves the extent alone, for [SettleWithin]'s reason.
final class ResnapBallistic extends LayoutCorrection {
  /// Prefer [LayoutCorrection.resnap].
  const ResnapBallistic(this.velocity);

  /// How fast the panel is travelling right now, sign included.
  ///
  /// The live velocity rather than the released one, because the projection is
  /// being redone from where the panel actually is, and by then the simulation
  /// has already spent some of the throw. Seeding a re-projection with the
  /// original release would land it further out than the panel can still reach.
  final ExtentVelocity velocity;

  /// [current], unchanged.
  @override
  Extent resolve(PanelLayout layout, Extent current, ResolvedDetents detents) =>
      current;

  @override
  bool operator ==(Object other) =>
      other is ResnapBallistic && other.velocity == velocity;

  @override
  int get hashCode => Object.hash(ResnapBallistic, velocity);

  @override
  String toString() => 'LayoutCorrection.resnap(${velocity.pxPerSecond} px/s)';
}
