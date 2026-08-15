/// The one coordinate a panel and the list inside it share, and the seam between
/// their two halves of it.
///
/// **Filed here rather than in `physics/`, and DESIGN.md §6 says `physics/`.**
/// This is pure maths over `geometry/` and it belongs beside `rubber_band.dart`
/// and `projection.dart`; it is in `scroll/` because `physics/` is committed and
/// this slice does not own it. The move is a `git mv` plus one import-test row,
/// and to keep it that cheap this file is on `imports_test.dart`'s widget-free
/// list — it may not reach a `BuildContext`, the same refusal `render_panel.dart`
/// carries, so nothing can quietly grow a dependency that would have to be
/// unpicked first.
library;

import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../geometry/detent.dart';
import '../geometry/detent_set.dart';
import '../geometry/units.dart';

/// The panel's travel and the content's scrollable distance laid end to end, so
/// a fling across both is one simulation over one number.
///
/// The axis runs from 0 — the panel at its smallest resting height with the
/// content at its start — through [seam], where the panel is at its largest and
/// the content is still at its start, to [end], where the content is at its own
/// end. **Increasing always means the same physical direction**, because the
/// panel's share is measured on the extent axis and the content's share is
/// converted into it by `PanelAnchor`, which is the only thing that knows a
/// bottom sheet grows when a finger rises.
///
/// The reason this type exists rather than two simulations handed off to each
/// other: a handoff has to *decide* what the second one starts at, and every
/// shipped implementation decides it with a fresh spring at rest.
/// `smooth_sheets` keeps three bare `double`s in the same method for the fused
/// position, the extent and the scroll offset (`lib/src/scrollable.dart:294-329`)
/// under a ten-line defensive comment citing "infinite recursion … issues #207
/// and #212". Here the fused coordinate is [FusedPosition], which nothing will
/// accept as an [Extent] or as a scroll offset, and [split] is the one crossing.
///
/// **Constructed from the detents and the scroll bounds, not from two spans.**
/// DESIGN.md §3.3 writes `FusedAxis({panelTravel, scrollableDistance, detents})`.
/// A `panelTravel` passed alongside the detents it is supposed to be the travel
/// *of* is a second copy of the arithmetic that produced it, and the two disagree
/// the first time a set resolves differently between the release and the
/// construction. It is the same argument `SnapDecision` makes for carrying the
/// height it chose.
@immutable
final class FusedAxis {
  /// Lays [detents]' travel end to end with the distance between [scrollMin] and
  /// [scrollMax].
  ///
  /// [scrollMin] and [scrollMax] are `ScrollPosition.minScrollExtent` and
  /// `maxScrollExtent` — the content's own bounds, taken at the moment of the
  /// release. A content shorter than its viewport has them equal, which makes
  /// [scrollableDistance] zero and the whole axis the panel's: a fling in a short
  /// list is a fling of the panel, with no branch written for it.
  const FusedAxis({
    required this.detents,
    required this.scrollMin,
    required this.scrollMax,
  });

  /// The heights the panel may rest at, resolved against the baseline the
  /// release was measured on.
  ///
  /// Carried whole rather than reduced to a travel because the snap at the end
  /// of a fling that lands below [seam] needs the individual stops, and
  /// re-resolving them from a baseline the caller may no longer have is the
  /// second copy this type refuses.
  final ResolvedDetents detents;

  /// `ScrollPosition.minScrollExtent` — where the content's own coordinate
  /// starts.
  final double scrollMin;

  /// `ScrollPosition.maxScrollExtent`.
  final double scrollMax;

  /// The panel's share of the axis: the distance between its smallest and
  /// largest resting heights.
  ///
  /// Zero for a single-detent panel, and that is the whole of S5 on this axis —
  /// the seam sits at the origin, every fling is a scroll, and no special case
  /// is written.
  Extent get panelTravel => detents.travel;

  /// The content's share: the distance it can be scrolled through.
  ///
  /// Saturated at zero, because a `ScrollPosition` reports `maxScrollExtent`
  /// below `minScrollExtent` for exactly one frame while a lazy viewport is
  /// still finding out how long it is, and a negative share would put [end]
  /// below [seam] and make [split] answer a scroll offset outside the content's
  /// own bounds.
  double get scrollableDistance => math.max(0.0, scrollMax - scrollMin);

  /// Where the panel stops and the content starts: the panel at its largest
  /// resting height, the content still at its start.
  ///
  /// The one number a fused fling is *about*. Everything below it is a panel
  /// motion and snaps to a detent; everything above it is a scroll and does not.
  FusedPosition get seam => FusedPosition(panelTravel.px);

  /// The far end of the axis: the panel at its largest, the content at its own
  /// end.
  FusedPosition get end => FusedPosition(panelTravel.px + scrollableDistance);

  /// The fused coordinate of a panel at [extent] with its content at
  /// [scrollPixels].
  ///
  /// The two are **added**, and the addition is invertible by [split] on exactly
  /// two families of states: the content on its rail (`scrollPixels == scrollMin`,
  /// so the second term is zero and the sum is below [seam]) and the panel on its
  /// rail (`extent == detents.max`, so the first term is the whole [panelTravel]
  /// and the sum is above it). The split rule keeps the pair in one of those two
  /// while a gesture is what is moving them, which is the whole reason this
  /// coordinate exists.
  ///
  /// **Every other state is still representable and is not recoverable**, and
  /// that is a property of the sum rather than a defect of this method: a panel
  /// below its largest detent over a list scrolled away from its top maps onto
  /// the same number as a fully open panel over a list scrolled less far, and
  /// [split] answers with the second. They are reachable —
  /// `PanelScrollPolicy.scrollsFirst` by construction, `resizesAlways` by gesture
  /// alone, a detent set swapped under a scrolled list, and any programmatic
  /// panel move over one — so the release has to *ask* rather than assume, and
  /// `PanelScrollLink.isOnFusedAxis` is that question. Adding is kept because it
  /// is the only extension that stays monotone in both arguments, which is what a
  /// simulation over this coordinate needs; being monotone is not being
  /// invertible, and the two used to be conflated here.
  ///
  /// Clamps neither argument. An overdragged panel maps above [seam] where the
  /// content would be, and an overscrolled list maps past [end]; both are
  /// information the release needs, and clamping them here would hide a fling
  /// launched from an overdrag.
  FusedPosition positionOf(Extent extent, double scrollPixels) =>
      // Both terms are measured from their own origin before they are added, so
      // the axis starts at zero rather than at whatever the smallest detent and
      // `minScrollExtent` happen to be. A sum of the raw values would still be
      // monotone and would still be continuous, and every landing projected on
      // it would be off by `min + scrollMin` — 214px of it on the MVP's set.
      FusedPosition((extent.px - detents.min.px) + (scrollPixels - scrollMin));

  /// [position] split back into the two things that move.
  ///
  /// The inverse of [positionOf] restricted to the rail: the panel takes the
  /// part below [seam] and the content takes the part above it, each clamped to
  /// its own share. A position below zero gives the smallest detent and the
  /// content's start; one past [end] gives the largest detent and the content's
  /// end. So a simulation that overshoots either end writes a valid extent and a
  /// valid offset, and the overshoot is expressed by the *simulation* being
  /// somewhere the axis is not, rather than by two consumers receiving numbers
  /// they cannot use.
  ({Extent extent, double scrollPixels}) split(FusedPosition position) {
    final travel = panelTravel.px;
    return (
      extent: Extent(detents.min.px + position.px.clamp(0.0, travel)),
      // The content's share is what is left *above the seam*, not what is left
      // of the position: subtracting before clamping is what keeps the panel at
      // its largest while the list moves. Clamping first and subtracting after
      // would hand the list the panel's travel as scroll offset, so a fling of
      // the panel alone would also scroll the list 598px.
      scrollPixels:
          scrollMin + (position.px - travel).clamp(0.0, scrollableDistance),
    );
  }

  /// Where [detent] sits on this axis, or null if it is not in [detents].
  ///
  /// Below [seam] by construction — every resting height is inside the travel —
  /// which is what makes "a fling that lands below the seam snaps to a detent"
  /// a statement about one coordinate rather than about two spaces.
  FusedPosition? positionOfDetent(Detent detent) {
    final extent = detents.extentOf(detent);
    // Null propagates rather than falling back. A fling whose destination went
    // inactive under it has lost its landing, and a substituted one is how a
    // panel arrives somewhere nobody chose — `LayoutCorrection.resnap` is what
    // re-decides that, and it needs to be told there is nothing here.
    return extent == null ? null : FusedPosition(extent.px - detents.min.px);
  }

  // **There is deliberately no `nearestDetentTo` here, and the absence is the
  // finding rather than an omission.** A `nearest detent to a fused position`
  // helper reads like the obvious companion to [positionOfDetent], and it had no
  // production caller: `FusedSimulation` chooses its destination through
  // `snapTarget`, which is the panel's own snap policy applied to a *projected*
  // landing, and then looks the answer up with [positionOfDetent]. A second
  // search over the same detents — no projection, no policy window — is a second
  // way to decide where a fling ends, and the day one of them acquires a
  // tie-break the other has not, a fling begun on the handle and a fling begun
  // in the list settle on different detents from the same release. That is the
  // duplication `SnapDecision` carries its chosen height to prevent, and it is
  // cheaper to delete than to keep in step.

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FusedAxis &&
          other.detents == detents &&
          other.scrollMin == scrollMin &&
          other.scrollMax == scrollMax;

  @override
  int get hashCode => Object.hash(detents, scrollMin, scrollMax);

  @override
  String toString() => 'FusedAxis($detents, scroll: [$scrollMin, $scrollMax])';
}
