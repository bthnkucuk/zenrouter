/// The arbiter: the one object that decides who gets a delta, where a fling
/// lands, and which scrollables have quietly escaped capture.
///
/// Flutter's gesture arena cannot express partial consumption — a recogniser
/// wins a pointer or it does not — which is why this package owns the
/// `ScrollPosition` rather than observing it. The arena question was already
/// answered by the time a delta reaches here; what is left is arithmetic, and
/// this is where it lives.
///
/// **Everything about the split is a pure function of a `PanelScrollDriver` and
/// the model.** [PanelScrollLink.split] and everything under it take the model's
/// three-getter view of a scrollable, never a `ScrollPosition`, so the whole
/// arbitration matrix in `split_test.dart` runs as plain `test`s with no binding,
/// no `pumpWidget` and no gesture — the same way the geometry, physics and model
/// layers are tested. The two members that are not pure — the position registry
/// and [PanelScrollLink.degradedSplit] — are here because DESIGN.md §6 says the
/// arbiter holds the registry, and they are the only reason this file imports a
/// binding at all.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../geometry/anchor.dart';
import '../geometry/detent_set.dart';
import '../geometry/units.dart';
import '../model/activity.dart';
import '../model/panel_model.dart';
import '../physics/fused_axis.dart';
import '../physics/fused_simulation.dart';
import 'policy.dart';
import 'position.dart';
import '../physics/momentum.dart';

/// Decides how a drag on a scrollable inside the panel divides between the two,
/// and where the release lands.
///
/// One link per panel, created and disposed by the widget that installs the
/// panel's `PrimaryScrollController`. It outlives every `ScrollPosition` under
/// it — several lists may attach at once, and Flutter replaces a position
/// outright on a physics or controller `runtimeType` change
/// (`scrollable.dart:686-698`) — which is why the positions are registered here
/// rather than the link being reachable only through one of them.
final class PanelScrollLink {
  /// Arbitrates for [model] under [anchor].
  ///
  /// The three policies default to the pair that ships: iOS's split rule, and
  /// the refresh reading that makes an unmodified `RefreshIndicator` work at the
  /// largest detent. Every one of them is an A5 policy with both ends tested —
  /// see `policy.dart`.
  PanelScrollLink({
    required this.model,
    this.anchor = PanelAnchor.bottom,
    this.scrollPolicy = PanelScrollPolicy.resizesFromEdge,
    this.refreshPolicy = PanelRefreshPolicy.whenFullyOpen,
    this.momentumCarry = MomentumCarry.both,
  });

  /// The panel this link moves.
  ///
  /// Held rather than passed per call because the link is what a
  /// `PanelScrollPosition` holds, and a position that had to be handed a model
  /// on every delta would be a position that could be handed a different one.
  final PanelModel model;

  /// Where the panel is attached, and therefore which finger direction grows it.
  ///
  /// Mutable, because the widget above rebuilds with a placement that can
  /// change — a drawer becoming a sheet on a wider window — and a link recreated
  /// for that would drop the registry and every position's binding with it.
  PanelAnchor anchor;

  /// Who gets a delta. See [PanelScrollPolicy].
  PanelScrollPolicy scrollPolicy;

  /// Who gets a downward drag from the content's own start. See
  /// [PanelRefreshPolicy].
  PanelRefreshPolicy refreshPolicy;

  /// What a fling does at the seam. See [MomentumCarry].
  MomentumCarry momentumCarry;

  /// The reading direction the last committed layout was measured in.
  ///
  /// Read off the model rather than from a `BuildContext`, because the split
  /// runs from a gesture callback where there is no build to depend on, and
  /// because the layout the panel was last laid out at is the one its extent
  /// means something in.
  TextDirection get textDirection => model.layout.textDirection;

  /// The heights the panel may currently rest at.
  ResolvedDetents get detents => model.detents;

  /// How big the panel is right now.
  Extent get extent => model.extent;

  // ==========================================================================
  // Sign, converted in exactly two places.
  //
  // `PanelAnchor` is the only file in the package that knows a screen
  // direction. These two are the only calls into it from the scroll layer, and
  // they are named after the two quantities rather than after the direction, so
  // that a call site cannot be read as "the obvious way round".
  // ==========================================================================

  /// The extent-axis delta a **scroll-space** delta of [scrollDelta] implies.
  ///
  /// Scroll space is `ScrollVelocity`'s convention: positive when
  /// `ScrollPosition.pixels` rises. `ScrollPosition.pointerScroll` is measured
  /// this way (`scroll_position_with_single_context.dart:219-222` adds its delta
  /// to `pixels`), and so is the velocity handed to `goBallistic`.
  double extentDeltaOfScroll(double scrollDelta) =>
      anchor.extentDeltaFromScrollDelta(scrollDelta, textDirection);

  /// The extent-axis delta a **drag** delta of [dragDelta] implies.
  ///
  /// Drag space is `ScrollPosition.applyUserOffset`'s convention, and it is the
  /// **negation** of scroll space: `:131` is `setPixels(pixels - offset)`, so a
  /// positive drag delta lowers `pixels`. The delta arriving there has already
  /// been reversed for `axisDirectionIsReversed` by `ScrollDragController`
  /// (`scroll_activity.dart:321`), which is why a right-to-left horizontal list
  /// needs no case here.
  ///
  /// Two entry points into the same position measuring the same physical motion
  /// with opposite signs is not a thing to remember; it is a thing to name
  /// twice. `split_test.dart` asserts these two are negatives of each other, so
  /// the day one of them is used where the other belongs, the panel moving the
  /// wrong way is a failing test rather than a bug report about "the sheet
  /// closes when I scroll up".
  double extentDeltaOfDrag(double dragDelta) => extentDeltaOfScroll(-dragDelta);

  /// The drag delta that would produce an extent-axis delta of [extentDelta] —
  /// [extentDeltaOfDrag] run backwards.
  ///
  /// It is the same multiplication because every anchor's scroll sign is exactly
  /// ±1, so the conversion is its own inverse. That is a *fact about the current
  /// anchors*, not a law, and `split_test.dart` asserts the round trip across all
  /// five anchors and both reading directions — because the day an anchor needs
  /// a scale factor, this is the call site that keeps silently working.
  double dragDeltaOfExtent(double extentDelta) =>
      -extentDeltaOfScroll(extentDelta);

  /// The scroll-space delta that would produce an extent-axis delta of
  /// [extentDelta] — [extentDeltaOfScroll] run backwards, and the sign
  /// [dragDeltaOfExtent] is not.
  double scrollDeltaOfExtent(double extentDelta) =>
      extentDeltaOfScroll(extentDelta);

  // ==========================================================================
  // The split.
  // ==========================================================================

  /// Whether the panel is standing **on** its largest resting height, to half a
  /// physical pixel.
  ///
  /// The tolerance is the point. `extent >= detents.max` is exact, and a spring
  /// approaches its destination asymptotically — a settle that stopped a tenth
  /// of a pixel short leaves a panel the user has finished opening reporting
  /// itself not fully open, and under [PanelRefreshPolicy.whenFullyOpen] that is
  /// a `RefreshIndicator` that silently does not fire. `Extent.isCloseTo`
  /// compares at half a pixel of *this* display, which is the finest difference
  /// the panel could show.
  ///
  /// The asymmetry with [contentIsAtStart] is deliberate and worth stating: a
  /// scroll position needs no tolerance, because `applyBoundaryConditions` pins
  /// it exactly at its edge, while an extent is the output of a spring and never
  /// arrives exactly.
  ///
  /// **Standing on it, and not "as open as it gets".** A panel rubber-banded 90pt
  /// past `.full` is the second and not the first, and both callers want the
  /// first: the refresh veto, because a panel held above its ceiling has
  /// somewhere for a downward drag to go and that is not a refresh; and
  /// [isOnFusedAxis], because "the panel's term is its whole travel" is what
  /// makes the fused sum invertible and an overdrag is exactly the term that is
  /// larger than the travel. There used to be a wider `isFullyOpen` alongside
  /// this for the reading an app would ask, and it had no caller anywhere — a
  /// second predicate over the same quantity that only tests read, which is how
  /// the two come to disagree.
  bool get isAtCeiling => _isAtCeiling(extent);

  /// [isAtCeiling], asked about a height the panel has not reached yet.
  ///
  /// The question the split re-asks in the state the leader would leave, so a
  /// panel that reaches its largest detent inside one delta hands the rest of
  /// that delta on in the same frame rather than on the next.
  bool _isAtCeiling(Extent at) => at.isCloseTo(
    detents.max,
    devicePixelRatio: model.layout.devicePixelRatio,
  );

  /// Whether [position] is at or before its own start — the SDK header's
  /// "scrolled to top".
  ///
  /// `pixels <= minScrollExtent`, exactly, and the `<=` is what makes an
  /// overscrolling list count as being at its start: a list already bouncing off
  /// its top is not somewhere the panel should refuse to take over from.
  bool contentIsAtStart(PanelScrollDriver position) =>
      position.pixels <= position.minScrollExtent;

  /// Whether the panel is entitled to a delta of [extentDelta] in the state
  /// [position] describes.
  ///
  /// The policy table, and nothing else — no clamping, no rooms, no refresh.
  /// DESIGN.md §3.2 writes it as `_panelMayTake(ExtentVelocity, ...)`; the
  /// parameter is a **delta**, not a velocity, and typing a per-frame
  /// displacement as `ExtentVelocity` to reach `.isGrowing` is exactly the
  /// confusion the unit vocabulary exists to refuse.
  ///
  /// | policy | growing | shrinking |
  /// |:--|:--|:--|
  /// | `scrollsFirst` | never | never |
  /// | `resizesAlways` | a larger detent exists | always |
  /// | `resizesFromEdge` | a larger detent exists **and** the content is at its start | the content is at its start |
  ///
  /// [PanelRefreshPolicy] is a fourth row on the shrinking column and it is
  /// applied here, not in [split]. It reads as a separate rule — the platform's
  /// table is one thing and A6.5's arbitration is ours — but a caller asking
  /// "may the panel take this" and getting the answer *without* the refresh
  /// veto would get an answer nothing in the package acts on. `split_test.dart`
  /// keeps the two apart by passing [PanelRefreshPolicy.never] on every row that
  /// is about the header, which is the same separation without a second
  /// predicate to keep in step.
  bool panelMayTake(double extentDelta, PanelScrollDriver position) =>
      _panelMayTake(
        extentDelta,
        at: extent,
        atStart: contentIsAtStart(position),
      );

  /// [panelMayTake], asked about a state the panel and the content are not in
  /// yet.
  ///
  /// The re-ask that makes the whole split one rule: after the leader has taken
  /// its room, the same question is put again with whichever of the two moved
  /// substituted. Both parameters are needed because either side can be the
  /// leader — the panel moves [at], the content moves [atStart] — and a re-ask
  /// that could only move one of them would answer the previous frame's question
  /// on one of the two branches.
  bool _panelMayTake(
    double extentDelta, {
    required Extent at,
    required bool atStart,
  }) =>
      _panelIsPreferred(extentDelta, at: at, atStart: atStart) &&
      // The growing column's other half, and it is the panel's *room* wearing
      // the SDK header's words: `neighbourAbove(at) == null` is true at exactly
      // the heights where `detents.max - at` is zero, because `neighbourAbove`
      // is strictly greater. Kept as the neighbour rather than as the
      // subtraction so the table above reads the way the header does.
      (extentDelta <= 0 || detents.neighbourAbove(at) != null);

  /// Which of the two this panel's policies would rather move, before either
  /// one's room is looked at.
  ///
  /// [_panelMayTake] is this and the panel's room; separating them is what makes
  /// the overdrag case in [split] expressible. When neither side can absorb a
  /// delta there is no room to arbitrate with, and the question left is the one
  /// this answers: who *would* have taken it.
  ///
  /// | policy | growing | shrinking |
  /// |:--|:--|:--|
  /// | `scrollsFirst` | never | never |
  /// | `resizesAlways` | always | always |
  /// | `resizesFromEdge` | the content is at its start | the content is at its start |
  bool _panelIsPreferred(
    double extentDelta, {
    required Extent at,
    required bool atStart,
  }) {
    if (extentDelta < 0 && _refreshVetoes(at: at, atStart: atStart)) {
      return false;
    }
    return switch (scrollPolicy) {
      // S4 does not appear here: the grabber bypasses the arbiter entirely,
      // because a handle is not a scrollable and never reaches this file.
      PanelScrollPolicy.scrollsFirst => false,
      PanelScrollPolicy.resizesAlways => true,
      // The SDK header's precondition, verbatim: the sheet expands *"and a
      // descendent scroll view is scrolled to top"*. S6 is the same clause read
      // downward, which is why one expression answers both columns.
      PanelScrollPolicy.resizesFromEdge => atStart,
    };
  }

  /// Whether the refresh policy takes a shrinking delta away from the panel.
  ///
  /// Only from the content's own start, and only downward: A6.5's argument is
  /// about the one gesture two correct answers both claim, and a panel that
  /// stopped rubber-banding *upward* past `.full` because a refresh policy was
  /// set would be a different behaviour nobody asked to change.
  bool _refreshVetoes({required Extent at, required bool atStart}) {
    if (!atStart) return false;
    // A panel held past its largest detent is off its rail, and coming back is
    // not the gesture A6.5 is about — under any of the three policies. Without
    // this, a fully open sheet over a list with nothing to scroll can be dragged
    // *up* into the band and then not down again: the veto hands every downward
    // pixel to a list that has none to spend, and the panel stays where the
    // finger left it until the finger lifts.
    if (at.px > detents.max.px && !_isAtCeiling(at)) return false;
    return switch (refreshPolicy) {
      PanelRefreshPolicy.never => false,
      PanelRefreshPolicy.always => true,
      PanelRefreshPolicy.whenFullyOpen => _isAtCeiling(at),
    };
  }

  /// How much of [extentDelta]'s direction the panel has left before it reaches
  /// the end of its travel, as a magnitude.
  ///
  /// `detents.max - extent` growing, `extent - detents.min` shrinking, saturated
  /// at zero. Not a limit on what the panel may be handed — `PanelDragMechanics`
  /// rubber-bands whatever falls outside the travel — but the point at which
  /// handing the rest to the content becomes possible, which is what makes the
  /// switchover happen inside one delta instead of on the next frame.
  double panelRoomFor(double extentDelta) => _panelRoomFor(extentDelta, extent);

  /// [panelRoomFor] measured from a height the panel has not reached yet.
  double _panelRoomFor(double extentDelta, Extent at) =>
      extentDelta > 0 ? (detents.max - at).px : (at - detents.min).px;

  /// How much of [extentDelta]'s direction the content has left, as a magnitude
  /// on the **extent** axis.
  ///
  /// `maxScrollExtent - pixels` or `pixels - minScrollExtent`, chosen by which
  /// of the two the anchor maps this direction onto — so a top sheet, whose
  /// scroll sign is inverted, gets the other one with no branch written here.
  /// Saturated at zero, which covers both a content shorter than its viewport
  /// and a content already overscrolled past the end in question.
  double contentRoomFor(double extentDelta, PanelScrollDriver position) =>
      _contentRoomFor(extentDelta, position, position.pixels);

  /// [contentRoomFor] measured from an offset the content has not reached yet.
  ///
  /// The end it measures to is chosen by the *scroll*-space direction, so a top
  /// sheet — whose scroll sign is inverted — measures to the other one with no
  /// branch written here. Saturated at zero, which covers both a content shorter
  /// than its viewport and one already overscrolled past the end in question.
  double _contentRoomFor(
    double extentDelta,
    PanelScrollDriver position,
    double pixels,
  ) => scrollDeltaOfExtent(extentDelta) > 0
      ? math.max(0.0, position.maxScrollExtent - pixels)
      : math.max(0.0, pixels - position.minScrollExtent);

  /// How a drag delta of [extentDelta] divides between the panel and the
  /// content.
  ///
  /// **One rule, and every case in the matrix falls out of it:**
  ///
  /// > Whoever leads takes what it has room for; the follower takes the rest —
  /// > but only if the policy, re-asked in the state the leader would leave,
  /// > still permits it. Otherwise the leader keeps the whole delta.
  ///
  /// The leader is the panel when [panelMayTake] says so in the *current* state
  /// and the content otherwise, and re-asking the policy afterwards is what
  /// makes the four interesting cases correct without any of them being written
  /// down:
  ///
  /// - **Drag up at the top of the list, panel below its largest.** Panel leads,
  ///   takes `max - extent`, and is then asked again at `extent == max` where
  ///   `neighbourAbove` is null — so the remainder goes to the list. That is
  ///   iOS's "the sheet reaches `.large` and the list starts scrolling, in one
  ///   gesture", and it is the case a per-frame decision cannot express.
  /// - **Drag down on a list scrolled 5px from its top.** Content leads, takes
  ///   its 5, and the panel is asked again at `pixels == minScrollExtent` where
  ///   `resizesFromEdge` now permits it — so the sheet starts shrinking inside
  ///   the same delta rather than on the next frame. `smooth_sheets` loses this
  ///   because it splits per notification.
  /// - **Drag up on a list scrolled to its end.** Content leads, runs out, and
  ///   the panel is asked again — still at `pixels > minScrollExtent`, so still
  ///   refused. The leader keeps it and the list bounces. A rule that gave the
  ///   remainder to the follower unconditionally would grow the sheet from the
  ///   *bottom* of its list, which is the one thing `resizesFromEdge` names.
  /// - **Drag down at the smallest detent with the list at its top.** Panel
  ///   leads with zero room, and the content — at its start — has no room
  ///   either, so the panel keeps everything and the rubber band shapes it. The
  ///   alternative reading, handing it to the list, would put a refresh spinner
  ///   under a sheet that is being dismissed.
  ///
  /// [PanelRefreshPolicy] enters in exactly one place: it can veto the panel's
  /// leadership for a shrinking delta from the content's start. Under
  /// [PanelRefreshPolicy.whenFullyOpen] it does so while [isAtCeiling], so the
  /// list overscrolls and `RefreshIndicator` sees it; under
  /// [PanelRefreshPolicy.always] it does so at every detent; under
  /// [PanelRefreshPolicy.never] it never does and S6 is untouched.
  ///
  /// The result's two shares always sum to [extentDelta] exactly. Nothing is
  /// dropped: DESIGN.md §3.2's `postScroll` — the leftover the panel declines,
  /// handed on *unconditionally* so a `RefreshIndicator` needs no flag — is the
  /// `content` share, and it is a field of this value rather than a third call
  /// that could disagree with the first two about state that moved in between.
  PanelScrollSplit split(double extentDelta, PanelScrollDriver position) {
    // Not an optimisation: a zero delta must reach the content's own drag
    // controller as a zero-delta update, because that is what keeps its
    // stationary-timestamp bookkeeping live. This only refuses to *divide* one,
    // and the caller forwards the zero either way.
    if (extentDelta == 0) return PanelScrollSplit.none;

    final atStart = contentIsAtStart(position);
    final panelRoom = panelRoomFor(extentDelta);
    final contentRoom = contentRoomFor(extentDelta, position);

    // Neither has anywhere to go, so this delta is an overdrag rather than a
    // share, and the only question left is whose overdrag it is. The panel's
    // answer rubber-bands and — once `Detent.dismissed` lands — carries a
    // dismissal; the content's overscrolls, which is what a `RefreshIndicator`
    // listens for. Deciding it by room instead would hand a sheet being flung
    // shut to a refresh spinner, or hand a short list's overdrag to a list with
    // no end to bounce off.
    if (panelRoom == 0 && contentRoom == 0) {
      return _panelIsPreferred(extentDelta, at: extent, atStart: atStart)
          ? PanelScrollSplit(panel: extentDelta, content: 0)
          : PanelScrollSplit(panel: 0, content: extentDelta);
    }

    if (_panelMayTake(extentDelta, at: extent, atStart: atStart)) {
      final taken = _towards(extentDelta, panelRoom);
      // The remainder is computed as a difference rather than accumulated, so
      // `panel + content` is the input to the last bit at every point in the
      // matrix. A split that lost 0.0001px per frame to a clamp would pass every
      // named case and drift a panel visibly over a second of dragging.
      final rest = extentDelta - taken;
      final after = Extent(extent.px + taken);
      // The follower takes the rest only if the policy — re-asked at the height
      // the panel would leave — has stopped pointing at the panel, *and* the
      // content can actually use it. Both halves are load-bearing: without the
      // first, a list at its end grows the sheet from the bottom of its content;
      // without the second, a three-row sheet hands its overdrag to a list with
      // no end to bounce off and the gesture dies against a boundary condition.
      final handsOn =
          rest != 0 &&
          !_panelMayTake(rest, at: after, atStart: atStart) &&
          _contentRoomFor(rest, position, position.pixels) > 0;
      return handsOn
          ? PanelScrollSplit(panel: taken, content: rest)
          : PanelScrollSplit(panel: extentDelta, content: 0);
    }

    final taken = _towards(extentDelta, contentRoom);
    final rest = extentDelta - taken;
    // Where the content would be once it has taken its share — which is the
    // whole of "the list scrolls to its top and the sheet starts shrinking in
    // the same delta", and is what a per-notification split cannot express.
    final after = position.pixels + scrollDeltaOfExtent(taken);
    // **No room test on this side, and the asymmetry is the preference rule.**
    // When the panel is permitted and has run out of travel, the rest is an
    // overdrag, and an overdrag belongs to whoever the policy would have moved —
    // which is the panel, because being permitted is being preferred. Requiring
    // room here split the two ends of the same gesture: a drag down at the
    // smallest detent rubber-banded the panel from a list already at its top and
    // overscrolled the *list* from one five pixels above it, so whether a sheet
    // could be flung shut depended on where its list happened to be resting.
    //
    // The other branch keeps its room test for the same reason read the other
    // way: there the panel was the leader, so the preference was already the
    // panel's, and handing its overdrag to a list with no end to bounce off is
    // what `FakeContent.short` exists to forbid.
    final handsOn =
        rest != 0 &&
        _panelMayTake(
          rest,
          at: extent,
          atStart: after <= position.minScrollExtent,
        );
    return handsOn
        ? PanelScrollSplit(panel: rest, content: taken)
        : PanelScrollSplit(panel: 0, content: extentDelta);
  }

  /// [delta] limited to [room] px in its own direction.
  ///
  /// [room] is a magnitude and [delta] is signed, which is why this is a
  /// function rather than a `clamp`: the two ends of the travel are the same
  /// arithmetic on the same magnitude, and writing them as two clamps is how
  /// they come to disagree.
  double _towards(double delta, double room) =>
      delta > 0 ? math.min(delta, room) : math.max(delta, -room);

  // ==========================================================================
  // The fused release.
  // ==========================================================================

  /// The fused axis [position] and the panel currently span.
  ///
  /// Built per release rather than held, because both halves move: the detents
  /// re-resolve on a rotation and `maxScrollExtent` changes every time a lazy
  /// viewport discovers another screenful. An axis cached across a release is
  /// the stale projection `LayoutCorrection.resnap` exists to correct, arrived
  /// at from the other side.
  FusedAxis axisFor(PanelScrollDriver position) => FusedAxis(
    detents: detents,
    scrollMin: position.minScrollExtent,
    scrollMax: position.maxScrollExtent,
  );

  /// Whether the panel and [position] are somewhere [axisFor]'s coordinate can
  /// describe — whether `FusedAxis.split` gives back the pair
  /// `FusedAxis.positionOf` was handed.
  ///
  /// **Two conditions, and the second is the one being inside the bounds does
  /// not imply.** `positionOf` **adds** `(extent − detents.min)` and
  /// `(pixels − scrollMin)`; a sum is invertible only where one of the two
  /// summands is pinned, because `split` assigns everything below
  /// `FusedAxis.seam` to the panel and everything above it to the content and
  /// has nothing else to go on. So exactly two families of states round-trip:
  ///
  /// - **the content on its rail** — `pixels == minScrollExtent`, the panel
  ///   anywhere in its travel. `positionOf` is then `extent − min`, at or below
  ///   the seam, and `split` reads it back as the panel's.
  /// - **the panel on its rail** — [isAtCeiling], the content anywhere in its
  ///   own range. `positionOf` is then `travel + (pixels − scrollMin)`, at or
  ///   above the seam, and `split` reads the part above the seam back as the
  ///   content's.
  ///
  /// **Neither on its rail is not a third family, it is the teleport.** A panel
  /// below its largest detent over a list scrolled away from its top sums to
  /// the same number as a fully open panel over a list scrolled less far, and
  /// `split` answers with the second: the first frame of the release writes
  /// `extent = min + clamp(sum, 0, travel)` and
  /// `scrollPixels = scrollMin + (sum − travel)`, which moves *both* by
  /// `min(detents.max − extent, pixels − scrollMin)` — up to the panel's whole
  /// remaining travel, in opposite directions, in one frame, on a plain finger
  /// lift. `PanelScrollPolicy.resizesAlways` reaches that state by gesture
  /// alone, `scrollsFirst` by construction, and any programmatic panel move
  /// over a scrolled list reaches it under every policy.
  ///
  /// Losing fusion there costs nothing, because there is nothing to fuse: off
  /// the rail the two are genuinely two axes with two ways back — the panel
  /// through `snapTarget` and the rubber band, the content through its own
  /// `BouncingScrollSimulation` — and `PanelScrollPosition.goBallistic` gives
  /// each of them the release.
  ///
  /// The bounds are still tested, and inclusively at all four ends: an
  /// overscrolled list maps past `FusedAxis.end` and an overdragged panel maps
  /// above the seam where the content would be, and a fling that has just used
  /// up exactly its room is the ordinary case rather than an overshoot.
  bool isOnFusedAxis(PanelScrollDriver position) {
    if (position.pixels < position.minScrollExtent ||
        position.pixels > position.maxScrollExtent) {
      return false;
    }
    if (extent.px < detents.min.px || extent.px > detents.max.px) return false;
    // `contentIsAtStart` is `pixels <= minScrollExtent` and the bounds above
    // have already refused anything below it, so this is "the content is at its
    // start" exactly — asked through the package's one definition of that,
    // rather than through a second comparison that could drift from it.
    return contentIsAtStart(position) || isAtCeiling;
  }

  /// Whether the panel is entitled to a **release** of [extentDelta]'s
  /// direction, asked in the state the release would reach it in.
  ///
  /// [panelMayTake] is the same table asked about *now*, and a release is not
  /// now: a fling thrown down a scrolled list reaches the panel only after the
  /// list has run out, in a state the current one says nothing about. Asking it
  /// about now is why a fling could move a panel that `split` refuses on every
  /// frame of the drag that preceded it — `PanelScrollPolicy.scrollsFirst`
  /// says the panel is moved only by its handle, its background or code, and a
  /// fling closed the sheet anyway.
  ///
  /// Three cases, and only the second is new arithmetic:
  ///
  /// - **The content is at its start.** The panel is what the release moves
  ///   first, so the state it is asked about is the state it is in.
  /// - **A scrolled list, released toward the panel.** The fling runs the list
  ///   back to its start and crosses `FusedAxis.seam`, where the panel is at
  ///   its largest and the content is at its own start. That is where the
  ///   question belongs, and under the shipped refresh policy the answer is no
  ///   — which is exactly what a *drag* down a scrolled list already does when
  ///   it reaches the top, so this is the release agreeing with the drag rather
  ///   than a new rule.
  /// - **A scrolled list, released away from the panel.** It never reaches the
  ///   panel's half of the axis at all, so there is nothing to refuse; the seam
  ///   it may cross is the other one, and that crossing is [MomentumCarry]'s.
  ///
  /// **Ask this only where [isOnFusedAxis] holds**, which is what
  /// `PanelScrollPosition.goBallistic` does. The last two cases both lean on it:
  /// a scrolled list that is on the rail means the panel is on its ceiling, so
  /// the panel's half of the axis is *below* the release and only a shrinking
  /// throw can reach it. Off the rail the panel is somewhere in its own travel
  /// with a scrolled list beside it, a growing throw moves it directly, and
  /// [panelMayTake] — the question about now — is the one to ask.
  bool panelMayTakeRelease(double extentDelta, PanelScrollDriver position) {
    if (contentIsAtStart(position)) return panelMayTake(extentDelta, position);
    if (extentDelta >= 0) return true;
    return _panelMayTake(extentDelta, at: detents.max, atStart: true);
  }

  /// One simulation for a release of [velocity] on [position].
  ///
  /// [velocity] is in scroll space — what `ScrollPosition.goBallistic` is handed
  /// — and it is converted here, once, through the anchor. Returning the
  /// simulation rather than installing it keeps this method pure and testable
  /// against a fake driver; `PanelScrollPosition.goBallistic` is what installs
  /// the activity that samples it.
  ///
  /// The panel's own release scale — the rubber band's slope at the accumulated
  /// overshoot — is **not** applied here. It belongs to the drag that is ending,
  /// `ScrollDragActivity.end` already applies it, and applying it in two places
  /// is how the same release comes out at two speeds.
  FusedSimulation flingFor(
    ScrollVelocity velocity,
    PanelScrollDriver position,
  ) {
    // The fused axis adds the content's own offset to the panel's travel, which
    // makes "increasing" one physical direction only where a rising `pixels`
    // grows the panel. It does for `bottom`, `center` and `trailing`; for `top`
    // and `leading` the two terms move against each other and a fling would
    // scroll the list the wrong way. Those anchors have no rect yet either —
    // `PanelAnchor.rectOf` refuses them for the same slice reason — so this is
    // one loud gap rather than a second silent one.
    assert(
      extentDeltaOfScroll(1) > 0,
      'PanelAnchor.${anchor.name} inverts scroll space against extent space, and '
      'FusedAxis lays the content\'s offset out in extent-positive order. The '
      'axis needs the content term mirrored (`scrollMax - pixels`) before this '
      'anchor can fling.',
    );
    final axis = axisFor(position);
    // Half a physical pixel of the display the panel is actually on, for both
    // the distance and the velocity. `Tolerance.defaultTolerance` is calibrated
    // for a 0..1 route animation; over a span in logical pixels it runs the
    // fling's tail for seconds after the last frame that could show a
    // difference.
    final finest = 0.5 / model.layout.devicePixelRatio;
    return FusedSimulation(
      axis: axis,
      from: axis.positionOf(extent, position.pixels),
      velocity: anchor.fromScroll(velocity, textDirection).pxPerSecond,
      // The panel's own spring and the panel's own snap policy, not a second
      // pair: a fling that begins on the handle and a fling that begins in the
      // list must settle the same way.
      motion: model.config.motion,
      snapPolicy: model.config.snapPolicy,
      carry: momentumCarry,
      tolerance: Tolerance(distance: finest, velocity: finest),
    );
  }

  // ==========================================================================
  // The registry, and the loud escape.
  // ==========================================================================

  /// Every position this panel's controller has attached.
  ///
  /// Several lists may be attached at once — a `TabBarView` of them, or a
  /// `PageView` — which is why nothing in this package calls
  /// `ScrollController.position`: it throws when `positions.length != 1`.
  Iterable<ScrollPosition> get positions => _positions;
  final Set<ScrollPosition> _positions = <ScrollPosition>{};

  /// The positions already complained about, so a drag reports one mistake once.
  final Set<ScrollPosition> _reported = <ScrollPosition>{};

  /// The escaped positions currently dragging the panel in a release build.
  final Map<ScrollPosition, _EscapedDrag> _escaped =
      <ScrollPosition, _EscapedDrag>{};

  /// Records that [position] belongs to this panel.
  ///
  /// Called from `PanelScrollController.attach`. The registry is what
  /// [isEscape] compares against and what `absorb` uses to hand a binding
  /// across when Flutter replaces a position outright.
  void register(ScrollPosition position) => _positions.add(position);

  /// Forgets [position].
  ///
  /// **It used to clear [_reported] and [_escaped] here too, and both were
  /// dead.** The three sets are disjoint by construction: [_positions] is
  /// written only by [register], whose one caller is
  /// `PanelScrollController.attach` and whose argument is therefore always a
  /// `PanelScrollPosition` this controller created; [_reported] and [_escaped]
  /// are written only by [reportEscape] and [degradedSplit], whose one caller
  /// is `PanelScrollPhysics.applyPhysicsToUserOffset` *after* it has returned
  /// for every `PanelScrollPosition`. So an escapee is never registered, never
  /// detaches through here, and a lookup for one in either map could not
  /// succeed.
  ///
  /// **The hole that leaves is real and is not closed here.** A captured list
  /// removed from the tree mid-drag detaches through this method while the
  /// model is still holding its `ScrollDragActivity`, and nothing ends it — the
  /// panel keeps a gesture with no finger behind it, answering
  /// `LayoutCorrection.freeze` to every rotation and keyboard for the life of
  /// the app. An escapee disposed mid-drag leaves the identical state from the
  /// other side, through its own `_EscapedDrag`. Both want a decision about
  /// what a detaching position owes the panel, and a `remove` that could never
  /// find anything was standing in front of the question rather than answering
  /// it.
  void unregister(ScrollPosition position) => _positions.remove(position);

  /// Ends the panel's side of anything [position] is still driving.
  ///
  /// The two seams that mean *this scrollable has stopped being ours* call it:
  /// `PanelScrollPosition.dispose`, when the list leaves the tree, and
  /// `PanelScrollController.attach`, when a list moves from one panel to
  /// another. Both leave the model holding a gesture with nothing behind it
  /// otherwise, which is the terminal state [dispose] and
  /// `ScrollBallisticActivity.tick`'s doc both name: `freeze` to every layout
  /// change afterwards, so the panel can no longer follow a rotation or a
  /// keyboard, and `isUserDriven` for ever, so `updateConfig` will never re-snap
  /// it and a route will never begin its exit.
  ///
  /// A settle of zero is an arrival, not a motion — `PanelModel._settleAt`
  /// refuses to build a spring with nothing to do — so a panel that was already
  /// parked is not animated by a list letting go of it.
  ///
  /// The identity test is what keeps two lists in one panel independent: a
  /// `TabBarView` disposing the page you swiped away must not end the gesture
  /// the page you swiped *to* has already started.
  void releaseDriver(PanelScrollDriver position) {
    final panel = model.activity;
    if (panel is ScrollDrivenActivity && identical(panel.position, position)) {
      model.goBallistic(ExtentVelocity.zero);
    }
  }

  /// Whether [metrics] belongs to a scrollable that should have been captured
  /// and was not.
  ///
  /// Three things are **not** escapes, and each of them is a case a naive
  /// detector gets wrong and complains about code that is correct:
  ///
  /// 1. **One of ours.** A `PanelScrollPosition` arbitrated before this was
  ///    reached.
  /// 2. **An axis mismatch.** A horizontal carousel inside a vertical sheet
  ///    scrolls itself, `PrimaryScrollController.shouldInherit` refuses it on the
  ///    `scrollDirection` check, and `capture_test.dart` pins that as *wanted*
  ///    behaviour. `ScrollMetrics.axis` is what tells them apart.
  /// 3. **A nested inner scrollable.** `scroll_view.dart:529-532` wraps a
  ///    scroll view that inherited in `PrimaryScrollController.none`, so every
  ///    scrollable below it sees a `PrimaryScrollController` whose `controller`
  ///    is null and correctly does not attach. The framework suppressed it
  ///    deliberately, and `capture_test.dart` pins that too. The test is
  ///    `findAncestorWidgetOfExactType<PrimaryScrollController>()` — the same
  ///    lookup `shouldInherit` itself uses — resolving to a controller that is
  ///    identically ours.
  ///
  /// `findAncestorWidgetOfExactType` and never `PrimaryScrollController.maybeOf`:
  /// `maybeOf` calls `dependOnInheritedWidgetOfExactType`, and a dependency
  /// registered from a gesture callback would rebuild the escapee's `Scrollable`
  /// every time anything above it changed.
  ///
  /// **The residual hole, named rather than hidden:** a `TextField`'s internal
  /// scrollable is a genuine escape by this test when the field is multi-line,
  /// and it is one we *want* — typing must not resize the sheet. It is exempted
  /// by an `EditableText` ancestor check, which is a heuristic and is the second
  /// place after `physics:` where this channel is not exact. DESIGN.md's §"against
  /// requirement 6" names the `TextField` case as correct behaviour and does not
  /// say how it is told apart; this is how, and `escape_test.dart` holds it.
  bool isEscape(ScrollMetrics metrics) {
    // One of ours. The registry rather than a type test, because a
    // `PanelScrollPosition` belonging to a *different* panel — one sheet's list
    // shown inside another — is an escape from this one's point of view.
    if (metrics is PanelScrollPosition && identical(metrics.link, this)) {
      return false;
    }
    // A carousel in a sheet scrolls itself. `PrimaryScrollController.shouldInherit`
    // refuses it on the same comparison, and `capture_test.dart` pins that
    // refusal as *wanted*: a detector without this row complains about the
    // commonest correct thing anyone puts in a panel.
    if (metrics.axis != anchor.spanAxis) return false;
    // Everything left needs the element tree to tell a mistake from a
    // suppression, and only a live position has one. A bare `ScrollMetrics` is a
    // snapshot — `ScrollMetrics.copyWith` produces them by the dozen — and
    // reporting a mistake against one names no widget.
    if (metrics is! ScrollPosition) return false;
    final context = metrics.context.storageContext;
    // A text field's own scrollable, which is a genuine escape by every other
    // test here and is one we want: typing must not resize the sheet. Named as
    // the heuristic it is — the second place after `physics:` where this channel
    // is not exact.
    if (context.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    // `scroll_view.dart:529-532` wraps a scroll view that inherited in
    // `PrimaryScrollController.none`, so every scrollable below it sees a
    // controller of null and correctly does not attach. The framework
    // suppressed it deliberately; treating that as a mistake makes every tab of
    // lists unusable.
    //
    // `findAncestorWidgetOfExactType` and never `PrimaryScrollController.maybeOf`:
    // `maybeOf` registers a dependency, and registering one from a gesture
    // callback rebuilds the escapee's `Scrollable` every time anything above it
    // changes.
    final ambient = context
        .findAncestorWidgetOfExactType<PrimaryScrollController>()
        ?.controller;
    return ambient is PanelScrollController && identical(ambient.link, this);
  }

  /// Complains, once, about a scrollable that escaped capture.
  ///
  /// Throws a `FlutterError` in debug naming the widget and **both** fixes —
  /// hand the list a `PanelScrollController`, or let it inherit by dropping its
  /// `controller:` / `primary: false` — and does nothing in release, where
  /// [degradedSplit] carries the behaviour instead.
  ///
  /// **Once per position, not once per delta.** This is reached from
  /// `applyPhysicsToUserOffset`, which runs on every frame of a drag; an
  /// unguarded throw would report the same mistake sixty times a second and
  /// bury the first stack, which is the one with the gesture in it.
  ///
  /// It is a throw and not a `debugPrint` because the failure it names is
  /// silent: a `ListView(controller: myController)` inside a sheet behaves
  /// exactly like one outside it, and the sheet simply never moves. That is the
  /// `SheetScrollConfiguration.disabled` trap this design is written against,
  /// and the difference is that ours cannot be quiet.
  void reportEscape(ScrollMetrics metrics) {
    // An assert block rather than a `kDebugMode` test, so "does nothing in
    // release" is a property of the compiler rather than of a branch somebody
    // could get the wrong way round. The throw inside it propagates as the
    // `FlutterError` it is, not as an `AssertionError`.
    assert(() {
      if (debugSuppressEscapeReports) return true;
      // Once per position. This is reached from `applyPhysicsToUserOffset`,
      // which runs on every frame of a drag, and an unguarded throw reports the
      // same mistake sixty times a second — burying the first stack, which is
      // the one with the gesture in it.
      if (metrics is ScrollPosition && !_reported.add(metrics)) return true;
      throw FlutterError.fromParts(<DiagnosticsNode>[
        ErrorSummary(
          '${_describe(metrics)} inside a panel is scrolling on its own.',
        ),
        ErrorDescription(
          'A panel arbitrates every drag on the scrollables inside it by owning '
          'their ScrollPosition, and it reaches them through the ambient '
          'PrimaryScrollController. This one did not take it, so dragging it '
          'scrolls the list and never moves the panel — which looks exactly '
          'like a panel that is broken, with nothing anywhere saying why.',
        ),
        ErrorHint(
          'Either let it inherit — drop its `controller:` argument, or its '
          '`primary: false` — or, if it genuinely needs a controller of its own '
          'to jump to an index or read an offset, give it a '
          'PanelScrollController instead of a plain ScrollController. Both keep '
          'the handoff; there is no third option and no flag that turns this '
          'off.',
        ),
      ]);
    }());
  }

  /// The name of the widget an author actually wrote, for [reportEscape].
  ///
  /// A `ScrollPosition`'s own context is the `Scrollable`'s, which no app ever
  /// writes down — a message naming it points at a line of the framework. The
  /// first `ScrollView` above it is the `ListView` or `CustomScrollView` in the
  /// app's build method, and that is the line to fix.
  String _describe(ScrollMetrics metrics) {
    if (metrics is! ScrollPosition) return '$metrics';
    final context = metrics.context.storageContext;
    String name = context.widget.runtimeType.toString();
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is ScrollView || widget is SingleChildScrollView) {
        name = widget.runtimeType.toString();
        return false;
      }
      return true;
    });
    return name;
  }

  /// Applies the split to an escaped scrollable and returns what is left for it,
  /// in raw drag units.
  ///
  /// The release behaviour, and the reason [debugSuppressEscapeReports] exists:
  /// in debug [reportEscape] throws before this runs, so without a way to
  /// suppress the throw this path would be unreachable by a test and would ship
  /// unexercised. DESIGN.md A4 states the rule it follows — *the release
  /// behaviour must be reachable by a test rather than hidden behind
  /// `coverage:ignore`*.
  ///
  /// **What "degraded" means, exactly.** The panel takes its share of every
  /// delta and nothing else works: there is no fling handoff, because the
  /// escapee's `goBallistic` is its own; no hold, because its `hold` is its own;
  /// and no `absorb`, because we never owned the position to hand across. The
  /// panel is dragged and then settles at zero velocity.
  ///
  /// The drag's *end* is observed rather than received:
  /// `ScrollPosition.isScrollingNotifier` flips false when the escapee's
  /// activity stops scrolling, and that is what ends the panel's side. A
  /// `ScrollMetrics` that is not a `ScrollPosition` has no such notifier and
  /// gets no split at all — it is a snapshot, and driving a live panel from one
  /// is worse than not driving it.
  double degradedSplit(ScrollMetrics metrics, double dragDelta) {
    // A snapshot has no activity to end and no notifier to watch, so a drag
    // begun against one would install a gesture on the model that nothing could
    // ever finish. Driving a live panel from a copy is worse than not driving
    // it.
    if (metrics is! ScrollPosition) return dragDelta;
    return _escaped
        .putIfAbsent(metrics, () => _EscapedDrag(this, metrics))
        .apply(dragDelta);
  }

  /// Silences [reportEscape] so [degradedSplit] can be exercised in debug.
  ///
  /// Debug-only and static, in the shape `RenderObject.debugCheckingIntrinsics`
  /// established for exactly this: a refusal that is correct in production and
  /// in the way of the test that proves what happens without it.
  static bool debugSuppressEscapeReports = false;

  /// Ends the panel's side of any drag this link installed, and clears the
  /// registry.
  ///
  /// Called by the widget that created the link. It does not dispose [model] —
  /// a model outlives any one panel widget and is owned by whoever owns the
  /// panel's lifetime.
  void dispose() {
    for (final drag in _escaped.values.toList()) {
      drag.end();
    }
    _escaped.clear();
    _positions.clear();
    _reported.clear();
    // A scroll-driven activity outliving its link is the terminal state
    // `ScrollBallisticActivity.tick` names: nothing left to drive it, so it
    // answers `freeze` to every layout change afterwards and the panel can no
    // longer follow a rotation or a keyboard. Handing it to a self-driven settle
    // of zero is an arrival — `PanelModel._settleAt` parks rather than building
    // a spring with nothing to do — so a panel that was already at a detent is
    // not animated by its link going away.
    if (model.activity is ScrollDrivenActivity) {
      model.goBallistic(ExtentVelocity.zero);
    }
  }
}

/// One escaped scrollable dragging the panel in a release build.
///
/// Holds the two things [PanelScrollLink.degradedSplit] cannot: the gesture
/// installed on the model, and the subscription that ends it. Both are per
/// position, because two escapees can be dragged one after the other and the
/// second must not inherit the first's accumulated position.
final class _EscapedDrag implements PanelScrollDriver {
  _EscapedDrag(this._link, this._position)
    : _element = _position.context.storageContext {
    _position.isScrollingNotifier.addListener(_scrollingChanged);
  }

  final PanelScrollLink _link;

  /// The escapee. Read live rather than snapshotted: the split asks where the
  /// content is *now*, and a copy taken when the drag began answers where it was
  /// when the finger landed.
  final ScrollPosition _position;

  /// The escapee's element, captured while it was still in the tree.
  ///
  /// The one signal [_scrollingChanged] does not have. `ScrollPosition.dispose`
  /// disposes `isScrollingNotifier` (`scroll_position.dart:1113-1117`) **without
  /// ever setting it false**, so a list removed from the tree mid-drag never
  /// reports its drag ending — and the release it does get first,
  /// `RawGestureDetector`'s disposal arriving as a `Drag.end`, leaves it
  /// *scrolling*. Measured: the panel sat at 529.68 holding a
  /// `ScrollDragActivity`, `isUserDriven` and answering
  /// `LayoutCorrection.freeze`, through `pumpAndSettle` and for the life of the
  /// app.
  ///
  /// Held as the element rather than re-read through
  /// `ScrollableState.storageContext`, because `State.context` throws once the
  /// state is unmounted — which is exactly the moment this is for.
  /// `BuildContext.mounted` is safe on a defunct element and goes false at
  /// deactivation, one step earlier than disposal.
  final BuildContext _element;

  ScrollDragActivity? _gesture;

  @override
  double get pixels => _position.pixels;

  @override
  double get minScrollExtent => _position.minScrollExtent;

  @override
  double get maxScrollExtent => _position.maxScrollExtent;

  /// Splits [dragDelta], moves the panel, and hands back what is left in drag
  /// units.
  double apply(double dragDelta) {
    final gesture = _gesture ??= _install();
    final split = _link.split(_link.extentDeltaOfDrag(dragDelta), this);
    // The model may have replaced the gesture underneath us — a programmatic
    // `animateTo`, a page change — and writing through a disposed activity
    // would move a panel that something else is already moving.
    if (identical(_link.model.activity, gesture)) gesture.update(split.panel);
    return _link.dragDeltaOfExtent(split.content);
  }

  ScrollDragActivity _install() {
    final gesture = ScrollDragActivity(
      position: this,
      from: _link.model.extent,
    );
    _link.model.beginActivity(gesture);
    _watchTheTree();
    return gesture;
  }

  /// Ends this drag when the escapee leaves the tree, which its own notifier
  /// cannot say.
  ///
  /// A poll, and named as one. There is no callback for "this scrollable was
  /// removed" — see [_element] — so the check rides the frame the removal
  /// causes, and re-arms itself for as long as the panel is actually holding
  /// this drag. It stops the moment there is nothing left to strand: the drag
  /// ended, or the model replaced our gesture with something of its own.
  ///
  /// One `bool` per frame, on the release build's degraded path only, against a
  /// panel that would otherwise be frozen for the rest of the session. The
  /// captured half of the same hole is closed properly, in
  /// `PanelScrollPosition.dispose`, because there we own the position and its
  /// disposal is a method we can override.
  void _watchTheTree() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final gesture = _gesture;
      if (gesture == null || !identical(_link.model.activity, gesture)) return;
      if (_element.mounted) return _watchTheTree();
      _link._escaped.remove(_position);
      end();
    });
  }

  /// The drag's end, observed rather than received.
  ///
  /// An escapee's `Drag` is its own and never reaches this package, so there is
  /// no `end` to hook. `isScrollingNotifier` going false is the only signal
  /// there is, and without it the panel keeps a drag activity installed for the
  /// life of the app — freezing every later layout change.
  void _scrollingChanged() {
    if (_position.isScrollingNotifier.value) return;
    _link._escaped.remove(_position);
    end();
  }

  /// Stops listening and settles the panel at the nearest detent.
  void end() {
    _position.isScrollingNotifier.removeListener(_scrollingChanged);
    final gesture = _gesture;
    // `cancel` is `goBallistic` of zero, which projects to where the panel
    // already is — so the detent nearest the projection is the detent nearest
    // the panel, and there is no second "which one is nearest" written down.
    if (gesture != null && identical(_link.model.activity, gesture)) {
      gesture.cancel();
    }
    _gesture = null;
  }
}
